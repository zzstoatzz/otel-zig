//! Dynamically loaded libcurl transport for OTLP mTLS.
//!
//! Zig 0.16's native TLS client does not present client certificates. Loading
//! libcurl only for that configuration keeps the ordinary exporter native and
//! avoids imposing a link-time dependency on downstream applications.

const std = @import("std");
const builtin = @import("builtin");
const TlsConfig = @import("root.zig").TlsConfig;

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    retry_after_millis: ?u64,
};

const Curl = opaque {};
const CurlSlist = opaque {};
const CurlCode = c_uint;
const CurlOption = c_uint;
const CurlInfo = c_uint;
const WriteCallback = *const fn ([*]u8, usize, usize, ?*anyopaque) callconv(.c) usize;

const Api = struct {
    easy_init: *const fn () callconv(.c) ?*Curl,
    easy_cleanup: *const fn (*Curl) callconv(.c) void,
    easy_setopt: *const fn (*Curl, CurlOption, ...) callconv(.c) CurlCode,
    easy_perform: *const fn (*Curl) callconv(.c) CurlCode,
    easy_getinfo: *const fn (*Curl, CurlInfo, ...) callconv(.c) CurlCode,
    slist_append: *const fn (?*CurlSlist, [*:0]const u8) callconv(.c) ?*CurlSlist,
    slist_free_all: *const fn (?*CurlSlist) callconv(.c) void,
};

var load_mutex: std.Io.Mutex = .init;
var loaded_library: ?std.DynLib = null;
var loaded_api: ?Api = null;

const curl_global_all: c_long = 3;
const curle_ok: CurlCode = 0;
const curlopt_url: CurlOption = 10002;
const curlopt_post: CurlOption = 47;
const curlopt_postfields: CurlOption = 10015;
const curlopt_postfieldsize_large: CurlOption = 30120;
const curlopt_httpheader: CurlOption = 10023;
const curlopt_writefunction: CurlOption = 20011;
const curlopt_writedata: CurlOption = 10001;
const curlopt_headerfunction: CurlOption = 20079;
const curlopt_headerdata: CurlOption = 10029;
const curlopt_timeout_ms: CurlOption = 155;
const curlopt_nosignal: CurlOption = 99;
const curlopt_cainfo: CurlOption = 10065;
const curlopt_sslcert: CurlOption = 10025;
const curlopt_sslkey: CurlOption = 10087;
const curlopt_ssl_verifypeer: CurlOption = 64;
const curlopt_ssl_verifyhost: CurlOption = 81;
const curlinfo_response_code: CurlInfo = 0x200002;
const max_response_body = 64 * 1024;

fn api(io: std.Io) !*const Api {
    load_mutex.lockUncancelable(io);
    defer load_mutex.unlock(io);
    if (loaded_api) |*value| return value;

    const names: []const []const u8 = switch (builtin.os.tag) {
        .linux => &.{ "libcurl.so.4", "libcurl.so" },
        .macos => &.{ "libcurl.4.dylib", "/usr/lib/libcurl.dylib" },
        .windows => &.{"libcurl.dll"},
        else => &.{"libcurl.so"},
    };
    var library: ?std.DynLib = null;
    for (names) |name| {
        library = std.DynLib.open(name) catch continue;
        break;
    }
    loaded_library = library orelse return error.LibcurlUnavailable;
    const lib = &loaded_library.?;
    const global_init = lib.lookup(*const fn (c_long) callconv(.c) CurlCode, "curl_global_init") orelse return error.LibcurlSymbolMissing;
    if (global_init(curl_global_all) != curle_ok) return error.LibcurlInitializationFailed;
    loaded_api = .{
        .easy_init = lib.lookup(@FieldType(Api, "easy_init"), "curl_easy_init") orelse return error.LibcurlSymbolMissing,
        .easy_cleanup = lib.lookup(@FieldType(Api, "easy_cleanup"), "curl_easy_cleanup") orelse return error.LibcurlSymbolMissing,
        .easy_setopt = lib.lookup(@FieldType(Api, "easy_setopt"), "curl_easy_setopt") orelse return error.LibcurlSymbolMissing,
        .easy_perform = lib.lookup(@FieldType(Api, "easy_perform"), "curl_easy_perform") orelse return error.LibcurlSymbolMissing,
        .easy_getinfo = lib.lookup(@FieldType(Api, "easy_getinfo"), "curl_easy_getinfo") orelse return error.LibcurlSymbolMissing,
        .slist_append = lib.lookup(@FieldType(Api, "slist_append"), "curl_slist_append") orelse return error.LibcurlSymbolMissing,
        .slist_free_all = lib.lookup(@FieldType(Api, "slist_free_all"), "curl_slist_free_all") orelse return error.LibcurlSymbolMissing,
    };
    return &loaded_api.?;
}

const Capture = struct {
    allocator: std.mem.Allocator,
    body: std.ArrayList(u8) = .empty,
    retry_after_millis: ?u64 = null,
    overflowed: bool = false,

    fn write(pointer: [*]u8, size: usize, count: usize, userdata: ?*anyopaque) callconv(.c) usize {
        const self: *Capture = @ptrCast(@alignCast(userdata orelse return 0));
        const length = size * count;
        if (self.body.items.len + length > max_response_body) {
            self.overflowed = true;
            return 0;
        }
        self.body.appendSlice(self.allocator, pointer[0..length]) catch return 0;
        return length;
    }

    fn header(pointer: [*]u8, size: usize, count: usize, userdata: ?*anyopaque) callconv(.c) usize {
        const self: *Capture = @ptrCast(@alignCast(userdata orelse return 0));
        const length = size * count;
        const line = pointer[0..length];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return length;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "retry-after")) return length;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
        const seconds = std.fmt.parseInt(u64, value, 10) catch return length;
        self.retry_after_millis = seconds *| 1000;
        return length;
    }
};

