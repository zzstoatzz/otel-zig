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
const AttributeKeyValue = @import("attributes.zig").AttributeKeyValue;

const api = struct {
    const ErrorInfo = @import("error_handler.zig").ErrorInfo;
    const ErrorComponent = @import("error_handler.zig").Component;
    const ErrorType = @import("error_handler.zig").ErrorType;
};

/// InstrumentationScope identifies the instrumentation library that generated telemetry data
/// Non-owning and immutable after creation following OpenTelemetry specification
pub const InstrumentationScope = struct {
    /// Name of the instrumentation library (REQUIRED, non-owning)
    /// Must be non-empty and identifies the instrumentation
    name: []const u8,

    /// Version of the instrumentation library (OPTIONAL, non-owning)
    /// Should follow semantic versioning when specified
    version: ?[]const u8 = null,

    /// Schema URL for the telemetry emitted by the library (OPTIONAL, non-owning)
    /// Points to the schema definition for the data
    schema_url: ?[]const u8 = null,

    /// Additional attributes about the instrumentation scope (OPTIONAL, non-owning)
    /// Provides extra metadata about the scope
    attributes: []const AttributeKeyValue = &.{},

    /// Creates an owning deep copy of an InstrumentationScope.
    ///
    /// This function allocates new memory for all of the scope's fields, creating a
    /// self-contained, owning instance. This contrasts with a regular
    /// `InstrumentationScope`, which only holds non-owning references to its data.
    ///
    /// The caller is responsible for freeing the allocated memory by calling
    /// `deinitOwned` on the returned scope when it is no longer needed.
    pub fn initOwned(allocator: std.mem.Allocator, unowned: InstrumentationScope) !InstrumentationScope {
        const owned_name = try allocator.dupe(u8, unowned.name);
        errdefer allocator.free(owned_name);
        const owned_version = if (unowned.version) |version| try allocator.dupe(u8, version) else null;
        errdefer if (owned_version) |version| allocator.free(version);
        const owned_schema_url = if (unowned.schema_url) |url| try allocator.dupe(u8, url) else null;
        errdefer if (owned_schema_url) |url| allocator.free(url);
        const owned_attributes = try AttributeKeyValue.initOwnedSlice(allocator, unowned.attributes);
        errdefer AttributeKeyValue.deinitOwnedSlice(allocator, owned_attributes);
        return .{
            .name = owned_name,
            .version = owned_version,
            .schema_url = owned_schema_url,
            .attributes = owned_attributes,
        };
    }

    /// Deinitializes an owning `InstrumentationScope` created by `initOwned`.
    ///
    /// This function frees all memory allocated for the scope's fields (name,
    /// version, schema_url, and attributes). It is the counterpart to `initOwned`
    /// and must be called to prevent memory leaks.
    ///
    /// The caller must ensure this is only called on an `InstrumentationScope`
    /// instance whose fields are all owned values, using the same allocator
    /// that created it.
    pub fn deinitOwned(self: InstrumentationScope, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.version) |v| allocator.free(v);
        if (self.schema_url) |url| allocator.free(url);
        AttributeKeyValue.deinitOwnedSlice(allocator, self.attributes);
    }

    /// Create an empty/default InstrumentationScope
    /// Uses "unknown" as the default name per OpenTelemetry conventions
    pub const empty: InstrumentationScope = .{
        .name = "unknown",
    };

    pub fn validationErrorInfo(self: InstrumentationScope) ?api.ErrorInfo {
        if (self.name.len == 0) {
            return .{
                .component = .general,
                .operation = "InstrumentationScope.name validation",
                .error_type = .validation,
                .message = "Invalid instrumentation scope name provided",
                .context = "name must be non-empty",
            };
        }
        return null;
    }

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

    /// Create a hash code for the instrumentation scopeh
    pub fn hash(self: InstrumentationScope) u64 {
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

        // Hash all attributes (order-independent to match eql() behavior)
        var attr_hash: u64 = 0;
        for (self.attributes) |attr| {
            var attr_hasher = std.hash.Wyhash.init(0);
            attr.hash(&attr_hasher);
            attr_hash ^= attr_hasher.final(); // XOR for order independence
        }
        hasher.update(std.mem.asBytes(&attr_hash));

        return hasher.final();
    }

    /// Format the InstrumentationScope for debugging/logging
    pub fn format(
        self: InstrumentationScope,
        writer: anytype,
    ) !void {
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
                try writer.print("{f}", .{attr});
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
    const scope1 = InstrumentationScope{ .name = "test-library" };
    try testing.expectEqualStrings("test-library", scope1.name);
    try testing.expect(scope1.version == null);
    try testing.expect(scope1.schema_url == null);
    try testing.expect(scope1.attributes.len == 0);

    // Test scope with name and version
    const scope2 = InstrumentationScope{ .name = "test-library", .version = "1.0.0" };
    try testing.expectEqualStrings("test-library", scope2.name);
    try testing.expectEqualStrings("1.0.0", scope2.version.?);
    try testing.expect(scope2.schema_url == null);
    try testing.expect(scope2.attributes.len == 0);

    // Test full scope
    const attrs = [_]AttributeKeyValue{
        .{ .key = "library.language", .value = .{ .string = "zig" } },
        .{ .key = "library.version", .value = .{ .string = "0.12.0" } },
    };

    const scope3 = InstrumentationScope{
        .name = "test-library",
        .version = "1.0.0",
        .schema_url = "https://example.com/schema",
        .attributes = &attrs,
    };

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
    const error_scope = InstrumentationScope{ .name = "" };
    const error_info = InstrumentationScope.validationErrorInfo(error_scope);
    try testing.expect(error_info != null);
    try testing.expectEqual(api.ErrorComponent.general, error_info.?.component);
    try testing.expectEqual(api.ErrorType.validation, error_info.?.error_type);
}

