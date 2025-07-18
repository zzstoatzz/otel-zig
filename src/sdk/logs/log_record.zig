//! OpenTelemetry Log Record API
//!
//! This module defines the LogRecord structure according to the OpenTelemetry specification.
//! A LogRecord represents a single log entry with associated metadata.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/data-model.md

const std = @import("std");
const api = @import("otel-api");

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
    severity_number: api.logs.Severity = .invalid,

    /// Human-readable severity text (optional)
    severity_text: ?[]const u8 = null,

    /// The log message body
    body: ?api.AttributeValue = null,

    /// Name that identifies the class/type of the event
    /// A log record with a non-empty event name is an Event according to OpenTelemetry spec
    event_name: ?[]const u8 = null,

    /// Additional attributes associated with the log record
    attributes: []const api.AttributeKeyValue = &[_]api.AttributeKeyValue{},

    /// TraceId of the span that this log record is associated with
    trace_id: ?api.common.TraceId = null,

    /// SpanId of the span that this log record is associated with
    span_id: ?api.common.SpanId = null,

    /// Trace flags (1 byte)
    flags: ?u8 = null,

    /// Instrumentation scope that produced this log record.
    instrumentation_scope: ?api.InstrumentationScope = null,

    /// Check if this log record is associated with a trace
    pub fn hasTraceContext(self: *const LogRecord) bool {
        return self.trace_id != null and self.span_id != null;
    }

    /// Get the severity number as an integer
    pub fn severityNumber(self: *const LogRecord) i32 {
        return @intFromEnum(self.severity_number);
    }

    /// Format trace ID as hex string (requires a buffer of at least 32 bytes)
    pub fn formatTraceId(self: *const LogRecord, buf: []u8) ![]const u8 {
        if (self.trace_id) |tid| {
            if (buf.len < 32) return error.BufferTooSmall;
            return std.fmt.bufPrint(buf, "{}", .{tid});
        }
        return "";
    }

    /// Format span ID as hex string (requires a buffer of at least 16 bytes)
    pub fn formatSpanId(self: *const LogRecord, buf: []u8) ![]const u8 {
        if (self.span_id) |sid| {
            if (buf.len < 16) return error.BufferTooSmall;
            return std.fmt.bufPrint(buf, "{}", .{sid});
        }
        return "";
    }

    /// Get the value of an attribute, or null if one doesn't exist.
    ///
    /// This interface isn't meant for frequent random access.
    pub fn getAttribute(self: *const LogRecord, key: []const u8) ?api.AttributeValue {
        for (self.attributes) |attr| {
            if (std.mem.eql(u8, attr.key, key)) {
                return attr.value;
            }
        }
        return null;
    }
};