pub fn perform(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    content_type: []const u8,
    headers: []const std.http.Header,
    payload: []const u8,
    timeout_ms: u64,
    tls: TlsConfig,
) !Response {
    const curl = try api(io);
    const easy = curl.easy_init() orelse return error.LibcurlInitializationFailed;
    defer curl.easy_cleanup(easy);

    const owned_url = try allocator.dupeZ(u8, url);
    defer allocator.free(owned_url);
    try setopt(curl, easy, curlopt_url, owned_url.ptr);
    try setopt(curl, easy, curlopt_post, @as(c_long, 1));
    try setopt(curl, easy, curlopt_postfields, payload.ptr);
    try setopt(curl, easy, curlopt_postfieldsize_large, @as(i64, @intCast(payload.len)));
    try setopt(curl, easy, curlopt_timeout_ms, @as(c_long, @intCast(@min(timeout_ms, std.math.maxInt(c_long)))));
    try setopt(curl, easy, curlopt_nosignal, @as(c_long, 1));

    var header_list: ?*CurlSlist = null;
    defer curl.slist_free_all(header_list);
    header_list = try appendHeader(allocator, curl, header_list, "content-type", content_type);
    header_list = try appendHeader(allocator, curl, header_list, "user-agent", "otel-zig-otlp");
    for (headers) |header| header_list = try appendHeader(allocator, curl, header_list, header.name, header.value);
    try setopt(curl, easy, curlopt_httpheader, header_list);

    if (tls.insecure_skip_verify) {
        try setopt(curl, easy, curlopt_ssl_verifypeer, @as(c_long, 0));
        try setopt(curl, easy, curlopt_ssl_verifyhost, @as(c_long, 0));
    }
    var ca_path: ?[:0]u8 = null;
    defer if (ca_path) |path| allocator.free(path);
    if (tls.ca_file) |path| {
        ca_path = try allocator.dupeZ(u8, path);
        try setopt(curl, easy, curlopt_cainfo, ca_path.?.ptr);
    }
    var cert_path: ?[:0]u8 = null;
    defer if (cert_path) |path| allocator.free(path);
    if (tls.cert_file) |path| {
        cert_path = try allocator.dupeZ(u8, path);
        try setopt(curl, easy, curlopt_sslcert, cert_path.?.ptr);
    }
    var key_path: ?[:0]u8 = null;
    defer if (key_path) |path| allocator.free(path);
    if (tls.key_file) |path| {
        key_path = try allocator.dupeZ(u8, path);
        try setopt(curl, easy, curlopt_sslkey, key_path.?.ptr);
    }

    var capture: Capture = .{ .allocator = allocator };
    defer capture.body.deinit(allocator);
    try setopt(curl, easy, curlopt_writefunction, @as(WriteCallback, Capture.write));
    try setopt(curl, easy, curlopt_writedata, @as(?*anyopaque, @ptrCast(&capture)));
    try setopt(curl, easy, curlopt_headerfunction, @as(WriteCallback, Capture.header));
    try setopt(curl, easy, curlopt_headerdata, @as(?*anyopaque, @ptrCast(&capture)));

    const code = curl.easy_perform(easy);
    if (capture.overflowed) return error.ResponseBodyTooLarge;
    if (code != curle_ok) return error.LibcurlRequestFailed;
    var response_code: c_long = 0;
    if (curl.easy_getinfo(easy, curlinfo_response_code, &response_code) != curle_ok) return error.LibcurlRequestFailed;
    if (response_code < 100 or response_code > 599) return error.InvalidHttpResponse;
    return .{
        .status = @enumFromInt(@as(u10, @intCast(response_code))),
        .body = try capture.body.toOwnedSlice(allocator),
        .retry_after_millis = capture.retry_after_millis,
    };
}

fn setopt(curl: *const Api, easy: *Curl, option: CurlOption, value: anytype) !void {
    if (curl.easy_setopt(easy, option, value) != curle_ok) return error.LibcurlOptionFailed;
}

fn appendHeader(
    allocator: std.mem.Allocator,
    curl: *const Api,
    list: ?*CurlSlist,
    name: []const u8,
    value: []const u8,
) !*CurlSlist {
    const line = try std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ name, value }, 0);
    defer allocator.free(line);
    return curl.slist_append(list, line.ptr) orelse error.OutOfMemory;
}

fn environment(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

test "libcurl performs a real mTLS request when the contract environment is present" {
    const endpoint = environment("OTEL_ZIG_MTLS_TEST_ENDPOINT") orelse return;
    const ca_file = environment("OTEL_ZIG_MTLS_TEST_CA") orelse return;
    const cert_file = environment("OTEL_ZIG_MTLS_TEST_CERT") orelse return;
    const key_file = environment("OTEL_ZIG_MTLS_TEST_KEY") orelse return;
    const response = try perform(
        std.testing.allocator,
        std.Options.debug_io,
        endpoint,
        "application/x-protobuf",
        &.{},
        "real-mtls-payload",
        2_000,
        .{ .ca_file = ca_file, .cert_file = cert_file, .key_file = key_file },
    );
    defer std.testing.allocator.free(response.body);
    try std.testing.expect(response.status.class() == .success);
}