test "InstrumentationScope equality" {
    const testing = std.testing;

    const scope1 = InstrumentationScope{ .name = "test-library", .version = "1.0.0" };
    const scope2 = InstrumentationScope{ .name = "test-library", .version = "1.0.0" };
    const scope3 = InstrumentationScope{ .name = "test-library", .version = "1.1.0" };
    const scope4 = InstrumentationScope{ .name = "other-library", .version = "1.0.0" };

    // Same scopes should be equal
    try testing.expect(scope1.eql(scope2));

    // Different versions should not be equal
    try testing.expect(!scope1.eql(scope3));

    // Different names should not be equal
    try testing.expect(!scope1.eql(scope4));
}

test "InstrumentationScope with attributes equality" {
    const testing = std.testing;

    const attrs1 = [_]AttributeKeyValue{
        .{ .key = "language", .value = .{ .string = "zig" } },
        .{ .key = "version", .value = .{ .string = "0.12.0" } },
    };

    const attrs2 = [_]AttributeKeyValue{
        .{ .key = "version", .value = .{ .string = "0.12.0" } },
        .{ .key = "language", .value = .{ .string = "zig" } },
    };

    const attrs3 = [_]AttributeKeyValue{
        .{ .key = "language", .value = .{ .string = "rust" } },
        .{ .key = "version", .value = .{ .string = "0.12.0" } },
    };

    const scope1 = InstrumentationScope{ .name = "test", .version = "1.0.0", .attributes = &attrs1 };
    const scope2 = InstrumentationScope{ .name = "test", .version = "1.0.0", .attributes = &attrs2 };
    const scope3 = InstrumentationScope{ .name = "test", .version = "1.0.0", .attributes = &attrs3 };

    // Same attributes in different order should be equal
    try testing.expect(scope1.eql(scope2));

    // Different attribute values should not be equal
    try testing.expect(!scope1.eql(scope3));
}

