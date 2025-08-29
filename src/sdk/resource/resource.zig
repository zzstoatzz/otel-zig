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
const sdk_version = @import("../root.zig").sdk_version;

/// Concrete resource implementation with owned attributes
pub const Resource = struct {
    attributes: []const AttributeKeyValue,
    schema_url: ?[]const u8 = null,

    /// SDK defaults for Resource
    pub const default: Resource = .{
        .schema_url = null,
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "telemetry.sdk.name", .value = .{ .string = "ibd1279/zig-otel" } },
            .{ .key = "telemetry.sdk.language", .value = .{ .string = "zig" } },
            .{ .key = "telemetry.sdk.version", .value = .{ .string = sdk_version } },
        },
    };

    /// An empty resource
    pub const empty: Resource = .{
        .schema_url = null,
        .attributes = &[_]AttributeKeyValue{},
    };

    /// Deep copy a Resource.
    pub fn initOwned(allocator: std.mem.Allocator, source: Resource) !Resource {
        const schema_url = if (source.schema_url) |url| try allocator.dupe(u8, url) else null;
        errdefer if (schema_url) |url| allocator.free(url);
        const attributes = try AttributeKeyValue.initOwnedSlice(allocator, source.attributes);
        errdefer AttributeKeyValue.deinitOwnedSlice(allocator, attributes);

        return .{
            .schema_url = schema_url,
            .attributes = attributes,
        };
    }

    /// Deep copy and dispose of the AttributeBuilder.
    pub fn initOwnedFromBuilder(allocator: std.mem.Allocator, resource_schema_url: ?[]const u8, attrs: *AttributeBuilder) !Resource {
        const schema_url = if (resource_schema_url) |url| try allocator.dupe(u8, url) else null;
        errdefer if (schema_url) |url| allocator.free(url);
        const attributes = try attrs.finish(allocator);
        errdefer AttributeKeyValue.deinitOwnedSlice(allocator, attributes);

        return .{
            .schema_url = schema_url,
            .attributes = attributes,
        };
    }

    pub fn deinitOwned(self: *const Resource, allocator: std.mem.Allocator) void {
        AttributeKeyValue.deinitOwnedSlice(allocator, self.attributes);
        if (self.schema_url) |url| allocator.free(url);
    }

    /// Merges two resources into one.
    ///
    /// The caller is responsible for calling `deinitOwned()` on
    /// the returned resource.
    pub fn initOwnedMerge(allocator: std.mem.Allocator, self: Resource, other: Resource) !Resource {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const merged_attrs = try AttributeBuilder.init(arena.allocator())
            .addMany(self.attributes)
            .addMany(other.attributes)
            .finish(allocator);
        errdefer AttributeKeyValue.deinitOwnedSlice(allocator, merged_attrs);

        // Schema URL precedence: other -> self -> null
        // Clone the schema URL to make it owned
        const schema_source = if (self.schema_url) |self_url| blk: {
            if (other.schema_url) |other_url| {
                if (std.mem.eql(u8, self_url, other_url)) {
                    break :blk self_url;
                } else {
                    otel_api.common.reportValidationError(
                        .resource,
                        "Resource.initOwnedMerge",
                        "Merging resources with different schemas",
                        null,
                    );
                    break :blk null;
                }
            } else {
                break :blk self_url;
            }
        } else other.schema_url;
        const owned_schema = if (schema_source) |url| try allocator.dupe(u8, url) else null;
        errdefer if (owned_schema) |url| allocator.free(url);

        return Resource{ .attributes = merged_attrs, .schema_url = owned_schema };
    }
};

test "Resource basic operations" {
    const testing = std.testing;

    const attrs = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "my-service" } },
        .{ .key = "service.version", .value = .{ .string = "1.0.0" } },
        .{ .key = "deployment.environment", .value = .{ .string = "production" } },
    };

    const resource = Resource{ .attributes = &attrs };

    // Test direct field access
    try testing.expectEqual(@as(usize, 3), resource.attributes.len);
    try testing.expect(resource.attributes.len > 0);

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
    const resource1 = Resource{ .attributes = &attrs1 };

    const attrs2 = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "service-b" } },
        .{ .key = "service.version", .value = .{ .string = "2.0.0" } },
    };
    const resource2 = Resource{ .attributes = &attrs2 };

    var merged = try Resource.initOwnedMerge(allocator, resource1, resource2);
    defer merged.deinitOwned(allocator);

    // service.name should be overridden by resource2
    const service_name = AttributeKeyValue.scanSlice(merged.attributes, "service.name");
    try testing.expect(service_name != null);
    try testing.expectEqualStrings("service-b", service_name.?.value.string);

    // host.name should remain from resource1
    const host_name = AttributeKeyValue.scanSlice(merged.attributes, "host.name");
    try testing.expect(host_name != null);
    try testing.expectEqualStrings("host1", host_name.?.value.string);

    // service.version should be added from resource2
    const service_version = AttributeKeyValue.scanSlice(merged.attributes, "service.version");
    try testing.expect(service_version != null);
    try testing.expectEqualStrings("2.0.0", service_version.?.value.string);
}

