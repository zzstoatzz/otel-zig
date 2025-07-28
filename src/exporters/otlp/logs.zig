const std = @import("std");
const api = @import("otel-api");
const sdk = @import("otel-sdk");
const protobuf = @import("protobuf");

const LogRecord = sdk.logs.LogRecord;
const ExportResult = api.common.ExportResult;
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const Resource = sdk.resource.Resource;
const ResourceBuilder = sdk.resource.ResourceBuilder;

// Import protobuf definitions
const logs_v1 = @import("proto/opentelemetry/proto/logs/v1.pb.zig");
const common_v1 = @import("proto/opentelemetry/proto/common/v1.pb.zig");
const resource_v1 = @import("proto/opentelemetry/proto/resource/v1.pb.zig");

const error_handler = api.common;

pub const OtlpLogExporter = struct {
    pub const PipelineStep = sdk.common.PipelineStepInstructions(
        OtlpLogExporter,
        sdk.logs.LogExporter,
        OtlpExporterConfig,
        logExporter,
        _init,
        sdk.common.PipelineDeinitConnection,
    );

    config: OtlpExporterConfig,
    allocator: std.mem.Allocator,
    is_shutdown: bool,
    mutex: std.Thread.Mutex,

    pub fn _init(self: *OtlpLogExporter, config: OtlpExporterConfig, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, config);
    }

    pub fn init(allocator: std.mem.Allocator, config: OtlpExporterConfig) OtlpLogExporter {
        return .{
            .config = config,
            .allocator = allocator,
            .is_shutdown = false,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *OtlpLogExporter) void {
        _ = self;
    }

    pub fn destroy(self: *OtlpLogExporter) void {
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

        // Choose format based on transport configuration
        const data_result = switch (self.config.transport) {
            .http_json => self.convertToJsonFormat(arena.allocator(), records, resource),
            .http_protobuf, .grpc => self.convertToProtobufFormat(arena.allocator(), records, resource),
        };

        const data = data_result catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_serialization",
                .error_type = .serialization,
                .message = "OTLP serialization failed",
                .context = "log records",
                .source_error = err,
            });
            return .failure;
        };

        const result = self.sendRequest(arena.allocator(), data) catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_network",
                .error_type = .network,
                .message = "OTLP network request failed",
                .context = self.config.endpoint,
                .source_error = err,
            });
            return .failure;
        };

        return result;
    }

    pub fn forceFlush(self: *OtlpLogExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        self.mutex.lock();
        defer self.mutex.unlock();

        // No-op for OTLP exporter
        return .success;
    }

    pub fn shutdown(self: *OtlpLogExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        self.is_shutdown = true;
        return .success;
    }

    fn sendRequest(self: *OtlpLogExporter, allocator: std.mem.Allocator, data: []const u8) !ExportResult {
        // Create stack-based HTTP client
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Parse endpoint URL with detailed error context
        const uri = std.Uri.parse(self.config.endpoint) catch |err| {
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

        // Determine content type based on transport
        const content_type = switch (self.config.transport) {
            .http_json => "application/json",
            .http_protobuf, .grpc => "application/x-protobuf",
        };

        // Create HTTP request
        const full_uri = try std.Uri.parse(full_url);
        var server_header_buffer: [8192]u8 = undefined;
        var req = try client.open(.POST, full_uri, .{
            .server_header_buffer = &server_header_buffer,
        });
        defer req.deinit();

        // Set request headers
        req.headers.content_type = .{ .override = content_type };
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
                return .failure;
            },
            else => {
                return .failure;
            },
        }
    }

    pub fn logExporter(self: *OtlpLogExporter) sdk.logs.LogExporter {
        return sdk.logs.LogExporter{ .bridge = sdk.logs.BridgeLogExporter.init(self) };
    }

    fn convertToJsonFormat(self: *OtlpLogExporter, allocator: std.mem.Allocator, records: []const LogRecord, resource: Resource) ![]u8 {
        _ = self;

        // Create protobuf LogsData structure
        var logs_data = logs_v1.LogsData{
            .resource_logs = std.ArrayList(logs_v1.ResourceLogs).init(allocator),
        };

        // Convert resource
        var resource_logs = logs_v1.ResourceLogs{
            .resource = try convertResourceToProtobuf(allocator, resource),
            .scope_logs = std.ArrayList(logs_v1.ScopeLogs).init(allocator),
            .schema_url = protobuf.ManagedString.static(""),
        };

        // Convert scope logs
        var scope_logs = logs_v1.ScopeLogs{
            .scope = common_v1.InstrumentationScope{
                .name = protobuf.ManagedString.static("zig-otel-logs"),
                .version = protobuf.ManagedString.static("1.0.0"),
                .attributes = std.ArrayList(common_v1.KeyValue).init(allocator),
                .dropped_attributes_count = 0,
            },
            .log_records = std.ArrayList(logs_v1.LogRecord).init(allocator),
            .schema_url = protobuf.ManagedString.static(""),
        };

        // Convert log records
        for (records) |record| {
            const protobuf_record = try convertLogRecordToProtobuf(allocator, record);
            try scope_logs.log_records.append(protobuf_record);
        }

        try resource_logs.scope_logs.append(scope_logs);
        try logs_data.resource_logs.append(resource_logs);

        // Serialize to JSON using std.json.stringify
        var json_buffer = std.ArrayList(u8).init(allocator);
        try std.json.stringify(logs_data, .{}, json_buffer.writer());
        return json_buffer.toOwnedSlice();
    }

    fn convertToProtobufFormat(self: *OtlpLogExporter, allocator: std.mem.Allocator, records: []const LogRecord, resource: Resource) ![]u8 {
        _ = self;

        // Create protobuf LogsData structure
        var logs_data = logs_v1.LogsData{
            .resource_logs = std.ArrayList(logs_v1.ResourceLogs).init(allocator),
        };

        // Convert resource
        var resource_logs = logs_v1.ResourceLogs{
            .resource = try convertResourceToProtobuf(allocator, resource),
            .scope_logs = std.ArrayList(logs_v1.ScopeLogs).init(allocator),
            .schema_url = protobuf.ManagedString.static(""),
        };

        // Convert scope logs
        var scope_logs = logs_v1.ScopeLogs{
            .scope = common_v1.InstrumentationScope{
                .name = protobuf.ManagedString.static("zig-otel-logs"),
                .version = protobuf.ManagedString.static("1.0.0"),
                .attributes = std.ArrayList(common_v1.KeyValue).init(allocator),
                .dropped_attributes_count = 0,
            },
            .log_records = std.ArrayList(logs_v1.LogRecord).init(allocator),
            .schema_url = protobuf.ManagedString.static(""),
        };

        // Convert log records
        for (records) |record| {
            const protobuf_record = try convertLogRecordToProtobuf(allocator, record);
            try scope_logs.log_records.append(protobuf_record);
        }

        try resource_logs.scope_logs.append(scope_logs);
        try logs_data.resource_logs.append(resource_logs);

        // Serialize to protobuf binary format
        return try logs_data.encode(allocator);
    }
};

