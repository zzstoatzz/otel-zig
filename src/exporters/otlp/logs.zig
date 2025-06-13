//! OpenTelemetry Protocol (OTLP) Log Exporter
//!
//! This module provides an OTLP exporter for log records that sends
//! data to OTLP-compatible backends using HTTP/JSON transport.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

const LogRecord = otel_sdk.logs.LogRecord;
const ExportResult = otel_api.common.ExportResult;
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const Resource = otel_sdk.resource.Resource;
const ResourceBuilder = otel_sdk.resource.ResourceBuilder;

/// OTLP JSON structures for serialization
const OtlpResourceLogs = struct {
    resourceLogs: []const OtlpResourceLog,
};

const OtlpResourceLog = struct {
    resource: OtlpResource,
    scopeLogs: []const OtlpScopeLog,
};

const OtlpResource = struct {
    attributes: []const OtlpKeyValue,
};

const OtlpScopeLog = struct {
    scope: OtlpInstrumentationScope,
    logRecords: []const OtlpLogRecord,
};

const OtlpInstrumentationScope = struct {
    name: []const u8,
    version: []const u8,
};

const OtlpLogRecord = struct {
    timeUnixNano: []const u8,
    severityNumber: u32,
    severityText: []const u8,
    body: OtlpAnyValue,
    attributes: []const OtlpKeyValue,
};

const OtlpKeyValue = struct {
    key: []const u8,
    value: OtlpAnyValue,
};

const OtlpAnyValue = union(enum) {
    stringValue: []const u8,
    intValue: i64,
    doubleValue: f64,
    boolValue: bool,
};

/// OTLP log exporter implementation
pub const OtlpLogExporter = struct {
    config: OtlpExporterConfig,
    allocator: std.mem.Allocator,
    is_shutdown: bool,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: OtlpExporterConfig) !*OtlpLogExporter {
        const self = try allocator.create(OtlpLogExporter);
        errdefer allocator.destroy(self);
        self.* = .{
            .config = config,
            .allocator = allocator,
            .is_shutdown = false,
            .mutex = .{},
        };
        return self;
    }

    pub fn deinit(self: *OtlpLogExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportRecords(self: *OtlpLogExporter, records: []const LogRecord, resource: Resource) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Local arena for the OTLP transform and network send.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const json_data = convertToOtlpFormat(arena.allocator(), records, resource) catch |err| {
            std.log.err("OTLP Export Error - JSON Conversion Failed. records:{} error:{}-{s}", .{ records.len, err, @errorName(err) });
            return .failure;
        };
        defer arena.allocator().free(json_data);

        const result = self.sendRequest(arena.allocator(), json_data) catch |err| {
            std.log.err("OTLP Export Error - Network Request Failed. error:{}-{s} endpoint:{s} content-length:{}", .{ err, @errorName(err), self.config.endpoint, json_data.len });
            return .failure;
        };

        return result;
    }

    pub fn forceFlush(self: *OtlpLogExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        // For HTTP transport, no persistent connection to flush
        return .success;
    }

    pub fn shutdown(self: *OtlpLogExporter, timeout_ms: ?u64) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;
        _ = timeout_ms;

        return .success;
    }

    fn sendRequest(self: *OtlpLogExporter, allocator: std.mem.Allocator, data: []const u8) !ExportResult {
        // Create stack-based HTTP client
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Parse endpoint URL with detailed error context
        const uri = std.Uri.parse(self.config.endpoint) catch |err| {
            std.log.err("OTLP URL Parsing Error: {s} - {s}", .{ self.config.endpoint, @errorName(err) });
            return err;
        };

        // Build full URL with logs path
        const host_str = switch (uri.host.?) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        const scheme_str = if (uri.scheme.len > 0) uri.scheme else "http";
        const full_url = try std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ scheme_str, host_str, uri.port orelse 4318, self.config.protocol_config.logs_path });
        defer allocator.free(full_url);
        std.log.debug("OTLP Request Details. URL:{s} Method:{s} content-type:{s} content-length:{} data:{s}", .{ full_url, "POST", "application/json", data.len, data });

        // Create HTTP request
        const full_uri = try std.Uri.parse(full_url);
        var server_header_buffer: [8192]u8 = undefined;
        var req = try client.open(.POST, full_uri, .{
            .server_header_buffer = &server_header_buffer,
        });
        defer req.deinit();

        // Set request headers
        req.headers.content_type = .{ .override = "application/json" };
        req.transfer_encoding = .{ .content_length = @intCast(data.len) };

        // Add custom headers from config (simplified approach)
        if (self.config.headers.len > 0) {
            var extra_headers = try allocator.alloc(std.http.Header, self.config.headers.len);
            for (self.config.headers, 0..) |header, h| {
                extra_headers[h] = header;
            }
            req.extra_headers = extra_headers;
        }

        // Send request
        try req.send();
        try req.writeAll(data);
        try req.finish();
        try req.wait();

        // Check response status
        switch (req.response.status) {
            .ok => return .success,
            .bad_request, .unauthorized, .forbidden, .not_found => {
                std.log.err("OTLP export failed with status: {}", .{req.response.status});
                return .failure;
            },
            else => {
                std.log.warn("OTLP export got unexpected status: {}", .{req.response.status});
                return .failure;
            },
        }
    }

    pub fn logExporter(self: *OtlpLogExporter) otel_sdk.logs.LogExporter {
        return .{ .bridge = otel_sdk.logs.BridgeLogExporter.init(self) };
    }
};