test "Empty resource" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var resource = Resource.empty;
    try testing.expectEqual(@as(usize, 0), resource.attributes.len);
    const attributes_ptr = resource.attributes.ptr;

    resource = try Resource.initOwned(allocator, resource);
    defer resource.deinitOwned(allocator);
    try testing.expectEqual(@as(usize, 0), resource.attributes.len);
    try testing.expect(attributes_ptr != resource.attributes.ptr);
}

test "Default resource" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var resource = Resource.default;
    try testing.expect(resource.attributes.len > 0);
    const attributes_ptr = resource.attributes.ptr;
    // Test expected default attributes
    var sdk_name = AttributeKeyValue.scanSlice(resource.attributes, "telemetry.sdk.name");
    try testing.expect(sdk_name != null);
    try testing.expectEqualStrings("ibd1279/zig-otel", sdk_name.?.value.string);

    var sdk_language = AttributeKeyValue.scanSlice(resource.attributes, "telemetry.sdk.language");
    try testing.expect(sdk_language != null);
    try testing.expectEqualStrings("zig", sdk_language.?.value.string);

    var sdk_version_attr = AttributeKeyValue.scanSlice(resource.attributes, "telemetry.sdk.version");
    try testing.expect(sdk_version_attr != null);
    try testing.expectEqualStrings(@import("../root.zig").sdk_version, sdk_version_attr.?.value.string);

    resource = try Resource.initOwned(allocator, resource);
    defer resource.deinitOwned(allocator);
    try testing.expect(resource.attributes.len > 0);
    try testing.expect(attributes_ptr != resource.attributes.ptr);

    // Test expected default attributes
    sdk_name = AttributeKeyValue.scanSlice(resource.attributes, "telemetry.sdk.name");
    try testing.expect(sdk_name != null);
    try testing.expectEqualStrings("ibd1279/zig-otel", sdk_name.?.value.string);

    sdk_language = AttributeKeyValue.scanSlice(resource.attributes, "telemetry.sdk.language");
    try testing.expect(sdk_language != null);
    try testing.expectEqualStrings("zig", sdk_language.?.value.string);

    sdk_version_attr = AttributeKeyValue.scanSlice(resource.attributes, "telemetry.sdk.version");
    try testing.expect(sdk_version_attr != null);
    try testing.expectEqualStrings(@import("../root.zig").sdk_version, sdk_version_attr.?.value.string);
}

test "Resource merge clones schema_url" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const attrs1 = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "service-a" } },
    };
    const resource1 = Resource{ .attributes = &attrs1, .schema_url = null };

    const attrs2 = [_]AttributeKeyValue{
        .{ .key = "service.version", .value = .{ .string = "1.0.0" } },
    };
    const resource2 = Resource{ .attributes = &attrs2, .schema_url = "https://schema2.example.com" };

    // Merge resources - should clone the schema_url from resource2 (precedence: other -> self)
    const merged = try Resource.initOwnedMerge(allocator, resource1, resource2);
    defer merged.deinitOwned(allocator);

    // Verify schema_url was copied from resource2 and is owned
    try testing.expect(merged.schema_url != null);
    try testing.expect(merged.schema_url.?.ptr != resource2.schema_url.?.ptr);
    if (merged.schema_url) |url| {
        try testing.expectEqualStrings("https://schema2.example.com", url);
        // The key test: this should not crash when we call deinitOwned
        // because the schema_url should be an owned copy
    }

    try testing.expectEqualStrings("service.name", merged.attributes[0].key);
    try testing.expectEqualStrings("service-a", merged.attributes[0].value.string);
    try testing.expectEqualStrings("service.version", merged.attributes[1].key);
    try testing.expectEqualStrings("1.0.0", merged.attributes[1].value.string);
}