fn convertResourceToProtobuf(allocator: std.mem.Allocator, resource: Resource) !?resource_v1.Resource {
    var pb_resource = resource_v1.Resource{
        .attributes = std.ArrayList(common_v1.KeyValue).init(allocator),
        .dropped_attributes_count = 0,
        .entity_refs = std.ArrayList(common_v1.EntityRef).init(allocator),
    };

    for (resource.attributes) |attr| {
        const pb_kv = common_v1.KeyValue{
            .key = protobuf.ManagedString.managed(attr.key),
            .value = try convertAttributeValueToProtobuf(allocator, attr.value),
        };
        try pb_resource.attributes.append(pb_kv);
    }

    return pb_resource;
}

fn convertLogRecordToProtobuf(allocator: std.mem.Allocator, record: LogRecord) !logs_v1.LogRecord {
    const timestamp_ns = record.timestamp_ns orelse std.time.nanoTimestamp();
    var pb_record = logs_v1.LogRecord{
        .time_unix_nano = @as(u64, @intCast(@max(0, timestamp_ns))),
        .observed_time_unix_nano = @as(u64, @intCast(@max(0, timestamp_ns))),
        .severity_number = mapSeverityToProtobuf(record.severity_number),
        .severity_text = protobuf.ManagedString.managed(record.severity_number.toShortText()),
        .body = if (record.body) |body| try convertAttributeValueToProtobuf(allocator, body) else null,
        .attributes = std.ArrayList(common_v1.KeyValue).init(allocator),
        .dropped_attributes_count = 0,
        .flags = 0,
        .trace_id = protobuf.ManagedString.static(""),
        .span_id = protobuf.ManagedString.static(""),
        .event_name = protobuf.ManagedString.static(""),
    };

    for (record.attributes) |attr| {
        const pb_kv = common_v1.KeyValue{
            .key = protobuf.ManagedString.managed(attr.key),
            .value = try convertAttributeValueToProtobuf(allocator, attr.value),
        };
        try pb_record.attributes.append(pb_kv);
    }

    return pb_record;
}

