//! OpenTelemetry Console Log Exporter
//!
//! This module provides a console exporter for log records that writes
//! formatted log output to stdout or stderr. This exporter is primarily
//! intended for debugging and development purposes.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

const LogRecord = otel_sdk.logs.LogRecord;
const Severity = otel_api.logs.Severity;
const ExportResult = otel_api.common.ExportResult;
const ConsoleExporterConfig = @import("root.zig").ConsoleExporterConfig;
const Resource = otel_sdk.resource.Resource;
const ResourceBuilder = otel_sdk.resource.ResourceBuilder;

/// Configuration for stream-based log exporters
pub const StreamLogExporterConfig = struct {
    /// Format output for human readability
    pretty_print: bool = true,

    /// Include timestamps in output
    include_timestamp: bool = true,

    /// Include attributes in output
    include_attributes: bool = true,

    /// Maximum attribute value length (0 = unlimited)
    max_attribute_length: usize = 128,
};

/// Generic stream-based log exporter that can write to any writer
pub fn StreamLogExporter(comptime WriterType: type) type {
    return struct {
        pub const PipelineStep = otel_sdk.common.PipelineStepInstructions(
            Self,
            otel_sdk.logs.LogExporter,
            StreamLogExporterConfig,
            logExporter,
            _init,
            otel_sdk.common.PipelineDeinitConnection,
        );
        const Self = @This();

        pub fn _init(config: StreamLogExporterConfig, allocator: std.mem.Allocator) !Self {
            const file = std.io.getStdOut();
            return init(allocator, config, file.writer());
        }

        allocator: std.mem.Allocator,
        config: StreamLogExporterConfig,
        writer: WriterType,
        mutex: std.Thread.Mutex,

        pub fn init(allocator: std.mem.Allocator, config: StreamLogExporterConfig, writer: WriterType) Self {
            return .{
                .allocator = allocator,
                .config = config,
                .writer = writer,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn destroy(self: *Self) void {
            self.allocator.destroy(self);
        }

        pub fn exportRecords(self: *Self, records: []const LogRecord, resource: Resource) ExportResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (records) |record| {
                self.writeRecord(record, resource) catch return .failure;
            }

            return .success;
        }

        pub fn forceFlush(self: *Self, timeout_ms: ?u64) ExportResult {
            _ = self;
            _ = timeout_ms;
            return .success;
        }

        pub fn shutdown(self: *Self, timeout_ms: ?u64) ExportResult {
            _ = self;
            _ = timeout_ms;
            return .success;
        }

        fn writeRecord(self: *Self, record: LogRecord, resource: Resource) !void {
            if (self.config.pretty_print) {
                try self.writePrettyRecord(record, resource);
            } else {
                try self.writeCompactRecord(record, resource);
            }
        }

        fn writePrettyRecord(self: *Self, record: LogRecord, resource: Resource) !void {
            // Write timestamp
            if (self.config.include_timestamp and record.timestamp_ns != null) {
                // Convert nanoseconds to seconds for display
                const timestamp_s = @divTrunc(record.timestamp_ns.?, 1_000_000_000);
                try self.writer.print("[{}] ", .{timestamp_s});
            }

            // Write severity level
            const severity_name = switch (record.severity_number) {
                .trace, .trace2, .trace3, .trace4 => "TRACE",
                .debug, .debug2, .debug3, .debug4 => "DEBUG",
                .info, .info2, .info3, .info4 => "INFO",
                .warn, .warn2, .warn3, .warn4 => "WARN",
                .@"error", .error2, .error3, .error4 => "ERROR",
                .fatal, .fatal2, .fatal3, .fatal4 => "FATAL",
                else => "UNKNOWN",
            };

            try self.writer.print("{s:<5} ", .{severity_name});

            // Write body/message
            if (record.body) |body| {
                try self.writer.print("\"{s}\"\n", .{body.string});
            } else {
                try self.writer.print("(no message)\n", .{});
            }

            // Write resource attributes
            if (resource.attributes.len > 0) {
                try self.writer.print("  Resource:\n", .{});
                for (resource.attributes) |attr| {
                    try self.writer.print("    {}=\"", .{std.fmt.fmtSliceEscapeUpper(attr.key)});
                    try self.writeAttributeValue(attr.value);
                    try self.writer.print("\"\n", .{});
                }
            }

            // Write attributes if present and enabled
            if (self.config.include_attributes and record.attributes.len > 0) {
                try self.writer.print("  Attributes:\n", .{});
                for (record.attributes) |attr| {
                    try self.writer.print("    {}=\"", .{std.fmt.fmtSliceEscapeUpper(attr.key)});
                    try self.writeAttributeValue(attr.value);
                    try self.writer.print("\"\n", .{});
                }
            }
        }

        fn writeCompactRecord(self: *Self, record: LogRecord, resource: Resource) !void {
            // Timestamp
            if (self.config.include_timestamp and record.timestamp_ns != null) {
                const timestamp_s = @divTrunc(record.timestamp_ns.?, 1_000_000_000);
                try self.writer.print("{}|", .{timestamp_s});
            }

            // Severity (single character)
            const severity_char: u8 = switch (record.severity_number) {
                .trace, .trace2, .trace3, .trace4 => 'T',
                .debug, .debug2, .debug3, .debug4 => 'D',
                .info, .info2, .info3, .info4 => 'I',
                .warn, .warn2, .warn3, .warn4 => 'W',
                .@"error", .error2, .error3, .error4 => 'E',
                .fatal, .fatal2, .fatal3, .fatal4 => 'F',
                else => '?',
            };
            try self.writer.print("{c}|", .{severity_char});

            // Body
            if (record.body) |body| {
                try self.writer.print("{s}", .{body.string});
            }

            // Resource attributes (compact format)
            if (resource.attributes.len > 0) {
                try self.writer.print("|res:", .{});
                for (resource.attributes, 0..) |attr, i| {
                    if (i > 0) try self.writer.print(",", .{});
                    try self.writer.print("{}=", .{std.fmt.fmtSliceEscapeUpper(attr.key)});
                    try self.writeAttributeValue(attr.value);
                }
            }

            // Attributes (compact format)
            if (self.config.include_attributes and record.attributes.len > 0) {
                try self.writer.print("|", .{});
                for (record.attributes, 0..) |attr, i| {
                    if (i > 0) try self.writer.print(",", .{});
                    try self.writer.print("{}=", .{std.fmt.fmtSliceEscapeUpper(attr.key)});
                    try self.writeAttributeValue(attr.value);
                }
            }

            try self.writer.print("\n", .{});
        }

        fn writeAttributeValue(self: *Self, value: otel_api.common.AttributeValue) !void {
            switch (value) {
                .bool => |v| try self.writer.print("{}", .{v}),
                .int => |v| try self.writer.print("{}", .{v}),
                .float => |v| try self.writer.print("{d}", .{v}),
                .string => |v| {
                    if (self.config.max_attribute_length > 0 and v.len > self.config.max_attribute_length) {
                        try self.writer.print("{s}...", .{v[0..self.config.max_attribute_length]});
                    } else {
                        try self.writer.print("{s}", .{v});
                    }
                },
                .bool_array => |arr| {
                    try self.writer.print("[", .{});
                    for (arr, 0..) |v, i| {
                        if (i > 0) try self.writer.print(",", .{});
                        try self.writer.print("{}", .{v});
                    }
                    try self.writer.print("]", .{});
                },
                .int_array => |arr| {
                    try self.writer.print("[", .{});
                    for (arr, 0..) |v, i| {
                        if (i > 0) try self.writer.print(",", .{});
                        try self.writer.print("{}", .{v});
                    }
                    try self.writer.print("]", .{});
                },
                .float_array => |arr| {
                    try self.writer.print("[", .{});
                    for (arr, 0..) |v, i| {
                        if (i > 0) try self.writer.print(",", .{});
                        try self.writer.print("{d}", .{v});
                    }
                    try self.writer.print("]", .{});
                },
                .string_array => |arr| {
                    try self.writer.print("[", .{});
                    for (arr, 0..) |v, i| {
                        if (i > 0) try self.writer.print(",", .{});
                        try self.writer.print("{s}", .{v});
                    }
                    try self.writer.print("]", .{});
                },
            }
        }

        pub fn logExporter(self: *Self) otel_sdk.logs.LogExporter {
            return .{ .bridge = otel_sdk.logs.BridgeLogExporter.init(self) };
        }
    };
}

// Tests using buffer writers
test "StreamLogExporter basic export with buffer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var stream_exporter = StreamLogExporter(std.ArrayList(u8).Writer).init(allocator, .{
        .pretty_print = false,
        .include_timestamp = false,
    }, buffer.writer());
    defer stream_exporter.deinit();

    const records = [_]LogRecord{
        .{
            .severity_number = .info,
            .body = otel_api.AttributeValue{ .string = "Test message 1" },
        },
        .{
            .severity_number = .@"error",
            .body = otel_api.AttributeValue{ .string = "Test message 2" },
        },
    };

    const test_resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    defer test_resource.deinitOwned(allocator);

    const result = stream_exporter.exportRecords(&records, test_resource);
    try testing.expectEqual(ExportResult.success, result);

    const output = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "Test message 1"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "Test message 2"));
}

