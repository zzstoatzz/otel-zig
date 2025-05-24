//! OpenTelemetry Log Record API
//!
//! This module defines the LogRecord structure according to the OpenTelemetry specification.
//! A LogRecord represents a single log entry with associated metadata.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/data-model.md

const std = @import("std");
const Severity = @import("severity.zig").Severity;
const AttributeValue = @import("../common/root.zig").AttributeValue;
const KeyValue = @import("../common/root.zig").KeyValue;

const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;

/// LogRecord represents a log entry according to the OpenTelemetry specification.
/// This is a non-owning structure - all slices reference external memory.
///
/// Required fields according to the spec:
/// - timestamp (here as timestamp_ns)
/// - observed_timestamp (here as observed_timestamp_ns)
/// - severity_number
/// - body
///
/// Optional fields:
/// - severity_text
/// - attributes
/// - trace_id
/// - span_id
/// - flags
pub const LogRecord = struct {
    /// Time when the event occurred, nanoseconds since Unix epoch
    timestamp_ns: ?i64 = null,

    /// Time when the event was observed, nanoseconds since Unix epoch
    /// If not set, it should be set to the current time when the record is emitted
    observed_timestamp_ns: ?i64 = null,

    /// Numeric severity level
    severity_number: Severity = .invalid,

    /// Human-readable severity text (optional)
    severity_text: ?[]const u8 = null,

    /// The log message body
    body: ?AttributeValue = null,

    /// Name that identifies the class/type of the event
    /// A log record with a non-empty event name is an Event according to OpenTelemetry spec
    event_name: ?[]const u8 = null,

    /// Additional attributes associated with the log record
    attributes: []const KeyValue = &[_]KeyValue{},

    /// TraceId of the span that this log record is associated with (16 bytes)
    trace_id: ?[16]u8 = null,

    /// SpanId of the span that this log record is associated with (8 bytes)
    span_id: ?[8]u8 = null,

    /// Trace flags (1 byte)
    flags: ?u8 = null,



    /// Instrumentation scope that produced this log record.
    instrumentation_scope: ?InstrumentationScope = null,

    /// Check if this log record is associated with a trace
    pub fn hasTraceContext(self: LogRecord) bool {
        return self.trace_id != null and self.span_id != null;
    }

    /// Get the severity number as an integer
    pub fn severityNumber(self: LogRecord) i32 {
        return @intFromEnum(self.severity_number);
    }

    /// Format trace ID as hex string (requires a buffer of at least 32 bytes)
    pub fn formatTraceId(self: LogRecord, buf: []u8) ![]const u8 {
        if (self.trace_id) |tid| {
            if (buf.len < 32) return error.BufferTooSmall;
            return std.fmt.bufPrint(buf, "{x:0>32}", .{std.fmt.fmtSliceHexLower(&tid)}) catch unreachable;
        }
        return "";
    }

    /// Format span ID as hex string (requires a buffer of at least 16 bytes)
    pub fn formatSpanId(self: LogRecord, buf: []u8) ![]const u8 {
        if (self.span_id) |sid| {
            if (buf.len < 16) return error.BufferTooSmall;
            return std.fmt.bufPrint(buf, "{x:0>16}", .{std.fmt.fmtSliceHexLower(&sid)}) catch unreachable;
        }
        return "";
    }

    /// Get the value of an attribute, or null if one doesn't exist.
    ///
    /// This interface isn't meant for frequent random access.
    pub fn getAttribute(self: LogRecord, key: []const u8) ?AttributeValue {
        for (self.attributes) |attr| {
            if (std.mem.eql(u8, attr.key, key)) {
                return attr.value;
            }
        }
        return null;
    }
};

test "LogRecord basic usage" {
    const testing = std.testing;

    const record = LogRecord{
        .timestamp_ns = 1234567890000000000,
        .severity_number = .info,
        .severity_text = "INFO",
        .body = .{ .string = "Test log message" },
    };

    try testing.expectEqual(@as(?i64, 1234567890000000000), record.timestamp_ns);
    try testing.expectEqual(Severity.info, record.severity_number);
    try testing.expectEqualStrings("INFO", record.severity_text.?);
    try testing.expectEqualStrings("Test log message", record.body.?.string);
    try testing.expect(!record.hasTraceContext());
}

test "LogRecord with trace context" {
    const testing = std.testing;

    const record = LogRecord{
        .severity_number = .debug,
        .body = .{ .string = "Debug message" },
        .trace_id = [_]u8{1} ** 16,
        .span_id = [_]u8{2} ** 8,
        .flags = 0x01,
    };

    try testing.expect(record.hasTraceContext());
    try testing.expectEqual(@as(?u8, 0x01), record.flags);

    var trace_buf: [32]u8 = undefined;
    const trace_str = try record.formatTraceId(&trace_buf);
    try testing.expectEqualStrings("01010101010101010101010101010101", trace_str);

    var span_buf: [16]u8 = undefined;
    const span_str = try record.formatSpanId(&span_buf);
    try testing.expectEqualStrings("0202020202020202", span_str);
}

test "LogRecord with attributes" {
    const testing = std.testing;

    const attrs = [_]KeyValue{
        KeyValue.init("user", .{ .string = "john" }),
        KeyValue.init("request_id", .{ .int = 12345 }),
    };

    const record = LogRecord{
        .severity_number = .warn,
        .body = .{ .string = "Warning message" },
        .attributes = &attrs,
    };

    try testing.expectEqual(@as(usize, 2), record.attributes.len);
    try testing.expectEqualStrings("user", record.attributes[0].key);
    try testing.expectEqualStrings("john", record.attributes[0].value.string);
}