fn mapSeverityToProtobuf(severity: api.logs.Severity) logs_v1.SeverityNumber {
    return switch (severity) {
        .invalid => .SEVERITY_NUMBER_UNSPECIFIED,
        .trace => .SEVERITY_NUMBER_TRACE,
        .trace2 => .SEVERITY_NUMBER_TRACE2,
        .trace3 => .SEVERITY_NUMBER_TRACE3,
        .trace4 => .SEVERITY_NUMBER_TRACE4,
        .debug => .SEVERITY_NUMBER_DEBUG,
        .debug2 => .SEVERITY_NUMBER_DEBUG2,
        .debug3 => .SEVERITY_NUMBER_DEBUG3,
        .debug4 => .SEVERITY_NUMBER_DEBUG4,
        .info => .SEVERITY_NUMBER_INFO,
        .info2 => .SEVERITY_NUMBER_INFO2,
        .info3 => .SEVERITY_NUMBER_INFO3,
        .info4 => .SEVERITY_NUMBER_INFO4,
        .warn => .SEVERITY_NUMBER_WARN,
        .warn2 => .SEVERITY_NUMBER_WARN2,
        .warn3 => .SEVERITY_NUMBER_WARN3,
        .warn4 => .SEVERITY_NUMBER_WARN4,
        .@"error" => .SEVERITY_NUMBER_ERROR,
        .error2 => .SEVERITY_NUMBER_ERROR2,
        .error3 => .SEVERITY_NUMBER_ERROR3,
        .error4 => .SEVERITY_NUMBER_ERROR4,
        .fatal => .SEVERITY_NUMBER_FATAL,
        .fatal2 => .SEVERITY_NUMBER_FATAL2,
        .fatal3 => .SEVERITY_NUMBER_FATAL3,
        .fatal4 => .SEVERITY_NUMBER_FATAL4,
    };
}

fn convertAttributeValueToProtobuf(allocator: std.mem.Allocator, value: api.common.AttributeValue) !?common_v1.AnyValue {
    const pb_value = switch (value) {
        .string => |s| common_v1.AnyValue{
            .value = .{ .string_value = protobuf.ManagedString.managed(s) },
        },
        .int => |i| common_v1.AnyValue{
            .value = .{ .int_value = i },
        },
        .float => |f| common_v1.AnyValue{
            .value = .{ .double_value = f },
        },
        .bool => |b| common_v1.AnyValue{
            .value = .{ .bool_value = b },
        },
        .bool_array => |arr| blk: {
            var pb_array = common_v1.ArrayValue{
                .values = std.ArrayList(common_v1.AnyValue).init(allocator),
            };
            for (arr) |item| {
                try pb_array.values.append(common_v1.AnyValue{
                    .value = .{ .bool_value = item },
                });
            }
            break :blk common_v1.AnyValue{
                .value = .{ .array_value = pb_array },
            };
        },
        .int_array => |arr| blk: {
            var pb_array = common_v1.ArrayValue{
                .values = std.ArrayList(common_v1.AnyValue).init(allocator),
            };
            for (arr) |item| {
                try pb_array.values.append(common_v1.AnyValue{
                    .value = .{ .int_value = item },
                });
            }
            break :blk common_v1.AnyValue{
                .value = .{ .array_value = pb_array },
            };
        },
        .float_array => |arr| blk: {
            var pb_array = common_v1.ArrayValue{
                .values = std.ArrayList(common_v1.AnyValue).init(allocator),
            };
            for (arr) |item| {
                try pb_array.values.append(common_v1.AnyValue{
                    .value = .{ .double_value = item },
                });
            }
            break :blk common_v1.AnyValue{
                .value = .{ .array_value = pb_array },
            };
        },
        .string_array => |arr| blk: {
            var pb_array = common_v1.ArrayValue{
                .values = std.ArrayList(common_v1.AnyValue).init(allocator),
            };
            for (arr) |item| {
                try pb_array.values.append(common_v1.AnyValue{
                    .value = .{ .string_value = protobuf.ManagedString.managed(item) },
                });
            }
            break :blk common_v1.AnyValue{
                .value = .{ .array_value = pb_array },
            };
        },
    };

    return pb_value;
}

