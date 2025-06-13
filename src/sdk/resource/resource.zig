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
        // Clone the schema URL to make it owned
        const schema_source = other.schema_url orelse self.schema_url;
        const owned_schema = if (schema_source) |url| try allocator.dupe(u8, url) else null;

        return Resource.init(merged_attrs, owned_schema);
    }
};

/// ResourceBuilder provides a fluent interface for constructing Resources.
///
/// Example usage:
/// ```zig
/// const resource = try ResourceBuilder.init(allocator)
///     .withDefaults()  // Add telemetry.sdk.* attributes
///     .addKeyValue(.{ .key = "service.name", .value = .{ .string = "my-service" }})
///     .withSchemaUrl("https://opentelemetry.io/schemas/1.21.0")
///     .finish(allocator);
/// defer resource.deinitOwned(allocator);
/// ```
///
/// Note: Later added values overwrite earlier added values.
///
/// The builder pattern is the recommended way to create Resources in the SDK,
/// as it handles attribute merging and memory management cleanly.
pub const ResourceBuilder = union(enum) {
    valid: struct {
        allocator: std.mem.Allocator,
        attributes: AttributeBuilder,
        schema_url: ?[]const u8,
    },
    invalid: anyerror,

    /// Create a new, blank ResourceBuilder.
    ///
    /// The `allocator` is used for the intermediatary Builder state, and has
    /// no impact on the memory ownership of the result from calling `finish()`.
    pub fn init(allocator: std.mem.Allocator) ResourceBuilder {
        const attr_builder = AttributeBuilder.init(allocator);
        return .{ .valid = .{
            .allocator = allocator,
            .attributes = attr_builder,
            .schema_url = null,
        } };
    }

    /// Release local copy of the memory.
    pub fn deinit(self: ResourceBuilder) void {
        switch (self) {
            .valid => |builder| {
                builder.attributes.deinit();
            },
            .invalid => {},
        }
    }

    /// Get the deep copy slice of `AttributeKeyValue` and `schema_url`, then
    /// destroy this builder.
    ///
    /// The provided allocator will be used for the resulting resource, not the
    /// allocator provided when the builder was created.
    ///
    /// Returned slice must be released with `Resource.deinitOwned` to
    /// release the keys, the values, and the schema url.
    pub fn finish(self: ResourceBuilder, allocator: std.mem.Allocator) !Resource {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                // if the attribute builder cannot provide attributes,
                // surface the error, and let the `defer self.deinit()`
                // takeover.
                const attributes = try AttributeKeyValue.initOwnedSlice(
                    allocator,
                    try builder.attributes.build(),
                );
                errdefer AttributeKeyValue.deinitOwnedSlice(allocator, attributes);

                const owned_schema_url = if (builder.schema_url) |url| try allocator.dupe(u8, url) else null;
                errdefer if (owned_schema_url) |url| allocator.free(url);

                break :blk .{
                    .attributes = attributes,
                    .schema_url = owned_schema_url,
                };
            },
            .invalid => |e| e,
        };
    }

    pub inline fn withDefaults(self: ResourceBuilder) ResourceBuilder {
        return self.addResource(.default);
    }

    /// Adds a resource to the builder. This is effecitively the merge
    /// operation.
    ///
    /// The resource must like longer than the builder.
    pub fn addResource(self: ResourceBuilder, resource: Resource) ResourceBuilder {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                // if the attribute builder cannot provide attributes,
                // invalidate the builder, and let the `defer self.deinit()`
                // takeover.
                const self_kvs = builder.attributes.build() catch |e| {
                    break :blk .{ .invalid = e };
                };

                // Merge the attributes.
                const attr_builder = AttributeBuilder.init(builder.allocator)
                    .addKeyValues(self_kvs)
                    .addKeyValues(resource.attributes);
                errdefer attr_builder.deinit();

                // Take the new schema url if it isn't null.
                const schema_url = resource.schema_url orelse builder.schema_url;

                break :blk .{
                    .valid = .{
                        .allocator = builder.allocator,
                        .attributes = attr_builder,
                        .schema_url = schema_url,
                    },
                };
            },
            .invalid => self,
        };
    }

    /// Add Attributes to the resource builder.
    ///
    /// The slice of attributeKeyValues must live longer than the builder.
    pub fn addKeyValues(self: ResourceBuilder, kvs: []const AttributeKeyValue) ResourceBuilder {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                // if the attribute builder cannot provide attributes,
                // invalidate the builder, and let the `defer self.deinit()`
                // takeover.
                const self_kvs = builder.attributes.build() catch |e| {
                    break :blk .{ .invalid = e };
                };

                // Merge the attributes.
                const attr_builder = AttributeBuilder.init(builder.allocator)
                    .addKeyValues(self_kvs)
                    .addKeyValues(kvs);
                errdefer attr_builder.deinit();

                break :blk .{
                    .valid = .{
                        .allocator = builder.allocator,
                        .attributes = attr_builder,
                        .schema_url = builder.schema_url,
                    },
                };
            },
            .invalid => self,
        };
    }

    /// Add an attribute to the resource builder.
    ///
    /// The AttributeKeyValues must live longer than the builder.
    pub fn addKeyValue(self: ResourceBuilder, kv: AttributeKeyValue) ResourceBuilder {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                // if the attribute builder cannot provide attributes,
                // invalidate the builder, and let the `defer self.deinit()`
                // takeover.
                const self_kvs = builder.attributes.build() catch |e| {
                    break :blk .{ .invalid = e };
                };

                // Merge the attributes.
                const attr_builder = AttributeBuilder.init(builder.allocator)
                    .addKeyValues(self_kvs)
                    .addKeyValue(kv);
                errdefer attr_builder.deinit();

                break :blk .{
                    .valid = .{
                        .allocator = builder.allocator,
                        .attributes = attr_builder,
                        .schema_url = builder.schema_url,
                    },
                };
            },
            .invalid => self,
        };
    }

    /// Add a schema url.
    ///
    /// If the `url` argument is null, this method unsets the schema url.
    pub fn addSchemaUrl(self: ResourceBuilder, url: ?[]const u8) ResourceBuilder {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                // if the attribute builder cannot provide attributes,
                // invalidate the builder, and let the `defer self.deinit()`
                // takeover.
                const self_kvs = builder.attributes.build() catch |e| {
                    break :blk .{ .invalid = e };
                };

                // make the new attributes builder.
                const attr_builder = AttributeBuilder.init(builder.allocator)
                    .addKeyValues(self_kvs);
                errdefer attr_builder.deinit();

                break :blk .{
                    .valid = .{
                        .allocator = builder.allocator,
                        .attributes = attr_builder,
                        .schema_url = url,
                    },
                };
            },
            .invalid => self,
        };
    }
};

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

    var resource = try ResourceBuilder.init(allocator).finish(allocator);
    defer resource.deinitOwned(allocator);

    try testing.expectEqual(@as(usize, 0), resource.attributes.len);
    try testing.expect(resource.getAttribute("any.key") == null);
}