test "InstrumentationScope optional field handling" {
    const testing = std.testing;

    // Test various combinations of optional fields
    const scope_none = InstrumentationScope{ .name = "test", .version = null, .schema_url = null };
    const scope_version = InstrumentationScope{ .name = "test", .version = "1.0.0", .schema_url = null };
    const scope_schema = InstrumentationScope{ .name = "test", .version = null, .schema_url = "https://schema.url" };
    const scope_both = InstrumentationScope{ .name = "test", .version = "1.0.0", .schema_url = "https://schema.url" };

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

    const scope1 = InstrumentationScope{ .name = "test-library", .version = "1.0.0" };
    const scope2 = InstrumentationScope{ .name = "test-library", .version = "1.0.0" };
    const scope3 = InstrumentationScope{ .name = "test-library", .version = "1.1.0" };
    const scope4 = InstrumentationScope{ .name = "other-library", .version = "1.0.0" };

    const hash1 = scope1.hash();
    const hash2 = scope2.hash();
    const hash3 = scope3.hash();
    const hash4 = scope4.hash();

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
    const scope1 = InstrumentationScope{ .name = "test-library" };
    const str1 = try std.fmt.bufPrint(&buf, "{f}", .{scope1});
    try testing.expectEqualStrings("InstrumentationScope{name=\"test-library\"}", str1);

    // Scope with version
    const scope2 = InstrumentationScope{ .name = "test-library", .version = "1.0.0" };
    const str2 = try std.fmt.bufPrint(&buf, "{f}", .{scope2});
    try testing.expectEqualStrings("InstrumentationScope{name=\"test-library\", version=\"1.0.0\"}", str2);

    // Full scope with attributes
    const attrs = [_]AttributeKeyValue{
        .{ .key = "lang", .value = .{ .string = "zig" } },
    };
    const scope3 = InstrumentationScope{ .name = "test", .version = "1.0.0", .schema_url = "https://schema.url", .attributes = &attrs };
    const str3 = try std.fmt.bufPrint(&buf, "{f}", .{scope3});
    const expected = "InstrumentationScope{name=\"test\", version=\"1.0.0\", schema_url=\"https://schema.url\", attributes=[lang=\"zig\"]}";
    try testing.expectEqualStrings(expected, str3);

    // Empty scope constant
    const str4 = try std.fmt.bufPrint(&buf, "{f}", .{InstrumentationScope.empty});
    try testing.expectEqualStrings("InstrumentationScope{name=\"unknown\"}", str4);
}

test "InstrumentationScope edge cases" {
    const testing = std.testing;

    // Test with empty attributes array (but not null)
    const empty_attrs = [_]AttributeKeyValue{};
    const scope1 = InstrumentationScope{ .name = "test", .version = "1.0.0", .attributes = &empty_attrs };
    try testing.expect(scope1.attributes.len == 0);
    try testing.expect(!scope1.hasAttribute("any-key"));

    // Test empty vs null attributes equality
    const scope2 = InstrumentationScope{ .name = "test", .version = "1.0.0" };
    try testing.expect(scope1.eql(scope2));

    // Test with very long strings (should still work)
    const long_name = "very_long_instrumentation_library_name_that_exceeds_normal_expectations";
    const long_version = "1.2.3-alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa";
    const scope3 = InstrumentationScope{ .name = long_name, .version = long_version };
    try testing.expectEqualStrings(long_name, scope3.name);
    try testing.expectEqualStrings(long_version, scope3.version.?);
}