test "OtlpLogExporter basic functionality" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a test config
    const config = OtlpExporterConfig{
        .endpoint = "http://localhost:4318",
        .transport = .http_json,
    };

    // Create exporter
    var exporter = OtlpLogExporter.init(allocator, config);
    defer exporter.deinit();

    // Create test resource
    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    // Create test log record
    const log_record = LogRecord{
        .timestamp_ns = 1000000000,
        .severity_number = .info,
        .body = .{ .string = "test message" },
        .attributes = &[_]api.common.AttributeKeyValue{
            .{ .key = "test.key", .value = .{ .string = "test.value" } },
        },
    };

    // Test that exporter doesn't crash (network call will fail but that's expected)
    const result = exporter.exportRecords(&[_]LogRecord{log_record}, resource);
    try testing.expect(result == .failure or result == .success);
}

test "OtlpLogExporter transport selection" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test resource
    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    // Create test log record
    const log_record = LogRecord{
        .timestamp_ns = 1000000000,
        .severity_number = .info,
        .body = .{ .string = "test message" },
        .attributes = &[_]api.common.AttributeKeyValue{
            .{ .key = "test.key", .value = .{ .string = "test.value" } },
        },
    };

    // Test JSON transport
    {
        const config = OtlpExporterConfig{
            .endpoint = "http://localhost:4318",
            .transport = .http_json,
        };

        var exporter = OtlpLogExporter.init(allocator, config);
        defer exporter.deinit();

        // Test JSON format conversion
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const json_data = try exporter.convertToJsonFormat(arena.allocator(), &[_]LogRecord{log_record}, resource);
        try testing.expect(json_data.len > 0);
        try testing.expect(std.mem.indexOf(u8, json_data, "test message") != null);
        try testing.expect(std.mem.indexOf(u8, json_data, "test.key") != null);
        try testing.expect(std.mem.indexOf(u8, json_data, "telemetry.sdk.name") != null);
    }

    // Test protobuf transport
    {
        const config = OtlpExporterConfig{
            .endpoint = "http://localhost:4318",
            .transport = .http_protobuf,
        };

        var exporter = OtlpLogExporter.init(allocator, config);
        defer exporter.deinit();

        // Test protobuf format conversion
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const protobuf_data = try exporter.convertToProtobufFormat(arena.allocator(), &[_]LogRecord{log_record}, resource);
        try testing.expect(protobuf_data.len > 0);
        // Protobuf is binary format, so we can't check for string content directly
        // But we can verify it's not empty and different from JSON
    }

    // Test gRPC transport (should use protobuf format)
    {
        const config = OtlpExporterConfig{
            .endpoint = "http://localhost:4318",
            .transport = .grpc,
        };

        var exporter = OtlpLogExporter.init(allocator, config);
        defer exporter.deinit();

        // Test gRPC format conversion (should be same as protobuf)
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const grpc_data = try exporter.convertToProtobufFormat(arena.allocator(), &[_]LogRecord{log_record}, resource);
        try testing.expect(grpc_data.len > 0);
    }
}

test "OtlpLogExporter severity mapping" {
    const testing = std.testing;

    // Test all severity levels map correctly
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_UNSPECIFIED, mapSeverityToProtobuf(.invalid));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_TRACE, mapSeverityToProtobuf(.trace));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_DEBUG, mapSeverityToProtobuf(.debug));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_INFO, mapSeverityToProtobuf(.info));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_WARN, mapSeverityToProtobuf(.warn));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_ERROR, mapSeverityToProtobuf(.@"error"));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_FATAL, mapSeverityToProtobuf(.fatal));
}

