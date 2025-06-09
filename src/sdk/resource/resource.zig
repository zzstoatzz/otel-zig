//! OpenTelemetry SDK Resource Implementation
//!
//! This module provides the concrete implementation of Resource for the SDK.
//! A Resource represents the entity producing telemetry as a collection of attributes.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/resource/sdk.md

const std = @import("std");
const otel_api = @import("otel-api");

const AttributeValue = otel_api.common.AttributeValue;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const AttributeBuilder = otel_api.common.AttributeBuilder;

/// Concrete resource implementation with owned attributes
pub const Resource = struct {
    attributes: []const AttributeKeyValue,
    schema_url: ?[]const u8,

    /// SDK defaults for Resource
    pub const default: Resource = .{
        .schema_url = null,
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "telemetry.sdk.name", .value = .{ .string = "opentelemetry" } },
            .{ .key = "telemetry.sdk.language", .value = .{ .string = "zig" } },
            .{ .key = "telemetry.sdk.version", .value = .{ .string = "0.1.0" } },
        },
    };

    /// An empty resource
    pub const empty: Resource = .{
        .schema_url = null,
        .attributes = &[_]AttributeKeyValue{},
    };

    pub fn init(attributes: []const AttributeKeyValue, schema_url: ?[]const u8) !Resource {
        return Resource{
            .attributes = attributes,
            .schema_url = schema_url,
        };
    }

    pub fn deinitOwned(self: *const Resource, allocator: std.mem.Allocator) void {
        AttributeKeyValue.deinitOwnedSlice(allocator, self.attributes);
        if (self.schema_url) |url| allocator.free(url);
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
    pub fn merge(allocator: std.mem.Allocator, self: Resource, other: Resource) !Resource {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var builder = AttributeBuilder.init(arena.allocator());

        builder = builder.addKeyValues(other.attributes);
        builder = builder.addKeyValues(self.attributes);

        const merged_attrs = try builder.finish(allocator);

        // Schema URL precedence: other -> self -> null
        const schema = other.schema_url orelse self.schema_url;

        return Resource.init(merged_attrs, schema);
    }
};

pub const ResourceBuilder = union(enum) {
    valid: struct {
        allocator: std.mem.Allocator,
        attributes: []AttributeKeyValue,
        schema_url: ?[]const u8,
    },
    invalid: anyerror,

    pub fn init(allocator: std.mem.Allocator) ResourceBuilder {
        return ResourceBuilder{ .valid = .{
            .allocator = allocator,
            .attributes = &[_]AttributeKeyValue{},
            .schema_url = null,
        } };
    }

    pub fn deinit(self: ResourceBuilder) void {
        switch (self) {
            .valid => |builder| {
                builder.allocator.free(builder.attributes);
            },
            .invalid => {},
        }
    }

    // Return
    pub fn finish(self: ResourceBuilder, allocator: std.mem.Allocator) !Resource {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                const owned_schema_url = if (builder.schema_url) |url| try allocator.dupe(u8, url) else null;
                errdefer if (owned_schema_url) |url| allocator.free(url);

                const kvs = try AttributeKeyValue.initOwnedSlice(allocator, builder.attributes);
                errdefer AttributeKeyValue.deinitOwnedSlice(allocator, kvs);

                const resource = Resource{
                    .schema_url = owned_schema_url,
                    .attributes = kvs,
                };
                break :blk resource;
            },
            .invalid => |e| e,
        };
    }

    pub fn addResource(self: ResourceBuilder, resource: Resource) ResourceBuilder {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                const new_len = builder.attributes.len + resource.attributes.len;
                var new_attributes = builder.allocator.alloc(AttributeKeyValue, new_len) catch |e| return ResourceBuilder{ .invalid = e };
                errdefer builder.allocator.free(new_attributes);
                @memcpy(new_attributes[0..builder.attributes.len], builder.attributes);
                @memcpy(new_attributes[builder.attributes.len..], resource.attributes);

                break :blk ResourceBuilder{
                    .valid = .{
                        .allocator = builder.allocator,
                        .schema_url = resource.schema_url,
                        .attributes = new_attributes,
                    },
                };
            },
            .invalid => self,
        };
    }

    pub fn addKeyValue(self: ResourceBuilder, kv: AttributeKeyValue) ResourceBuilder {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                const new_len = builder.attributes.len + 1;
                var new_attributes = builder.allocator.alloc(AttributeKeyValue, new_len) catch |e| return ResourceBuilder{ .invalid = e };
                errdefer builder.allocator.free(new_attributes);
                @memcpy(new_attributes[0..builder.attributes.len], builder.attributes);
                new_attributes[builder.attributes.len] = kv;

                break :blk ResourceBuilder{
                    .valid = .{
                        .allocator = builder.allocator,
                        .schema_url = builder.schema_url,
                        .attributes = new_attributes,
                    },
                };
            },
            .invalid => self,
        };
    }
};

/// Get default resource with telemetry SDK information
pub fn getDefaultResource(allocator: std.mem.Allocator) !Resource {
    var attrs = std.ArrayList(AttributeKeyValue).init(allocator);
    defer attrs.deinit();

    try attrs.append(try AttributeKeyValue.initOwned(allocator, "telemetry.sdk.name", .{ .string = "opentelemetry" }));
    try attrs.append(try AttributeKeyValue.initOwned(allocator, "telemetry.sdk.language", .{ .string = "zig" }));
    try attrs.append(try AttributeKeyValue.initOwned(allocator, "telemetry.sdk.version", .{ .string = "0.1.0" }));

    return Resource.init(try attrs.toOwnedSlice(), null);
}

/// Get telemetry SDK resource attributes
pub fn getTelemetrySDKResource(allocator: std.mem.Allocator) !Resource {
    return getDefaultResource(allocator);
}

/// Create an empty resource
pub fn createEmptyResource(allocator: std.mem.Allocator) !Resource {
    const attrs = try allocator.alloc(AttributeKeyValue, 0);
    return Resource.init(attrs, null);
}

test "Resource basic operations" {
    const testing = std.testing;

    const attrs = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "my-service" } },
        .{ .key = "service.version", .value = .{ .string = "1.0.0" } },
        .{ .key = "deployment.environment", .value = .{ .string = "production" } },
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

    const attrs1 = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "service-a" } },
        .{ .key = "host.name", .value = .{ .string = "host1" } },
    };
    const resource1 = try Resource.init(&attrs1, null);

    const attrs2 = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "service-b" } },
        .{ .key = "service.version", .value = .{ .string = "2.0.0" } },
    };
    const resource2 = try Resource.init(&attrs2, null);

    var merged = try Resource.merge(allocator, resource1, resource2);
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
