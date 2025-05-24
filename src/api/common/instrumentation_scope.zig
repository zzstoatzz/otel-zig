//! OpenTelemetry InstrumentationScope - Identifies the instrumentation library
//!
//! InstrumentationScope represents the instrumentation library/framework that
//! generated the telemetry data. It identifies the source of instrumentation
//! and provides metadata about the library version and schema.
//!
//! ## Memory Management
//! InstrumentationScope is NON-OWNING - it only holds references to data.
//! The caller is responsible for ensuring the lifetime of all referenced data.
//!
//! ## Key Properties
//! - Name (required): Identifies the instrumentation library
//! - Version (optional): Version of the instrumentation library
//! - Schema URL (optional): URL to the schema used by the library
//! - Attributes (optional): Additional metadata about the scope
//!
//! ## Usage
//! ```zig
//! // Simple scope with just name
//! const scope = try InstrumentationScope.init("my-library", null, null, &[_]KeyValue{});
//!
//! // Scope with version and schema
//! const scope = try InstrumentationScope.init("my-library", "1.0.0", "https://schema.url", &attrs);
//!
//! // Using convenience methods
//! const scope = try InstrumentationScope.initSimple("my-library", "1.0.0");
//! ```

const std = @import("std");
const AttributeValue = @import("attributes.zig").AttributeValue;
const KeyValue = @import("attributes.zig").KeyValue;

/// InstrumentationScope identifies the instrumentation library that generated telemetry data
/// Non-owning and immutable after creation following OpenTelemetry specification
pub const InstrumentationScope = struct {
    /// Name of the instrumentation library (REQUIRED, non-owning)
    /// Must be non-empty and identifies the instrumentation
    name: []const u8,

    /// Version of the instrumentation library (OPTIONAL, non-owning)
    /// Should follow semantic versioning when specified
    version: ?[]const u8,

    /// Schema URL for the telemetry emitted by the library (OPTIONAL, non-owning)
    /// Points to the schema definition for the data
    schema_url: ?[]const u8,

    /// Additional attributes about the instrumentation scope (OPTIONAL, non-owning)
    /// Provides extra metadata about the scope
    attributes: []const KeyValue,

    /// Create a new InstrumentationScope with all parameters
    pub fn init(
        name: []const u8,
        version: ?[]const u8,
        schema_url: ?[]const u8,
        attributes: []const KeyValue,
    ) !InstrumentationScope {
        // Name is required and must be non-empty
        if (name.len == 0) {
            return error.EmptyInstrumentationScopeName;
        }

        return InstrumentationScope{
            .name = name,
            .version = version,
            .schema_url = schema_url,
            .attributes = attributes,
        };
    }

    /// Create a simple InstrumentationScope with just name and optional version
    pub fn initSimple(name: []const u8, version: ?[]const u8) !InstrumentationScope {
        return init(name, version, null, &[_]KeyValue{});
    }

    /// Create an InstrumentationScope with just a name
    pub fn initWithName(name: []const u8) !InstrumentationScope {
        return init(name, null, null, &[_]KeyValue{});
    }

    /// Create an empty/default InstrumentationScope
    /// Uses "unknown" as the default name per OpenTelemetry conventions
    pub const empty: InstrumentationScope = .{
        .attributes = &[_]KeyValue{},
        .name = "unknown",
        .schema_url = null,
        .version = null,
    };

    /// Get an attribute by key
    pub fn getAttribute(self: InstrumentationScope, key: []const u8) ?AttributeValue {
        for (self.attributes) |attr| {
            if (std.mem.eql(u8, attr.key, key)) {
                return attr.value;
            }
        }
        return null;
    }

    /// Check if scope has an attribute with the given key
    pub fn hasAttribute(self: InstrumentationScope, key: []const u8) bool {
        return self.getAttribute(key) != null;
    }

    /// Check if two InstrumentationScopes are equal
    /// Two scopes are equal if all their fields match exactly
    pub fn eql(self: InstrumentationScope, other: InstrumentationScope) bool {
        // Check name (required field)
        if (!std.mem.eql(u8, self.name, other.name)) {
            return false;
        }

        // Check version (optional field)
        if (!optionalStringEql(self.version, other.version)) {
            return false;
        }

        // Check schema URL (optional field)
        if (!optionalStringEql(self.schema_url, other.schema_url)) {
            return false;
        }

        // Check attributes count
        if (self.attributes.len != other.attributes.len) {
            return false;
        }

        // Check each attribute (order doesn't matter for equality)
        for (self.attributes) |self_attr| {
            var found = false;
            for (other.attributes) |other_attr| {
                if (self_attr.eql(other_attr)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return false;
            }
        }

        return true;
    }

    /// Create a hash code for the instrumentation scope
    /// Useful for hash maps and performance optimizations
    pub fn hashCode(self: InstrumentationScope) u64 {
        var hasher = std.hash.Wyhash.init(0);
        
        // Hash the name (always present)
        hasher.update(self.name);
        
        // Hash the version if present
        if (self.version) |version| {
            hasher.update(version);
        }
        
        // Hash the schema URL if present
        if (self.schema_url) |url| {
            hasher.update(url);
        }

        // Hash attribute count (we don't hash the full attributes for performance)
        const attr_count = @as(u64, @intCast(self.attributes.len));
        hasher.update(std.mem.asBytes(&attr_count));

        return hasher.final();
    }

    /// Format the InstrumentationScope for debugging/logging
    pub fn format(
        self: InstrumentationScope,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("InstrumentationScope{{name=\"{s}\"", .{self.name});

        if (self.version) |version| {
            try writer.print(", version=\"{s}\"", .{version});
        }

        if (self.schema_url) |url| {
            try writer.print(", schema_url=\"{s}\"", .{url});
        }

        if (self.attributes.len > 0) {
            try writer.print(", attributes=[", .{});
            for (self.attributes, 0..) |attr, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{}", .{attr});
            }
            try writer.writeAll("]");
        }

        try writer.writeAll("}");
    }

    /// Helper function to compare optional strings
    fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }
};