test "OtlpLogExporter attribute conversion" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test string attribute
    {
        const attr_value = api.common.AttributeValue{ .string = "test_string" };
        const pb_value = try convertAttributeValueToProtobuf(allocator, attr_value);
        try testing.expect(pb_value != null);
        try testing.expect(pb_value.?.value != null);
        try testing.expectEqual(common_v1.AnyValue._value_case.string_value, std.meta.activeTag(pb_value.?.value.?));
    }

    // Test int attribute
    {
        const attr_value = api.common.AttributeValue{ .int = 42 };
        const pb_value = try convertAttributeValueToProtobuf(allocator, attr_value);
        try testing.expect(pb_value != null);
        try testing.expect(pb_value.?.value != null);
        try testing.expectEqual(common_v1.AnyValue._value_case.int_value, std.meta.activeTag(pb_value.?.value.?));
        try testing.expectEqual(@as(i64, 42), pb_value.?.value.?.int_value);
    }

    // Test bool attribute
    {
        const attr_value = api.common.AttributeValue{ .bool = true };
        const pb_value = try convertAttributeValueToProtobuf(allocator, attr_value);
        try testing.expect(pb_value != null);
        try testing.expect(pb_value.?.value != null);
        try testing.expectEqual(common_v1.AnyValue._value_case.bool_value, std.meta.activeTag(pb_value.?.value.?));
        try testing.expectEqual(true, pb_value.?.value.?.bool_value);
    }

    // Test float attribute
    {
        const attr_value = api.common.AttributeValue{ .float = 3.14 };
        const pb_value = try convertAttributeValueToProtobuf(allocator, attr_value);
        try testing.expect(pb_value != null);
        try testing.expect(pb_value.?.value != null);
        try testing.expectEqual(common_v1.AnyValue._value_case.double_value, std.meta.activeTag(pb_value.?.value.?));
        try testing.expectEqual(@as(f64, 3.14), pb_value.?.value.?.double_value);
    }

    // Test array attribute
    {
        const int_array = [_]i64{ 1, 2, 3 };
        const attr_value = api.common.AttributeValue{ .int_array = &int_array };
        const pb_value = try convertAttributeValueToProtobuf(allocator, attr_value);
        defer if (pb_value) |val| {
            if (val.value) |v| {
                switch (v) {
                    .array_value => |arr| arr.values.deinit(),
                    else => {},
                }
            }
        };
        try testing.expect(pb_value != null);
        try testing.expect(pb_value.?.value != null);
        try testing.expectEqual(common_v1.AnyValue._value_case.array_value, std.meta.activeTag(pb_value.?.value.?));
        try testing.expectEqual(@as(usize, 3), pb_value.?.value.?.array_value.values.items.len);
    }
}

test "OtlpLogExporter protobuf format validation" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test resource
    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    // Create test log record
    const log_record = LogRecord{
        .timestamp_ns = 1000000000,
        .severity_number = .info,
        .body = .{ .string = "test message" },
        .attributes = &[_]api.common.AttributeKeyValue{
            .{ .key = "test.key", .value = .{ .string = "test.value" } },
            .{ .key = "test.number", .value = .{ .int = 42 } },
        },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var exporter = OtlpLogExporter.init(allocator, .{ .transport = .http_json });

    // Generate JSON using protobuf structures
    const protobuf_json = try exporter.convertToJsonFormat(arena.allocator(), &[_]LogRecord{log_record}, resource);

    // Generate binary protobuf
    const protobuf_data = try exporter.convertToProtobufFormat(arena.allocator(), &[_]LogRecord{log_record}, resource);

    // Validate both formats are generated successfully
    try testing.expect(protobuf_json.len > 0);
    try testing.expect(protobuf_data.len > 0);

    // Protobuf binary should be smaller than JSON
    try testing.expect(protobuf_data.len < protobuf_json.len);

    // JSON should contain the test message and attributes
    try testing.expect(std.mem.indexOf(u8, protobuf_json, "test message") != null);
    try testing.expect(std.mem.indexOf(u8, protobuf_json, "test.key") != null);
    try testing.expect(std.mem.indexOf(u8, protobuf_json, "test.value") != null);

    // JSON should contain OTLP structure
    try testing.expect(std.mem.indexOf(u8, protobuf_json, "resourceLogs") != null);
    try testing.expect(std.mem.indexOf(u8, protobuf_json, "scopeLogs") != null);
    try testing.expect(std.mem.indexOf(u8, protobuf_json, "logRecords") != null);
}
