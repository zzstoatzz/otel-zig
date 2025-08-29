//! OpenTelemetry Span Limits Configuration
//!
//! This module defines configuration limits for spans according to the OpenTelemetry
//! specification. These limits help control resource usage and prevent unbounded
//! growth of span data.
//!
//! See: https://opentelemetry.io/docs/specs/otel/trace/sdk/#span-limits

const std = @import("std");

const Limits = @This();

/// SpanLimits defines the limits for various span components
/// Maximum number of attributes per span
max_attributes: u32 = 128,

/// Maximum number of events per span
max_events: u32 = 128,

/// Maximum number of links per span
max_links: u32 = 128,

/// Maximum number of attributes per event
max_attributes_per_event: u32 = 128,

/// Maximum number of attributes per link
max_attributes_per_link: u32 = 128,

/// Maximum length of attribute values in bytes
max_attribute_value_length: u32 = 4096,

/// Maximum length of attribute keys in bytes
max_attribute_key_length: u32 = 256,

/// Create SpanLimits with default values according to OpenTelemetry specification
pub const default: Limits = .{};

/// Create SpanLimits with unlimited values (use with caution)
pub const unlimited: Limits = .{
    .max_attributes = std.math.maxInt(u32),
    .max_events = std.math.maxInt(u32),
    .max_links = std.math.maxInt(u32),
    .max_attributes_per_event = std.math.maxInt(u32),
    .max_attributes_per_link = std.math.maxInt(u32),
    .max_attribute_value_length = std.math.maxInt(u32),
    .max_attribute_key_length = std.math.maxInt(u32),
};

/// Create SpanLimits with minimal values (useful for testing)
pub const minimal: Limits = .{
    .max_attributes = 1,
    .max_events = 1,
    .max_links = 1,
    .max_attributes_per_event = 1,
    .max_attributes_per_link = 1,
    .max_attribute_value_length = 64,
    .max_attribute_key_length = 32,
};

/// Check if the limits are effectively unlimited
pub fn isUnlimited(self: Limits) bool {
    const max_u32 = std.math.maxInt(u32);
    return self.max_attributes == max_u32 and
        self.max_events == max_u32 and
        self.max_links == max_u32 and
        self.max_attributes_per_event == max_u32 and
        self.max_attributes_per_link == max_u32 and
        self.max_attribute_value_length == max_u32 and
        self.max_attribute_key_length == max_u32;
}

/// Check if an attribute key length is within limits
pub fn isAttributeKeyLengthValid(self: Limits, key: []const u8) bool {
    return key.len <= self.max_attribute_key_length;
}

/// Check if an attribute value length is within limits
pub fn isAttributeValueLengthValid(self: Limits, value: []const u8) bool {
    return value.len <= self.max_attribute_value_length;
}

test "SpanLimits default values" {
    const testing = std.testing;

    const limits = Limits.default;

    // Verify OpenTelemetry specification defaults
    try testing.expectEqual(@as(u32, 128), limits.max_attributes);
    try testing.expectEqual(@as(u32, 128), limits.max_events);
    try testing.expectEqual(@as(u32, 128), limits.max_links);
    try testing.expectEqual(@as(u32, 128), limits.max_attributes_per_event);
    try testing.expectEqual(@as(u32, 128), limits.max_attributes_per_link);
    try testing.expectEqual(@as(u32, 4096), limits.max_attribute_value_length);
    try testing.expectEqual(@as(u32, 256), limits.max_attribute_key_length);

    try testing.expect(!limits.isUnlimited());
}

test "SpanLimits unlimited values" {
    const testing = std.testing;

    const limits = Limits.unlimited;
    const max_u32 = std.math.maxInt(u32);

    try testing.expectEqual(max_u32, limits.max_attributes);
    try testing.expectEqual(max_u32, limits.max_events);
    try testing.expectEqual(max_u32, limits.max_links);
    try testing.expectEqual(max_u32, limits.max_attributes_per_event);
    try testing.expectEqual(max_u32, limits.max_attributes_per_link);
    try testing.expectEqual(max_u32, limits.max_attribute_value_length);
    try testing.expectEqual(max_u32, limits.max_attribute_key_length);

    try testing.expect(limits.isUnlimited());
}

