//! OpenTelemetry Span Event
//!
//! Events are timestamped occurrences within a span that provide additional context
//! about what happened during the span's execution. Events are useful for logging
//! significant moments, exceptions, or other notable occurrences within a span.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#add-events

const std = @import("std");
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
const AttributeValue = @import("../common/root.zig").AttributeValue;

/// Event represents a timestamped occurrence within a span
pub const Event = struct {
    /// Human-readable name for the event
    name: []const u8,

    /// Timestamp of the event in nanoseconds since Unix epoch
    timestamp_ns: i64,

    /// Optional attributes providing additional context about the event
    attributes: ?[]const AttributeKeyValue,

    /// Check if this event has attributes
    pub fn hasAttributes(self: Event) bool {
        return self.attributes != null and self.attributes.?.len > 0;
    }

    /// Get the number of attributes
    pub fn getAttributeCount(self: Event) usize {
        return if (self.attributes) |attrs| attrs.len else 0;
    }

    /// Create a copy of this event with different attributes
    pub fn withAttributes(self: Event, attributes: ?[]const AttributeKeyValue) Event {
        return Event{
            .name = self.name,
            .timestamp_ns = self.timestamp_ns,
            .attributes = attributes,
        };
    }

    /// Create a copy of this event with a different timestamp
    pub fn withTimestamp(self: Event, timestamp_ns: i64) Event {
        return Event{
            .name = self.name,
            .timestamp_ns = timestamp_ns,
            .attributes = self.attributes,
        };
    }

    /// Create a copy of this event with a different name
    pub fn withName(self: Event, name: []const u8) Event {
        return Event{
            .name = name,
            .timestamp_ns = self.timestamp_ns,
            .attributes = self.attributes,
        };
    }

    /// Get timestamp as seconds since Unix epoch
    pub fn getTimestampSeconds(self: Event) f64 {
        return @as(f64, @floatFromInt(self.timestamp_ns)) / std.time.ns_per_s;
    }

    /// Get timestamp as milliseconds since Unix epoch
    pub fn getTimestampMillis(self: Event) i64 {
        return @divTrunc(self.timestamp_ns, std.time.ns_per_ms);
    }

    /// Get timestamp as microseconds since Unix epoch
    pub fn getTimestampMicros(self: Event) i64 {
        return @divTrunc(self.timestamp_ns, std.time.ns_per_us);
    }

    /// Format Event for debugging
    pub fn format(self: Event, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("Event{{name=\"{s}\", timestamp_ns={}", .{ self.name, self.timestamp_ns });

        if (self.attributes) |attrs| {
            if (attrs.len > 0) {
                try writer.writeAll(", attributes=[");
                for (attrs, 0..) |attr, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}={}", .{ std.fmt.fmtSliceEscapeUpper(attr.key), attr.value });
                }
                try writer.writeAll("]");
            }
        }

        try writer.writeAll("}");
    }
};

test "Event creation" {
    const timestamp = 1234567890123456789;
    const event = Event{
        .name = "test.event",
        .timestamp_ns = timestamp,
        .attributes = null,
    };

    try std.testing.expectEqualStrings("test.event", event.name);
    try std.testing.expectEqual(timestamp, event.timestamp_ns);
    try std.testing.expectEqual(@as(?[]const AttributeKeyValue, null), event.attributes);
    try std.testing.expect(!event.hasAttributes());
    try std.testing.expectEqual(@as(usize, 0), event.getAttributeCount());
}

test "Event direct creation" {
    const timestamp = 1234567890123456789;
    const event = Event{
        .name = "direct.event",
        .timestamp_ns = timestamp,
        .attributes = null,
    };

    try std.testing.expectEqualStrings("direct.event", event.name);
    try std.testing.expectEqual(timestamp, event.timestamp_ns);
    try std.testing.expectEqual(@as(?[]const AttributeKeyValue, null), event.attributes);
}