// Tests
test "InstrumentationScope creation and basic operations" {
    const testing = std.testing;

    // Test simple scope with just name
    const scope1 = try InstrumentationScope.initWithName("test-library");
    try testing.expectEqualStrings("test-library", scope1.name);
    try testing.expect(scope1.version == null);
    try testing.expect(scope1.schema_url == null);
    try testing.expect(scope1.attributes.len == 0);

    // Test scope with name and version
    const scope2 = try InstrumentationScope.initSimple("test-library", "1.0.0");
    try testing.expectEqualStrings("test-library", scope2.name);
    try testing.expectEqualStrings("1.0.0", scope2.version.?);
    try testing.expect(scope2.schema_url == null);
    try testing.expect(scope2.attributes.len == 0);

    // Test full scope
    const attrs = [_]KeyValue{
        .{ .key = "library.language", .value = .{ .string = "zig" } },
        .{ .key = "library.version", .value = .{ .string = "0.12.0" } },
    };

    const scope3 = try InstrumentationScope.init(
        "test-library",
        "1.0.0",
        "https://example.com/schema",
        &attrs,
    );

    try testing.expectEqualStrings("test-library", scope3.name);
    try testing.expectEqualStrings("1.0.0", scope3.version.?);
    try testing.expectEqualStrings("https://example.com/schema", scope3.schema_url.?);
    try testing.expect(scope3.attributes.len == 2);

    // Test getAttribute
    const lang = scope3.getAttribute("library.language");
    try testing.expect(lang != null);
    try testing.expectEqualStrings("zig", lang.?.string);

    const missing = scope3.getAttribute("missing.key");
    try testing.expect(missing == null);

    // Test hasAttribute
    try testing.expect(scope3.hasAttribute("library.language"));
    try testing.expect(!scope3.hasAttribute("missing.key"));
}