test "ResourceBuilder duplicate key handling - no duplicates unchanged" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const attrs = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "my-service" } },
        .{ .key = "service.version", .value = .{ .string = "1.0.0" } },
        .{ .key = "environment", .value = .{ .string = "prod" } },
    };
    const resource = try Resource.initOwned(allocator, .{ .attributes = &attrs });
    defer resource.deinitOwned(allocator);

    try testing.expectEqual(@as(usize, 3), resource.attributes.len);

    // Should preserve original order and values
    try testing.expectEqualStrings("service.name", resource.attributes[0].key);
    try testing.expectEqualStrings("my-service", resource.attributes[0].value.string);
    try testing.expectEqualStrings("service.version", resource.attributes[1].key);
    try testing.expectEqualStrings("1.0.0", resource.attributes[1].value.string);
    try testing.expectEqualStrings("environment", resource.attributes[2].key);
    try testing.expectEqualStrings("prod", resource.attributes[2].value.string);
}

test "Resource with AttributeBuilder duplicate key handling - with merge operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a base resource with some attributes
    const base_attrs = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "base-service" } },
        .{ .key = "host.name", .value = .{ .string = "base-host" } },
    };
    var builder = AttributeBuilder.init(allocator).addMany(&base_attrs)
        .add(.{ .key = "service.name", .value = .{ .string = "builder-service" } }) // should win over base
        .add(.{ .key = "environment", .value = .{ .string = "prod" } })
        .add(.{ .key = "service.name", .value = .{ .string = "final-service" } }); // should win over previous.

    const resource = try Resource.initOwnedFromBuilder(allocator, null, &builder);
    defer resource.deinitOwned(allocator);

    try testing.expectEqual(@as(usize, 3), resource.attributes.len);

    // Find each attribute and verify final resolution
    const service_name = AttributeKeyValue.scanSlice(resource.attributes, "service.name");
    try testing.expect(service_name != null);
    try testing.expectEqualStrings("final-service", service_name.?.value.string);

    const host_name = AttributeKeyValue.scanSlice(resource.attributes, "host.name");
    try testing.expect(host_name != null);
    try testing.expectEqualStrings("base-host", host_name.?.value.string);

    const environment = AttributeKeyValue.scanSlice(resource.attributes, "environment");
    try testing.expect(environment != null);
    try testing.expectEqualStrings("prod", environment.?.value.string);
}

test "ResourceBuilder duplicate key handling - with merge" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test that withDefaults() properly handles duplicates with custom attributes
    var builder = AttributeBuilder.init(allocator)
        .add(.{ .key = "port", .value = .{ .int = 8080 } })
        .add(.{ .key = "telemetry.sdk.name", .value = .{ .string = "custom-sdk" } }) // should override default
        .add(.{ .key = "service.name", .value = .{ .string = "my-service" } })
        .add(.{ .key = "telemetry.sdk.name", .value = .{ .string = "final-sdk" } }); // should win
    const override = try Resource.initOwnedFromBuilder(allocator, null, &builder);
    defer override.deinitOwned(allocator);

    const resource = try Resource.initOwnedMerge(allocator, .default, override);
    defer resource.deinitOwned(allocator);

    // Should have defaults plus custom attributes, with duplicates resolved
    try testing.expect(resource.attributes.len >= 3); // At least the 3 default SDK attributes

    // Find the overridden SDK name, should be in the original order.
    try testing.expectEqualStrings("telemetry.sdk.name", resource.attributes[0].key);
    try testing.expectEqualStrings("final-sdk", resource.attributes[0].value.string);
    try testing.expectEqualStrings("telemetry.sdk.language", resource.attributes[1].key);
    try testing.expectEqualStrings("zig", resource.attributes[1].value.string);
    try testing.expectEqualStrings("telemetry.sdk.version", resource.attributes[2].key);
    try testing.expectEqualStrings(@import("../root.zig").sdk_version, resource.attributes[2].value.string);
    try testing.expectEqualStrings("port", resource.attributes[3].key);
    try testing.expectEqual(@as(i64, 8080), resource.attributes[3].value.int);
    try testing.expectEqualStrings("service.name", resource.attributes[4].key);
    try testing.expectEqualStrings("my-service", resource.attributes[4].value.string);
}