test "StreamLogExporter with attributes and buffer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var stream_exporter = StreamLogExporter(std.ArrayList(u8).Writer).init(allocator, .{
        .pretty_print = false,
        .include_timestamp = false,
    }, buffer.writer());
    defer stream_exporter.deinit();

    const attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "user", .value = .{ .string = "alice" } },
        .{ .key = "action", .value = .{ .string = "login" } },
    };

    const records = [_]LogRecord{
        .{
            .severity_number = .info,
            .body = otel_api.AttributeValue{ .string = "User action" },
            .attributes = &attrs,
        },
    };

    const test_resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    defer test_resource.deinitOwned(allocator);

    const result = stream_exporter.exportRecords(&records, test_resource);
    try testing.expectEqual(ExportResult.success, result);

    const output = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "User action"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "alice"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "login"));
}

test "StreamLogExporter formatting modes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test compact format
    {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        var stream_exporter = StreamLogExporter(std.ArrayList(u8).Writer).init(allocator, .{
            .pretty_print = false,
            .include_timestamp = false,
            .include_attributes = true,
        }, buffer.writer());
        defer stream_exporter.deinit();

        const attrs = [_]otel_api.common.AttributeKeyValue{
            .{ .key = "key", .value = .{ .string = "value" } },
        };

        const records = [_]LogRecord{
            .{
                .severity_number = .info,
                .body = .{ .string = "compact test" },
                .attributes = &attrs,
            },
        };

        const test_resource = otel_sdk.resource.Resource.default;

        const result = stream_exporter.exportRecords(&records, test_resource);
        try testing.expectEqual(ExportResult.success, result);

        const output = buffer.items;
        try testing.expect(std.mem.containsAtLeast(u8, output, 1, "I|compact test"));
        try testing.expect(std.mem.containsAtLeast(u8, output, 1, "key=value"));
    }

    // Test pretty format
    {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        var stream_exporter = StreamLogExporter(std.ArrayList(u8).Writer).init(allocator, .{
            .pretty_print = true,
            .include_timestamp = false,
            .include_attributes = true,
        }, buffer.writer());
        defer stream_exporter.deinit();

        const attrs = [_]otel_api.common.AttributeKeyValue{
            .{ .key = "service", .value = .{ .string = "test-service" } },
        };

        const records = [_]LogRecord{
            .{
                .severity_number = .warn,
                .body = .{ .string = "pretty test" },
                .attributes = &attrs,
            },
        };

        const test_resource = try ResourceBuilder.init(allocator)
            .withDefaults()
            .finish(allocator);
        defer test_resource.deinitOwned(allocator);

        const result = stream_exporter.exportRecords(&records, test_resource);
        try testing.expectEqual(ExportResult.success, result);

        const output = buffer.items;
        try testing.expect(std.mem.containsAtLeast(u8, output, 1, "WARN"));
        try testing.expect(std.mem.containsAtLeast(u8, output, 1, "pretty test"));
        try testing.expect(std.mem.containsAtLeast(u8, output, 1, "Attributes:"));
        try testing.expect(std.mem.containsAtLeast(u8, output, 1, "service"));
    }
}
