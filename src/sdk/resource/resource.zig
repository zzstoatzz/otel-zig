//! OpenTelemetry SDK Resource Implementation
//!
//! This module provides the concrete implementation of Resource for the SDK.
//! A Resource represents the entity producing telemetry as a collection of attributes.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/resource/sdk.md

const std = @import("std");
const otel_api = @import("otel-api");

const AttributeValue = otel_api.common.AttributeValue;
const KeyValue = otel_api.common.KeyValue;
const AttributeBuilder = otel_api.common.AttributeBuilder;

/// Concrete resource implementation with owned attributes
pub const Resource = struct {
    attributes: []const KeyValue,
    schema_url: ?[]const u8,

    pub fn init(attributes: []const KeyValue, schema_url: ?[]const u8) !Resource {
        return Resource{
            .attributes = attributes,
            .schema_url = schema_url,
        };
    }

    pub fn deinitOwned(self: *const Resource, allocator: std.mem.Allocator) void {
        KeyValue.deinitOwnedSlice(allocator, self.attributes);
    }

    /// Convenience method for key-based attribute lookup
    pub fn getAttribute(self: *const Resource, key: []const u8) ?AttributeValue {
        for (self.attributes) |kv| {
            if (std.mem.eql(u8, kv.key, key)) {
                return kv.value;
            }
        }
        return null;
    }

    /// Merges two resources into one.
    ///
    /// The caller is responsible for calling `deinitOwned()` on
    /// the returned resource.
    pub fn merge(allocator: std.mem.Allocator, self: *const Resource, other: *const Resource) !Resource {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var builder = AttributeBuilder.init(arena.allocator());
        errdefer builder.deinit();

        try builder.addKeyValues(self.attributes);
        try builder.addKeyValues(other.attributes);

        const merged_attrs = try builder.finish(allocator);

        // Schema URL precedence: other -> self -> null
        const schema = other.schema_url orelse self.schema_url;

        return Resource.init(merged_attrs, schema);
    }
};

/// Get default resource with telemetry SDK information
pub fn getDefaultResource(allocator: std.mem.Allocator) !Resource {
    var attrs = std.ArrayList(KeyValue).init(allocator);
    defer attrs.deinit();
    
    try attrs.append(try KeyValue.initOwned(allocator, "telemetry.sdk.name", .{ .string = "opentelemetry" }));
    try attrs.append(try KeyValue.initOwned(allocator, "telemetry.sdk.language", .{ .string = "zig" }));
    try attrs.append(try KeyValue.initOwned(allocator, "telemetry.sdk.version", .{ .string = "0.1.0" }));
    
    return Resource.init(try attrs.toOwnedSlice(), null);
}

/// Get telemetry SDK resource attributes
pub fn getTelemetrySDKResource(allocator: std.mem.Allocator) !Resource {
    return getDefaultResource(allocator);
}

/// Create an empty resource
pub fn createEmptyResource(allocator: std.mem.Allocator) !Resource {
    const attrs = try allocator.alloc(KeyValue, 0);
    return Resource.init(attrs, null);
}

/// Create a resource with attributes
pub fn createResource(allocator: std.mem.Allocator, attributes: []const KeyValue) !Resource {
    const attrs = try allocator.dupe(KeyValue, attributes);
    return Resource.init(attrs, null);
}

test "Resource basic operations" {
    const testing = std.testing;

    const attrs = [_]KeyValue{
        KeyValue.init("service.name", .{ .string = "my-service" }),
        KeyValue.init("service.version", .{ .string = "1.0.0" }),
        KeyValue.init("deployment.environment", .{ .string = "production" }),
    };

    var resource = try Resource.init(&attrs, null);

    // Test direct field access
    try testing.expectEqual(@as(usize, 3), resource.attributes.len);
    try testing.expect(resource.attributes.len > 0);

    // Test convenience method
    try testing.expect(resource.getAttribute("service.name") != null);
    if (resource.getAttribute("service.name")) |value| {
        try testing.expectEqualStrings("my-service", value.string);
    }

    // Test direct iteration
    var found_service = false;
    for (resource.attributes) |kv| {
        if (std.mem.eql(u8, kv.key, "service.name")) {
            found_service = true;
            try testing.expectEqualStrings("my-service", kv.value.string);
        }
    }
    try testing.expect(found_service);
}

test "Resource merge" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const attrs1 = [_]KeyValue{
        KeyValue.init("service.name", .{ .string = "service-a" }),
        KeyValue.init("host.name", .{ .string = "host1" }),
    };
    var resource1 = try Resource.init(&attrs1, null);

    const attrs2 = [_]KeyValue{
        KeyValue.init("service.name", .{ .string = "service-b" }),
        KeyValue.init("service.version", .{ .string = "2.0.0" }),
    };
    var resource2 = try Resource.init(&attrs2, null);

    var merged = try Resource.merge(allocator, &resource1, &resource2);
    defer merged.deinitOwned(allocator);

    // service.name should be overridden by resource2
    if (merged.getAttribute("service.name")) |value| {
        try testing.expectEqualStrings("service-b", value.string);
    } else {
        try testing.expect(false);
    }

    // host.name should remain from resource1
    if (merged.getAttribute("host.name")) |value| {
        try testing.expectEqualStrings("host1", value.string);
    } else {
        try testing.expect(false);
    }

    // service.version should be added from resource2
    if (merged.getAttribute("service.version")) |value| {
        try testing.expectEqualStrings("2.0.0", value.string);
    } else {
        try testing.expect(false);
    }
}

test "Empty resource" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var resource = try createEmptyResource(allocator);
    defer allocator.free(resource.attributes);

    try testing.expectEqual(@as(usize, 0), resource.attributes.len);
    try testing.expect(resource.getAttribute("any.key") == null);
}

test "Default resource" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var resource = try getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);

    try testing.expect(resource.attributes.len > 0);
    try testing.expect(resource.getAttribute("telemetry.sdk.name") != null);
    try testing.expect(resource.getAttribute("telemetry.sdk.language") != null);
    try testing.expect(resource.getAttribute("telemetry.sdk.version") != null);

    if (resource.getAttribute("telemetry.sdk.language")) |value| {
        try testing.expectEqualStrings("zig", value.string);
    }
}