test "InstrumentationScope attribute operations" {
    const testing = std.testing;

    // Create scope with various attribute types
    const attrs = [_]AttributeKeyValue{
        .{ .key = "string_attr", .value = .{ .string = "test_value" } },
        .{ .key = "int_attr", .value = .{ .int = 42 } },
        .{ .key = "bool_attr", .value = .{ .bool = true } },
        .{ .key = "float_attr", .value = .{ .float = 3.14159 } },
    };

    const scope = InstrumentationScope{ .name = "test-lib", .version = "1.0.0", .attributes = &attrs };

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

test "InstrumentationScope hash/equality contract" {
    const testing = std.testing;

    // Test basic hash/equality contract
    const scope1 = InstrumentationScope{ .name = "test.scope", .version = "1.0.0", .schema_url = "http://schema.example.com" };
    const scope2 = InstrumentationScope{ .name = "test.scope", .version = "1.0.0", .schema_url = "http://schema.example.com" };
    const scope3 = InstrumentationScope{ .name = "other.scope", .version = "1.0.0", .schema_url = "http://schema.example.com" };

    // Equal scopes should have equal hashes
    try testing.expect(scope1.eql(scope2));
    try testing.expectEqual(scope1.hash(), scope2.hash());

    // Different scopes should not be equal and should have different hashes
    try testing.expect(!scope1.eql(scope3));
    try testing.expect(scope1.hash() != scope3.hash());
}

test "InstrumentationScope hash with attributes" {
    const testing = std.testing;

    const attrs1 = [_]AttributeKeyValue{
        .{ .key = "env", .value = .{ .string = "prod" } },
        .{ .key = "version", .value = .{ .int = 1 } },
    };
    const attrs2 = [_]AttributeKeyValue{
        .{ .key = "env", .value = .{ .string = "prod" } },
        .{ .key = "version", .value = .{ .int = 1 } },
    };
    const attrs3 = [_]AttributeKeyValue{
        .{ .key = "env", .value = .{ .string = "dev" } },
        .{ .key = "version", .value = .{ .int = 1 } },
    };

    const scope1 = InstrumentationScope{ .name = "test.scope", .version = "1.0.0", .attributes = &attrs1 };
    const scope2 = InstrumentationScope{ .name = "test.scope", .version = "1.0.0", .attributes = &attrs2 };
    const scope3 = InstrumentationScope{ .name = "test.scope", .version = "1.0.0", .attributes = &attrs3 };

    // Same attributes should produce equal scopes and hashes
    try testing.expect(scope1.eql(scope2));
    try testing.expectEqual(scope1.hash(), scope2.hash());

    // Different attributes should produce different scopes and hashes
    try testing.expect(!scope1.eql(scope3));
    try testing.expect(scope1.hash() != scope3.hash());
}

test "InstrumentationScope hash attribute order independence" {
    const testing = std.testing;

    const attrs1 = [_]AttributeKeyValue{
        .{ .key = "env", .value = .{ .string = "prod" } },
        .{ .key = "version", .value = .{ .int = 1 } },
        .{ .key = "region", .value = .{ .string = "us-east" } },
    };
    const attrs2 = [_]AttributeKeyValue{
        .{ .key = "version", .value = .{ .int = 1 } },
        .{ .key = "region", .value = .{ .string = "us-east" } },
        .{ .key = "env", .value = .{ .string = "prod" } },
    };

    const scope1 = InstrumentationScope{ .name = "test.scope", .version = "1.0.0", .attributes = &attrs1 };
    const scope2 = InstrumentationScope{ .name = "test.scope", .version = "1.0.0", .attributes = &attrs2 };

    // Different order, same attributes should be equal
    try testing.expect(scope1.eql(scope2));
    try testing.expectEqual(scope1.hash(), scope2.hash());
}

test "InstrumentationScope hash with optional fields" {
    const testing = std.testing;

    // Test with all combinations of optional fields
    const scope1 = InstrumentationScope{ .name = "test.scope" };
    const scope2 = InstrumentationScope{ .name = "test.scope", .version = "1.0.0" };
    const scope3 = InstrumentationScope{ .name = "test.scope", .schema_url = "http://schema.example.com" };
    const scope4 = InstrumentationScope{ .name = "test.scope", .version = "1.0.0", .schema_url = "http://schema.example.com" };

    // All should have different hashes due to different optional fields
    try testing.expect(scope1.hash() != scope2.hash());
    try testing.expect(scope1.hash() != scope3.hash());
    try testing.expect(scope1.hash() != scope4.hash());
    try testing.expect(scope2.hash() != scope3.hash());
    try testing.expect(scope2.hash() != scope4.hash());
    try testing.expect(scope3.hash() != scope4.hash());

    // Test equality consistency
    try testing.expect(!scope1.eql(scope2));
    try testing.expect(!scope1.eql(scope3));
    try testing.expect(!scope1.eql(scope4));
}

test "InstrumentationScope hash consistency" {
    const testing = std.testing;

    const attrs = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "test-service" } },
        .{ .key = "service.version", .value = .{ .string = "1.2.3" } },
        .{ .key = "deployment.environment", .value = .{ .string = "production" } },
    };

    const scope = InstrumentationScope{ .name = "consistency.test", .version = "2.0.0", .schema_url = "http://schema.test.com", .attributes = &attrs };

    // Hash should be consistent across multiple calls
    const hash1 = scope.hash();
    const hash2 = scope.hash();
    const hash3 = scope.hash();

    try testing.expectEqual(hash1, hash2);
    try testing.expectEqual(hash2, hash3);
}