test "Event with attributes" {
    const attributes = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "event.type", .value = AttributeValue{ .string = "exception" } },
        AttributeKeyValue{ .key = "event.severity", .value = AttributeValue{ .string = "error" } },
        AttributeKeyValue{ .key = "event.count", .value = AttributeValue{ .int = 1 } },
    };

    const timestamp = 1234567890123456789;
    const event = Event{
        .name = "exception.occurred",
        .timestamp_ns = timestamp,
        .attributes = &attributes,
    };

    try std.testing.expectEqualStrings("exception.occurred", event.name);
    try std.testing.expectEqual(timestamp, event.timestamp_ns);
    try std.testing.expect(event.hasAttributes());
    try std.testing.expectEqual(@as(usize, 3), event.getAttributeCount());

    const attrs = event.attributes.?;
    try std.testing.expectEqualStrings("event.type", attrs[0].key);
    try std.testing.expectEqualStrings("exception", attrs[0].value.string);
    try std.testing.expectEqualStrings("event.severity", attrs[1].key);
    try std.testing.expectEqualStrings("error", attrs[1].value.string);
    try std.testing.expectEqualStrings("event.count", attrs[2].key);
    try std.testing.expectEqual(@as(i64, 1), attrs[2].value.int);
}

test "Event withAttributes" {
    const timestamp = 1234567890123456789;
    var event = Event{
        .name = "test.event",
        .timestamp_ns = timestamp,
        .attributes = null,
    };
    try std.testing.expect(!event.hasAttributes());

    const attributes = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "added.later", .value = AttributeValue{ .string = "yes" } },
    };

    event = event.withAttributes(&attributes);
    try std.testing.expect(event.hasAttributes());
    try std.testing.expectEqual(@as(usize, 1), event.getAttributeCount());
    try std.testing.expectEqualStrings("added.later", event.attributes.?[0].key);

    event = event.withAttributes(null);
    try std.testing.expect(!event.hasAttributes());
}

test "Event withTimestamp" {
    const original_timestamp = 1234567890123456789;
    const new_timestamp = 987654321012345678;

    var event = Event{
        .name = "test.event",
        .timestamp_ns = original_timestamp,
        .attributes = null,
    };
    try std.testing.expectEqual(original_timestamp, event.timestamp_ns);

    event = event.withTimestamp(new_timestamp);
    try std.testing.expectEqual(new_timestamp, event.timestamp_ns);
    try std.testing.expectEqualStrings("test.event", event.name);
}

test "Event withName" {
    const timestamp = 1234567890123456789;
    var event = Event{
        .name = "original.name",
        .timestamp_ns = timestamp,
        .attributes = null,
    };
    try std.testing.expectEqualStrings("original.name", event.name);

    event = event.withName("new.name");
    try std.testing.expectEqualStrings("new.name", event.name);
    try std.testing.expectEqual(timestamp, event.timestamp_ns);
}

test "Event timestamp conversions" {
    // Use a known timestamp: 2023-01-01 00:00:00 UTC = 1672531200 seconds
    const timestamp_ns: i64 = 1672531200 * std.time.ns_per_s + 123456789; // Add some nanoseconds
    const event = Event{
        .name = "timestamp.test",
        .timestamp_ns = timestamp_ns,
        .attributes = null,
    };

    const seconds = event.getTimestampSeconds();
    try std.testing.expectApproxEqRel(@as(f64, 1672531200.123456789), seconds, 0.000001);

    const millis = event.getTimestampMillis();
    try std.testing.expectEqual(@as(i64, 1672531200123), millis);

    const micros = event.getTimestampMicros();
    try std.testing.expectEqual(@as(i64, 1672531200123456), micros);
}

test "Event format simple" {
    const timestamp = 1234567890123456789;
    const event = Event{
        .name = "simple.event",
        .timestamp_ns = timestamp,
        .attributes = null,
    };

    var buf: [256]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{}", .{event});

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Event{name=\"simple.event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "timestamp_ns=1234567890123456789") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "attributes") == null); // No attributes section
}

test "Event format with attributes" {
    const attributes = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "level", .value = AttributeValue{ .string = "info" } },
        AttributeKeyValue{ .key = "count", .value = AttributeValue{ .int = 42 } },
    };

    const timestamp = 1234567890123456789;
    const event = Event{
        .name = "complex.event",
        .timestamp_ns = timestamp,
        .attributes = &attributes,
    };

    var buf: [512]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{}", .{event});

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Event{name=\"complex.event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "timestamp_ns=1234567890123456789") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "attributes=[") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "level=") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "count=") != null);
}

test "Event format empty attributes" {
    const timestamp = 1234567890123456789;
    const empty_attributes = [_]AttributeKeyValue{};
    const event = Event{
        .name = "empty.attrs",
        .timestamp_ns = timestamp,
        .attributes = &empty_attributes,
    };

    var buf: [256]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{}", .{event});

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Event{name=\"empty.attrs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "attributes") == null); // No attributes section for empty array
}