test "InstrumentationScope empty constant and error cases" {
    const testing = std.testing;

    // Test empty scope constant
    const empty_scope = InstrumentationScope.empty;
    try testing.expectEqualStrings("unknown", empty_scope.name);
    try testing.expect(empty_scope.version == null);
    try testing.expect(empty_scope.schema_url == null);
    try testing.expect(empty_scope.attributes.len == 0);

    // Test error case - empty name
    try testing.expectError(
        error.EmptyInstrumentationScopeName,
        InstrumentationScope.init("", null, null, &[_]KeyValue{}),
    );
}

test "InstrumentationScope equality" {
    const testing = std.testing;

    const scope1 = try InstrumentationScope.initSimple("test-library", "1.0.0");
    const scope2 = try InstrumentationScope.initSimple("test-library", "1.0.0");
    const scope3 = try InstrumentationScope.initSimple("test-library", "1.1.0");
    const scope4 = try InstrumentationScope.initSimple("other-library", "1.0.0");

    // Same scopes should be equal
    try testing.expect(scope1.eql(scope2));

    // Different versions should not be equal
    try testing.expect(!scope1.eql(scope3));

    // Different names should not be equal
    try testing.expect(!scope1.eql(scope4));


}

test "InstrumentationScope with attributes equality" {
    const testing = std.testing;

    const attrs1 = [_]KeyValue{
        .{ .key = "language", .value = .{ .string = "zig" } },
        .{ .key = "version", .value = .{ .string = "0.12.0" } },
    };

    const attrs2 = [_]KeyValue{
        .{ .key = "version", .value = .{ .string = "0.12.0" } },
        .{ .key = "language", .value = .{ .string = "zig" } },
    };

    const attrs3 = [_]KeyValue{
        .{ .key = "language", .value = .{ .string = "rust" } },
        .{ .key = "version", .value = .{ .string = "0.12.0" } },
    };

    const scope1 = try InstrumentationScope.init("test", "1.0.0", null, &attrs1);
    const scope2 = try InstrumentationScope.init("test", "1.0.0", null, &attrs2);
    const scope3 = try InstrumentationScope.init("test", "1.0.0", null, &attrs3);

    // Same attributes in different order should be equal
    try testing.expect(scope1.eql(scope2));

    // Different attribute values should not be equal
    try testing.expect(!scope1.eql(scope3));
}

test "InstrumentationScope optional field handling" {
    const testing = std.testing;

    // Test various combinations of optional fields
    const scope_none = try InstrumentationScope.init("test", null, null, &[_]KeyValue{});
    const scope_version = try InstrumentationScope.init("test", "1.0.0", null, &[_]KeyValue{});
    const scope_schema = try InstrumentationScope.init("test", null, "https://schema.url", &[_]KeyValue{});
    const scope_both = try InstrumentationScope.init("test", "1.0.0", "https://schema.url", &[_]KeyValue{});

    // Test equality with different optional field combinations
    try testing.expect(!scope_none.eql(scope_version));
    try testing.expect(!scope_none.eql(scope_schema));
    try testing.expect(!scope_none.eql(scope_both));
    try testing.expect(!scope_version.eql(scope_schema));
    try testing.expect(!scope_version.eql(scope_both));
    try testing.expect(!scope_schema.eql(scope_both));


}

test "InstrumentationScope hash code" {
    const testing = std.testing;

    const scope1 = try InstrumentationScope.initSimple("test-library", "1.0.0");
    const scope2 = try InstrumentationScope.initSimple("test-library", "1.0.0");
    const scope3 = try InstrumentationScope.initSimple("test-library", "1.1.0");
    const scope4 = try InstrumentationScope.initSimple("other-library", "1.0.0");

    const hash1 = scope1.hashCode();
    const hash2 = scope2.hashCode();
    const hash3 = scope3.hashCode();
    const hash4 = scope4.hashCode();

    // Same scopes should have same hash
    try testing.expect(hash1 == hash2);

    // Different scopes should likely have different hashes (not guaranteed but very likely)
    try testing.expect(hash1 != hash3);
    try testing.expect(hash1 != hash4);
    try testing.expect(hash3 != hash4);
}