test "InstrumentationScope hash collision resistance" {
    const testing = std.testing;

    // Test that similar scopes have different hashes
    const scope1 = InstrumentationScope{ .name = "service.a", .version = "1.0" };
    const scope2 = InstrumentationScope{ .name = "service.b", .version = "1.0" };
    const scope3 = InstrumentationScope{ .name = "service.a", .version = "1.1" };
    const scope4 = InstrumentationScope{ .name = "service.a", .version = "1.0", .schema_url = "http://schema.com" };

    const hash1 = scope1.hash();
    const hash2 = scope2.hash();
    const hash3 = scope3.hash();
    const hash4 = scope4.hash();

    // All should be different
    try testing.expect(hash1 != hash2);
    try testing.expect(hash1 != hash3);
    try testing.expect(hash1 != hash4);
    try testing.expect(hash2 != hash3);
    try testing.expect(hash2 != hash4);
    try testing.expect(hash3 != hash4);
}

test "InstrumentationScope comprehensive hash/equality contract validation" {
    const testing = std.testing;

    // Create a variety of test scopes to validate the fundamental hash contract:
    // If a.eql(b) then a.hashCode() == b.hashCode()

    const test_cases = [_]InstrumentationScope{
        // Basic cases
        .{ .name = "test", .version = null, .schema_url = null },
        .{ .name = "test", .version = "1.0", .schema_url = null },
        .{ .name = "test", .version = null, .schema_url = "http://schema.com" },
        .{ .name = "test", .version = "1.0", .schema_url = "http://schema.com" },

        // With single attribute
        .{ .name = "test", .version = null, .schema_url = null, .attributes = &[_]AttributeKeyValue{
            .{ .key = "key", .value = .{ .string = "value" } },
        } },

        // With multiple attributes (different orders)
        .{ .name = "test", .version = null, .schema_url = null, .attributes = &[_]AttributeKeyValue{
            .{ .key = "a", .value = .{ .string = "1" } },
            .{ .key = "b", .value = .{ .int = 2 } },
        } },
        .{ .name = "test", .version = null, .schema_url = null, .attributes = &[_]AttributeKeyValue{
            .{ .key = "b", .value = .{ .int = 2 } },
            .{ .key = "a", .value = .{ .string = "1" } },
        } },

        // Edge cases with empty strings (name cannot be empty per validation)
        .{ .name = "test", .version = "", .schema_url = null },
        .{ .name = "test", .version = null, .schema_url = "" },
    };

    // Test all pairs to validate hash/equality contract
    for (test_cases, 0..) |case1, i| {
        for (test_cases, 0..) |case2, j| {
            const scope1 = case1;
            const scope2 = case2;

            const are_equal = scope1.eql(scope2);
            const hash1 = scope1.hash();
            const hash2 = scope2.hash();

            if (are_equal) {
                // If equal, hashes MUST be equal
                try testing.expectEqual(hash1, hash2);
            }

            // Additional validation: same case should always be equal to itself
            if (i == j) {
                try testing.expect(are_equal);
                try testing.expectEqual(hash1, hash2);
            }
        }
    }

    // Special test for attribute order independence
    const attrs_order1 = [_]AttributeKeyValue{
        .{ .key = "env", .value = .{ .string = "prod" } },
        .{ .key = "version", .value = .{ .int = 1 } },
        .{ .key = "region", .value = .{ .string = "us" } },
    };
    const attrs_order2 = [_]AttributeKeyValue{
        .{ .key = "region", .value = .{ .string = "us" } },
        .{ .key = "env", .value = .{ .string = "prod" } },
        .{ .key = "version", .value = .{ .int = 1 } },
    };

    const scope_order1 = InstrumentationScope{ .name = "order.test", .version = "1.0", .attributes = &attrs_order1 };
    const scope_order2 = InstrumentationScope{ .name = "order.test", .version = "1.0", .attributes = &attrs_order2 };

    // These should be equal despite different attribute order
    try testing.expect(scope_order1.eql(scope_order2));
    try testing.expectEqual(scope_order1.hash(), scope_order2.hash());
}