/// Convert LogRecords to OTLP format JSON
fn convertToOtlpFormat(allocator: std.mem.Allocator, records: []const LogRecord, resource: Resource) ![]u8 {
    // Convert LogRecords to OTLP ResourceLogs format
    var otlp_log_records = try allocator.alloc(OtlpLogRecord, records.len);
    defer allocator.free(otlp_log_records);

    for (records, 0..) |record, i| {
        // Convert severity number
        const severity_number: u32 = @intFromEnum(record.severity_number);
        const severity_text = record.severity_number.toShortText();

        // Convert timestamp
        const timestamp_str = try std.fmt.allocPrint(allocator, "{}", .{record.timestamp_ns orelse @as(i64, @intCast(std.time.nanoTimestamp()))});
        defer allocator.free(timestamp_str);

        // Convert body
        const body = if (record.body) |body_value| switch (body_value) {
            .string => |s| OtlpAnyValue{ .stringValue = s },
            .int => |int_val| OtlpAnyValue{ .intValue = int_val },
            .float => |f| OtlpAnyValue{ .doubleValue = f },
            .bool => |b| OtlpAnyValue{ .boolValue = b },
            .bool_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.appendSlice(if (item) "true" else "false");
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
            .int_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.writer().print("{}", .{item});
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
            .float_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.writer().print("{}", .{item});
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
            .string_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.writer().print("\"{s}\"", .{item});
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
        } else OtlpAnyValue{ .stringValue = "" };

        // Convert attributes
        var otlp_attributes = std.ArrayList(OtlpKeyValue).init(allocator);
        defer otlp_attributes.deinit();

        for (record.attributes) |attr| {
            const otlp_value = switch (attr.value) {
                .string => |s| OtlpAnyValue{ .stringValue = s },
                .int => |int_val| OtlpAnyValue{ .intValue = int_val },
                .float => |f| OtlpAnyValue{ .doubleValue = f },
                .bool => |b| OtlpAnyValue{ .boolValue = b },
                .bool_array => |arr| blk: {
                    var result = std.ArrayList(u8).init(allocator);
                    defer result.deinit();
                    try result.append('[');
                    for (arr, 0..) |item, idx| {
                        if (idx > 0) try result.appendSlice(", ");
                        try result.appendSlice(if (item) "true" else "false");
                    }
                    try result.append(']');
                    const str = try result.toOwnedSlice();
                    break :blk OtlpAnyValue{ .stringValue = str };
                },
                .int_array => |arr| blk: {
                    var result = std.ArrayList(u8).init(allocator);
                    defer result.deinit();
                    try result.append('[');
                    for (arr, 0..) |item, idx| {
                        if (idx > 0) try result.appendSlice(", ");
                        try result.writer().print("{}", .{item});
                    }
                    try result.append(']');
                    const str = try result.toOwnedSlice();
                    break :blk OtlpAnyValue{ .stringValue = str };
                },
                .float_array => |arr| blk: {
                    var result = std.ArrayList(u8).init(allocator);
                    defer result.deinit();
                    try result.append('[');
                    for (arr, 0..) |item, idx| {
                        if (idx > 0) try result.appendSlice(", ");
                        try result.writer().print("{}", .{item});
                    }
                    try result.append(']');
                    const str = try result.toOwnedSlice();
                    break :blk OtlpAnyValue{ .stringValue = str };
                },
                .string_array => |arr| blk: {
                    var result = std.ArrayList(u8).init(allocator);
                    defer result.deinit();
                    try result.append('[');
                    for (arr, 0..) |item, idx| {
                        if (idx > 0) try result.appendSlice(", ");
                        try result.writer().print("\"{s}\"", .{item});
                    }
                    try result.append(']');
                    const str = try result.toOwnedSlice();
                    break :blk OtlpAnyValue{ .stringValue = str };
                },
            };

            try otlp_attributes.append(OtlpKeyValue{
                .key = attr.key,
                .value = otlp_value,
            });
        }

        otlp_log_records[i] = OtlpLogRecord{
            .timeUnixNano = try allocator.dupe(u8, timestamp_str),
            .severityNumber = severity_number,
            .severityText = severity_text,
            .body = body,
            .attributes = try otlp_attributes.toOwnedSlice(),
        };
    }

    // Convert resource attributes to OTLP format
    var otlp_resource_attributes = std.ArrayList(OtlpKeyValue).init(allocator);
    defer otlp_resource_attributes.deinit();

    for (resource.attributes) |attr| {
        const otlp_value = switch (attr.value) {
            .string => |s| OtlpAnyValue{ .stringValue = s },
            .int => |int_val| OtlpAnyValue{ .intValue = int_val },
            .float => |f| OtlpAnyValue{ .doubleValue = f },
            .bool => |b| OtlpAnyValue{ .boolValue = b },
            .bool_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.appendSlice(if (item) "true" else "false");
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
            .int_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.writer().print("{}", .{item});
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
            .float_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.writer().print("{}", .{item});
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
            .string_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.writer().print("\"{s}\"", .{item});
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
        };

        try otlp_resource_attributes.append(OtlpKeyValue{
            .key = attr.key,
            .value = otlp_value,
        });
    }

    // Create OTLP structure
    const resource_log = OtlpResourceLog{
        .resource = OtlpResource{
            .attributes = try otlp_resource_attributes.toOwnedSlice(),
        },
        .scopeLogs = &[_]OtlpScopeLog{
            OtlpScopeLog{
                .scope = OtlpInstrumentationScope{
                    .name = "zig-otel-logs",
                    .version = "1.0.0",
                },
                .logRecords = otlp_log_records,
            },
        },
    };

    const resource_logs = OtlpResourceLogs{
        .resourceLogs = &[_]OtlpResourceLog{resource_log},
    };

    // Serialize to JSON
    var json_buffer = std.ArrayList(u8).init(allocator);
    defer json_buffer.deinit();

    try std.json.stringify(resource_logs, .{}, json_buffer.writer());
    return try json_buffer.toOwnedSlice();
}