test "InstrumentationScope formatting" {
    const testing = std.testing;

    var buf: [512]u8 = undefined;

    // Simple scope
    const scope1 = try InstrumentationScope.initWithName("test-library");
    const str1 = try std.fmt.bufPrint(&buf, "{}", .{scope1});
    try testing.expectEqualStrings("InstrumentationScope{name=\"test-library\"}", str1);

    // Scope with version
    const scope2 = try InstrumentationScope.initSimple("test-library", "1.0.0");
    const str2 = try std.fmt.bufPrint(&buf, "{}", .{scope2});
    try testing.expectEqualStrings("InstrumentationScope{name=\"test-library\", version=\"1.0.0\"}", str2);

    // Full scope with attributes
    const attrs = [_]KeyValue{
        .{ .key = "lang", .value = .{ .string = "zig" } },
    };
    const scope3 = try InstrumentationScope.init("test", "1.0.0", "https://schema.url", &attrs);
    const str3 = try std.fmt.bufPrint(&buf, "{}", .{scope3});
    const expected = "InstrumentationScope{name=\"test\", version=\"1.0.0\", schema_url=\"https://schema.url\", attributes=[lang=\"zig\"]}";
    try testing.expectEqualStrings(expected, str3);

    // Empty scope constant
    const str4 = try std.fmt.bufPrint(&buf, "{}", .{InstrumentationScope.empty});
    try testing.expectEqualStrings("InstrumentationScope{name=\"unknown\"}", str4);
}

test "InstrumentationScope edge cases" {
    const testing = std.testing;

    // Test with empty attributes array (but not null)
    const empty_attrs = [_]KeyValue{};
    const scope1 = try InstrumentationScope.init("test", "1.0.0", null, &empty_attrs);
    try testing.expect(scope1.attributes.len == 0);
    try testing.expect(!scope1.hasAttribute("any-key"));

    // Test empty vs null attributes equality
    const scope2 = try InstrumentationScope.init("test", "1.0.0", null, &[_]KeyValue{});
    try testing.expect(scope1.eql(scope2));

    // Test with very long strings (should still work)
    const long_name = "very_long_instrumentation_library_name_that_exceeds_normal_expectations";
    const long_version = "1.2.3-alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa";
    const scope3 = try InstrumentationScope.initSimple(long_name, long_version);
    try testing.expectEqualStrings(long_name, scope3.name);
    try testing.expectEqualStrings(long_version, scope3.version.?);
}

test "InstrumentationScope attribute operations" {
    const testing = std.testing;

    // Create scope with various attribute types
    const attrs = [_]KeyValue{
        .{ .key = "string_attr", .value = .{ .string = "test_value" } },
        .{ .key = "int_attr", .value = .{ .int = 42 } },
        .{ .key = "bool_attr", .value = .{ .bool = true } },
        .{ .key = "float_attr", .value = .{ .float = 3.14159 } },
    };

    const scope = try InstrumentationScope.init("test-lib", "1.0.0", null, &attrs);

    // Test getting different attribute types
    const string_val = scope.getAttribute("string_attr");
    try testing.expect(string_val != null);
    try testing.expectEqualStrings("test_value", string_val.?.string);

    const int_val = scope.getAttribute("int_attr");
    try testing.expect(int_val != null);
    try testing.expect(int_val.?.int == 42);

    const bool_val = scope.getAttribute("bool_attr");
    try testing.expect(bool_val != null);
    try testing.expect(bool_val.?.bool == true);

    const float_val = scope.getAttribute("float_attr");
    try testing.expect(float_val != null);
    try testing.expect(float_val.?.float == 3.14159);

    // Test missing attribute
    try testing.expect(scope.getAttribute("missing_attr") == null);

    // Test hasAttribute for all
    try testing.expect(scope.hasAttribute("string_attr"));
    try testing.expect(scope.hasAttribute("int_attr"));
    try testing.expect(scope.hasAttribute("bool_attr"));
    try testing.expect(scope.hasAttribute("float_attr"));
    try testing.expect(!scope.hasAttribute("missing_attr"));
}