test "Default resource" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var resource = try ResourceBuilder.init(allocator).withDefaults().finish(allocator);
    defer resource.deinitOwned(allocator);

    try testing.expect(resource.attributes.len > 0);
    try testing.expect(resource.getAttribute("telemetry.sdk.name") != null);
    try testing.expect(resource.getAttribute("telemetry.sdk.language") != null);
    try testing.expect(resource.getAttribute("telemetry.sdk.version") != null);

    const sdk_name = resource.getAttribute("telemetry.sdk.name").?;
    try testing.expectEqualStrings("opentelemetry", sdk_name.string);
}

test "Resource merge clones schema_url" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const attrs1 = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "service-a" } },
    };
    const resource1 = try Resource.init(&attrs1, "https://schema1.example.com");

    const attrs2 = [_]AttributeKeyValue{
        .{ .key = "service.version", .value = .{ .string = "1.0.0" } },
    };
    const resource2 = try Resource.init(&attrs2, "https://schema2.example.com");

    // Merge resources - should clone the schema_url from resource2 (precedence: other -> self)
    const merged = try Resource.merge(allocator, resource1, resource2);
    defer merged.deinitOwned(allocator);

    // Verify schema_url was copied from resource2 and is owned
    try testing.expect(merged.schema_url != null);
    if (merged.schema_url) |url| {
        try testing.expectEqualStrings("https://schema2.example.com", url);
        // The key test: this should not crash when we call deinitOwned
        // because the schema_url should be an owned copy
    }
}
