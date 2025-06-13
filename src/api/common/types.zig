//! Common types for OpenTelemetry in Zig
//!
//! This module contains shared type definitions used across different telemetry signals.
//! Note: ID generation logic is handled in the tracing module, while these types
//! provide consistent definitions for ID representation and manipulation.

const std = @import("std");

/// TraceId represents a unique identifier for a trace.
/// As per OpenTelemetry specification, it is 16 bytes (128 bits).
fn ByteId(length: comptime_int) type {
    return struct {
        const Self = @This();
        bytes: [length]u8,

        /// Creates a new TraceId from a byte array
        pub fn fromBytes(bytes: [length]u8) Self {
            return .{ .bytes = bytes };
        }

        /// Returns true if the TraceId is invalid (all zeros)
        pub fn isInvalid(self: Self) bool {
            for (self.bytes) |byte| {
                if (byte != 0) return false;
            }
            return true;
        }

        /// Returns true if the TraceId is valid (not all zeros)
        pub fn isValid(self: Self) bool {
            return !self.isInvalid();
        }

        /// Formats the TraceId as a hex string
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            for (self.bytes) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
        }

        /// Creates a TraceId from a hex string
        pub fn fromHexString(hex: []const u8) !Self {
            if (hex.len != length * 2) return error.InvalidLength;

            var bytes: [length]u8 = undefined;
            for (0..length) |i| {
                bytes[i] = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
            }
            return .{ .bytes = bytes };
        }
    };
}

pub const TraceId = ByteId(16);
pub const SpanId = ByteId(8);

test "TraceId validity checks" {
    const testing = std.testing;

    // Test invalid TraceId (all zeros)
    const invalid_trace_id = TraceId{ .bytes = [_]u8{0} ** 16 };
    try testing.expect(invalid_trace_id.isInvalid());
    try testing.expect(!invalid_trace_id.isValid());

    // Test valid TraceId
    const valid_trace_id = TraceId{ .bytes = [_]u8{1} ++ [_]u8{0} ** 15 };
    try testing.expect(!valid_trace_id.isInvalid());
    try testing.expect(valid_trace_id.isValid());
}

test "SpanId validity checks" {
    const testing = std.testing;

    // Test invalid SpanId (all zeros)
    const invalid_span_id = SpanId{ .bytes = [_]u8{0} ** 8 };
    try testing.expect(invalid_span_id.isInvalid());
    try testing.expect(!invalid_span_id.isValid());

    // Test valid SpanId
    const valid_span_id = SpanId{ .bytes = [_]u8{1} ++ [_]u8{0} ** 7 };
    try testing.expect(!valid_span_id.isInvalid());
    try testing.expect(valid_span_id.isValid());
}

test "TraceId hex string conversion" {
    const testing = std.testing;

    const hex_string = "0123456789abcdef0123456789abcdef";
    const trace_id = try TraceId.fromHexString(hex_string);

    var buffer: [32]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{}", .{trace_id});
    try testing.expectEqualStrings(hex_string, formatted);
}

test "SpanId hex string conversion" {
    const testing = std.testing;

    const hex_string = "0123456789abcdef";
    const span_id = try SpanId.fromHexString(hex_string);

    var buffer: [16]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{}", .{span_id});
    try testing.expectEqualStrings(hex_string, formatted);
}