/// Create an OTLP log exporter with custom configuration
pub fn createLogExporterWithConfig(config: OtlpExporterConfig, allocator: std.mem.Allocator) !otel_sdk.logs.LogExporter {
    const exporter = try OtlpLogExporter.init(allocator, config);
    return exporter.logExporter();
}

test "OtlpLogExporter basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var exporter = try OtlpLogExporter.init(allocator, .{
        .endpoint = "http://localhost:4318",
        .transport = .http_json,
    });
    defer exporter.deinit();

    const records = [_]LogRecord{
        .{
            .severity_number = .info,
            .body = .{ .string = "test log message" },
            .timestamp_ns = 1234567890000000000,
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "test.key", .value = .{ .string = "test.value" } },
            },
        },
    };

    // Test JSON conversion
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const test_resource = try ResourceBuilder.init(arena.allocator())
        .withDefaults()
        .finish(arena.allocator());
    const json_data = try convertToOtlpFormat(arena.allocator(), &records, test_resource);
    defer arena.allocator().free(json_data);

    try testing.expect(json_data.len > 0);
    try testing.expect(std.mem.indexOf(u8, json_data, "test log message") != null);
    try testing.expect(std.mem.indexOf(u8, json_data, "test.key") != null);
    // Test that resource information is included
    try testing.expect(std.mem.indexOf(u8, json_data, "telemetry.sdk.name") != null);
    try testing.expect(std.mem.indexOf(u8, json_data, "opentelemetry") != null);

    // Test lifecycle methods
    const flush_result = exporter.forceFlush(5000);
    try testing.expectEqual(ExportResult.success, flush_result);

    const shutdown_result = exporter.shutdown(5000);
    try testing.expectEqual(ExportResult.success, shutdown_result);

    // Should reject exports after shutdown
    const result_after_shutdown = exporter.exportRecords(&records, test_resource);
    try testing.expectEqual(ExportResult.failure, result_after_shutdown);
}