test "SpanLimits minimal values" {
    const testing = std.testing;

    const limits = Limits.minimal;

    try testing.expectEqual(@as(u32, 1), limits.max_attributes);
    try testing.expectEqual(@as(u32, 1), limits.max_events);
    try testing.expectEqual(@as(u32, 1), limits.max_links);
    try testing.expectEqual(@as(u32, 1), limits.max_attributes_per_event);
    try testing.expectEqual(@as(u32, 1), limits.max_attributes_per_link);
    try testing.expectEqual(@as(u32, 64), limits.max_attribute_value_length);
    try testing.expectEqual(@as(u32, 32), limits.max_attribute_key_length);

    try testing.expect(!limits.isUnlimited());
}

test "SpanLimits custom values" {
    const testing = std.testing;

    const limits = Limits{
        .max_attributes = 64,
        .max_events = 32,
        .max_links = 16,
        .max_attributes_per_event = 8,
        .max_attributes_per_link = 4,
        .max_attribute_value_length = 1024,
        .max_attribute_key_length = 128,
    };

    try testing.expectEqual(@as(u32, 64), limits.max_attributes);
    try testing.expectEqual(@as(u32, 32), limits.max_events);
    try testing.expectEqual(@as(u32, 16), limits.max_links);
    try testing.expectEqual(@as(u32, 8), limits.max_attributes_per_event);
    try testing.expectEqual(@as(u32, 4), limits.max_attributes_per_link);
    try testing.expectEqual(@as(u32, 1024), limits.max_attribute_value_length);
    try testing.expectEqual(@as(u32, 128), limits.max_attribute_key_length);

    try testing.expect(!limits.isUnlimited());
}

test "SpanLimits attribute validation" {
    const testing = std.testing;

    const limits = Limits{
        .max_attribute_key_length = 10,
        .max_attribute_value_length = 20,
    };

    // Test key length validation
    try testing.expect(limits.isAttributeKeyLengthValid("short"));
    try testing.expect(limits.isAttributeKeyLengthValid("1234567890")); // exactly 10
    try testing.expect(!limits.isAttributeKeyLengthValid("12345678901")); // 11, too long

    // Test value length validation
    try testing.expect(limits.isAttributeValueLengthValid("short value"));
    try testing.expect(limits.isAttributeValueLengthValid("12345678901234567890")); // exactly 20
    try testing.expect(!limits.isAttributeValueLengthValid("123456789012345678901")); // 21, too long
}

test "SpanLimits isUnlimited detection" {
    const testing = std.testing;

    // Default limits should not be unlimited
    try testing.expect(!Limits.default.isUnlimited());

    // Minimal limits should not be unlimited
    try testing.expect(!Limits.minimal.isUnlimited());

    // Unlimited limits should be detected
    try testing.expect(Limits.unlimited.isUnlimited());

    // Partially unlimited should not be detected as unlimited
    const partial = Limits{
        .max_attributes = std.math.maxInt(u32),
        .max_events = 100, // Not unlimited
        .max_links = std.math.maxInt(u32),
        .max_attributes_per_event = std.math.maxInt(u32),
        .max_attributes_per_link = std.math.maxInt(u32),
        .max_attribute_value_length = std.math.maxInt(u32),
        .max_attribute_key_length = std.math.maxInt(u32),
    };
    try testing.expect(!partial.isUnlimited());
}

test "SpanLimits edge cases" {
    const testing = std.testing;

    const limits = Limits{
        .max_attribute_key_length = 0,
        .max_attribute_value_length = 0,
    };

    // Zero-length limits should reject any non-empty strings
    try testing.expect(limits.isAttributeKeyLengthValid(""));
    try testing.expect(!limits.isAttributeKeyLengthValid("a"));

    try testing.expect(limits.isAttributeValueLengthValid(""));
    try testing.expect(!limits.isAttributeValueLengthValid("a"));
}
