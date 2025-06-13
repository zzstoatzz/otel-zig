//! OpenTelemetry AttributeValue - Non-owning, lightweight attribute values
//!
//! ## Memory Management
//! AttributeValue is NON-OWNING - it only holds references to data.
//! The caller is responsible for ensuring the lifetime of all referenced data.

const std = @import("std");

/// Non-owning attribute value type.
/// All memory referenced by this type must be managed by the caller.
///
/// Follows OpenTelemetry specification for supported attribute value types:
/// - Primitive types: bool, int64, float64, string
/// - Homogeneous arrays of primitive types
pub const AttributeValue = union(enum) {
    /// Boolean value
    bool: bool,

    /// Signed 64-bit integer
    int: i64,

    /// IEEE 754 double precision floating point
    float: f64,

    /// UTF-8 string slice (non-owning)
    string: []const u8,

    /// Array of boolean values (non-owning)
    bool_array: []const bool,

    /// Array of signed 64-bit integers (non-owning)
    int_array: []const i64,

    /// Array of double precision floats (non-owning)
    float_array: []const f64,

    /// Array of UTF-8 string slices (non-owning)
    string_array: []const []const u8,

    /// Compare two AttributeValues for equality
    pub fn eql(self: AttributeValue, other: AttributeValue) bool {
        if (@as(std.meta.Tag(AttributeValue), self) != @as(std.meta.Tag(AttributeValue), other)) {
            return false;
        }

        return switch (self) {
            .bool => |a| a == other.bool,
            .int => |a| a == other.int,
            .float => |a| a == other.float,
            .string => |a| std.mem.eql(u8, a, other.string),
            .bool_array => |a| std.mem.eql(bool, a, other.bool_array),
            .int_array => |a| std.mem.eql(i64, a, other.int_array),
            .float_array => |a| std.mem.eql(f64, a, other.float_array),
            .string_array => |a| blk: {
                const b = other.string_array;
                if (a.len != b.len) break :blk false;
                for (a, b) |str_a, str_b| {
                    if (!std.mem.eql(u8, str_a, str_b)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Hash the AttributeValue for use in hash maps
    pub fn hash(self: AttributeValue, hasher: *std.hash.Wyhash) void {
        // Hash the type tag first to distinguish different types
        const tag = @as(u8, @intFromEnum(@as(std.meta.Tag(AttributeValue), self)));
        hasher.update(std.mem.asBytes(&tag));

        switch (self) {
            .bool => |v| hasher.update(std.mem.asBytes(&v)),
            .int => |v| hasher.update(std.mem.asBytes(&v)),
            .float => |v| hasher.update(std.mem.asBytes(&v)),
            .string => |v| hasher.update(v),
            .bool_array => |v| hasher.update(std.mem.sliceAsBytes(v)),
            .int_array => |v| hasher.update(std.mem.sliceAsBytes(v)),
            .float_array => |v| hasher.update(std.mem.sliceAsBytes(v)),
            .string_array => |v| {
                for (v) |str| {
                    hasher.update(str);
                    // Add separator to distinguish ["ab", "c"] from ["a", "bc"]
                    hasher.update(&[_]u8{0});
                }
            },
        }
    }

    /// Get the type tag as a string for debugging
    pub fn getTypeName(self: AttributeValue) []const u8 {
        return switch (self) {
            .bool => "bool",
            .int => "int",
            .float => "float",
            .string => "string",
            .bool_array => "bool_array",
            .int_array => "int_array",
            .float_array => "float_array",
            .string_array => "string_array",
        };
    }

    /// Format the AttributeValue for debugging/logging
    pub fn format(
        self: AttributeValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        switch (self) {
            .bool => |v| try writer.print("{}", .{v}),
            .int => |v| try writer.print("{}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .string => |v| try writer.print("\"{}\"", .{std.zig.fmtEscapes(v)}),
            .bool_array => |v| {
                try writer.writeAll("[");
                for (v, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{item});
                }
                try writer.writeAll("]");
            },
            .int_array => |v| {
                try writer.writeAll("[");
                for (v, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{item});
                }
                try writer.writeAll("]");
            },
            .float_array => |v| {
                try writer.writeAll("[");
                for (v, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{item});
                }
                try writer.writeAll("]");
            },
            .string_array => |v| {
                try writer.writeAll("[");
                for (v, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("\"{}\"", .{std.zig.fmtEscapes(item)});
                }
                try writer.writeAll("]");
            },
        }
    }
};

// Tests
test "AttributeValue creation and basic operations" {
    const testing = std.testing;

    // Test primitive types
    const bool_val: AttributeValue = .{ .bool = true };
    try testing.expect(bool_val.bool == true);
    try testing.expectEqualStrings("bool", bool_val.getTypeName());

    const int_val: AttributeValue = .{ .int = 42 };
    try testing.expect(int_val.int == 42);
    try testing.expectEqualStrings("int", int_val.getTypeName());

    const float_val: AttributeValue = .{ .float = 3.14 };
    try testing.expect(float_val.float == 3.14);
    try testing.expectEqualStrings("float", float_val.getTypeName());

    const string_val: AttributeValue = .{ .string = "hello" };
    try testing.expectEqualStrings("hello", string_val.string);
    try testing.expectEqualStrings("string", string_val.getTypeName());
}

test "AttributeValue equality comparison" {
    const testing = std.testing;

    // Test primitive equality
    try testing.expect((AttributeValue{ .bool = true }).eql(AttributeValue{ .bool = true }));
    try testing.expect(!(AttributeValue{ .bool = true }).eql(AttributeValue{ .bool = false }));

    try testing.expect((AttributeValue{ .int = 42 }).eql(AttributeValue{ .int = 42 }));
    try testing.expect(!(AttributeValue{ .int = 42 }).eql(AttributeValue{ .int = 43 }));

    try testing.expect((AttributeValue{ .float = 3.14 }).eql(AttributeValue{ .float = 3.14 }));
    try testing.expect(!(AttributeValue{ .float = 3.14 }).eql(AttributeValue{ .float = 2.71 }));

    try testing.expect((AttributeValue{ .string = "hello" }).eql(AttributeValue{ .string = "hello" }));
    try testing.expect(!(AttributeValue{ .string = "hello" }).eql(AttributeValue{ .string = "world" }));

    // Test different types are not equal
    try testing.expect(!(AttributeValue{ .bool = true }).eql(AttributeValue{ .int = 1 }));
    try testing.expect(!(AttributeValue{ .string = "42" }).eql(AttributeValue{ .int = 42 }));
}

test "AttributeValue array types" {
    const testing = std.testing;

    const bool_array = [_]bool{ true, false, true };
    const bool_val = AttributeValue{ .bool_array = &bool_array };
    try testing.expectEqualStrings("bool_array", bool_val.getTypeName());

    const int_array = [_]i64{ 1, 2, 3 };
    const int_val = AttributeValue{ .int_array = &int_array };
    try testing.expectEqualStrings("int_array", int_val.getTypeName());

    const float_array = [_]f64{ 1.1, 2.2, 3.3 };
    const float_val = AttributeValue{ .float_array = &float_array };
    try testing.expectEqualStrings("float_array", float_val.getTypeName());

    const strings = [_][]const u8{ "a", "b", "c" };
    const string_array_val = AttributeValue{ .string_array = &strings };
    try testing.expectEqualStrings("string_array", string_array_val.getTypeName());
}

test "AttributeValue array equality" {
    const testing = std.testing;

    const bool_array1 = [_]bool{ true, false };
    const bool_array2 = [_]bool{ true, false };
    const bool_array3 = [_]bool{ false, true };

    const val1 = AttributeValue{ .bool_array = &bool_array1 };
    const val2 = AttributeValue{ .bool_array = &bool_array2 };
    const val3 = AttributeValue{ .bool_array = &bool_array3 };

    try testing.expect(val1.eql(val2));
    try testing.expect(!val1.eql(val3));

    const strings1 = [_][]const u8{ "hello", "world" };
    const strings2 = [_][]const u8{ "hello", "world" };
    const strings3 = [_][]const u8{ "hello", "universe" };

    const str_val1 = AttributeValue{ .string_array = &strings1 };
    const str_val2 = AttributeValue{ .string_array = &strings2 };
    const str_val3 = AttributeValue{ .string_array = &strings3 };

    try testing.expect(str_val1.eql(str_val2));
    try testing.expect(!str_val1.eql(str_val3));
}

test "AttributeValue formatting" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    // Test primitive formatting
    const bool_val: AttributeValue = .{ .bool = true };
    const bool_str = try std.fmt.bufPrint(&buf, "{}", .{bool_val});
    try testing.expectEqualStrings("true", bool_str);

    const int_val: AttributeValue = .{ .int = -42 };
    const int_str = try std.fmt.bufPrint(&buf, "{}", .{int_val});
    try testing.expectEqualStrings("-42", int_str);

    const float_val: AttributeValue = .{ .float = 3.14159 };
    const float_str = try std.fmt.bufPrint(&buf, "{}", .{float_val});
    try testing.expectEqualStrings("3.14159", float_str);

    const string_val: AttributeValue = .{ .string = "hello\nworld" };
    const string_str = try std.fmt.bufPrint(&buf, "{}", .{string_val});
    try testing.expectEqualStrings("\"hello\\nworld\"", string_str);

    // Test array formatting
    const int_array = [_]i64{ 1, 2, 3 };
    const array_val = AttributeValue{ .int_array = &int_array };
    const array_str = try std.fmt.bufPrint(&buf, "{}", .{array_val});
    try testing.expectEqualStrings("[1, 2, 3]", array_str);
}

/// A key-value pair used for attributes and other OpenTelemetry contexts.
/// This is a simple non-owning structure that holds references to data.
pub const AttributeKeyValue = struct {
    /// The attribute key (non-owning string slice)
    key: []const u8,

    /// The attribute value (non-owning)
    value: AttributeValue,

    /// Deep copy an AttributeKeyValue. Must call `deinitOwned` on the return instance.
    pub fn initOwned(allocator: std.mem.Allocator, key: []const u8, value: AttributeValue) !AttributeKeyValue {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value: AttributeValue = switch (value) {
            .bool, .int, .float => value,
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .bool_array => |s| .{ .bool_array = try allocator.dupe(bool, s) },
            .int_array => |s| .{ .int_array = try allocator.dupe(i64, s) },
            .float_array => |s| .{ .float_array = try allocator.dupe(f64, s) },
            .string_array => |arr| blk: {
                var owned_strings = try allocator.alloc([]const u8, arr.len);
                errdefer allocator.free(owned_strings);

                for (arr, 0..) |str, i| {
                    errdefer for (0..i) |h| allocator.free(owned_strings[h]);
                    owned_strings[i] = try allocator.dupe(u8, str);
                }
                break :blk .{ .string_array = owned_strings };
            },
        };
        return .{
            .key = owned_key,
            .value = owned_value,
        };
    }

    /// Deep copy a slice of AttributeKeyValue.
    pub fn initOwnedSlice(allocator: std.mem.Allocator, unowned: []const AttributeKeyValue) ![]AttributeKeyValue {
        var owned = try allocator.alloc(AttributeKeyValue, unowned.len);
        for (0..unowned.len) |h| {
            owned[h] = try initOwned(allocator, unowned[h].key, unowned[h].value);
        }
        return owned;
    }

    /// Destroy a deep copied AttributeKeyValue.
    pub fn deinitOwned(self: AttributeKeyValue, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        switch (self.value) {
            .bool, .int, .float => {},
            .string => |s| allocator.free(s),
            .bool_array => |s| allocator.free(s),
            .int_array => |s| allocator.free(s),
            .float_array => |s| allocator.free(s),
            .string_array => |s| {
                for (s) |str| allocator.free(str);
                allocator.free(s);
            },
        }
    }

    /// Destroy a deep copied slice of AttributeKeyValue.
    pub fn deinitOwnedSlice(allocator: std.mem.Allocator, slice: []const AttributeKeyValue) void {
        for (0..slice.len) |h| slice[h].deinitOwned(allocator);
        allocator.free(slice);
    }

    /// Compare two AttributeKeyValue pairs for equality.
    ///
    /// Equality is defined as a byte comparison on the key and
    /// invoking the equal opretor for the value.
    pub fn eql(self: AttributeKeyValue, other: AttributeKeyValue) bool {
        return std.mem.eql(u8, self.key, other.key) and self.value.eql(other.value);
    }

    /// Hash the AttributeKeyValue for use in hash maps
    pub fn hash(self: AttributeKeyValue, hasher: *std.hash.Wyhash) void {
        hasher.update(self.key);
        self.value.hash(hasher);
    }

    /// Format the AttributeKeyValue for debugging/logging
    pub fn format(
        self: AttributeKeyValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{}={}", .{ std.zig.fmtEscapes(self.key), self.value });
    }
};

// Convenience functions for creating AttributeKeyValue arrays
/// Create a AttributeKeyValue array from compile-time tuples
pub fn fromTuples(comptime tuples: anytype) [tuples.len]AttributeKeyValue {
    var result: [tuples.len]AttributeKeyValue = undefined;
    inline for (tuples, 0..) |tuple, i| {
        result[i] = AttributeKeyValue{ .key = tuple[0], .value = tuple[1] };
    }
    return result;
}

// Tests
test "KeyValue creation and basic operations" {
    const testing = std.testing;

    const kv1 = AttributeKeyValue{ .key = "service.name", .value = .{ .string = "my-service" } };
    try testing.expectEqualStrings("service.name", kv1.key);
    try testing.expectEqualStrings("my-service", kv1.value.string);

    const kv2 = AttributeKeyValue{ .key = "version", .value = .{ .string = "1.0.0" } };
    try testing.expectEqualStrings("version", kv2.key);
    try testing.expectEqualStrings("1.0.0", kv2.value.string);

    const kv3 = AttributeKeyValue{ .key = "port", .value = .{ .int = 8080 } };
    try testing.expectEqualStrings("port", kv3.key);
    try testing.expect(kv3.value.int == 8080);

    const kv4 = AttributeKeyValue{ .key = "debug", .value = .{ .bool = true } };
    try testing.expectEqualStrings("debug", kv4.key);
    try testing.expect(kv4.value.bool == true);

    const kv5 = AttributeKeyValue{ .key = "ratio", .value = .{ .float = 0.95 } };
    try testing.expectEqualStrings("ratio", kv5.key);
    try testing.expect(kv5.value.float == 0.95);
}

test "KeyValue equality comparison" {
    const testing = std.testing;

    const kv1 = AttributeKeyValue{ .key = "name", .value = .{ .string = "test" } };
    const kv2 = AttributeKeyValue{ .key = "name", .value = .{ .string = "test" } };
    const kv3 = AttributeKeyValue{ .key = "name", .value = .{ .string = "different" } };
    const kv4 = AttributeKeyValue{ .key = "different", .value = .{ .string = "test" } };

    try testing.expect(kv1.eql(kv2));
    try testing.expect(!kv1.eql(kv3));
    try testing.expect(!kv1.eql(kv4));
}

test "KeyValue formatting" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    const kv1 = AttributeKeyValue{ .key = "service.name", .value = .{ .string = "my-service" } };
    const str1 = try std.fmt.bufPrint(&buf, "{}", .{kv1});
    try testing.expectEqualStrings("service.name=\"my-service\"", str1);

    const kv2 = AttributeKeyValue{ .key = "port", .value = .{ .int = 8080 } };
    const str2 = try std.fmt.bufPrint(&buf, "{}", .{kv2});
    try testing.expectEqualStrings("port=8080", str2);

    const kv3 = AttributeKeyValue{ .key = "enabled", .value = .{ .bool = true } };
    const str3 = try std.fmt.bufPrint(&buf, "{}", .{kv3});
    try testing.expectEqualStrings("enabled=true", str3);

    // Test key with special characters
    const kv4 = AttributeKeyValue{ .key = "key\nwith\ttabs", .value = .{ .string = "value" } };
    const str4 = try std.fmt.bufPrint(&buf, "{}", .{kv4});
    try testing.expectEqualStrings("key\\nwith\\ttabs=\"value\"", str4);
}

test "KeyValue fromTuples convenience function" {
    const testing = std.testing;

    const kvs = fromTuples(.{
        .{ "service.name", AttributeValue{ .string = "my-service" } },
        .{ "port", AttributeValue{ .int = 8080 } },
        .{ "debug", AttributeValue{ .bool = true } },
    });
    try testing.expect(kvs.len == 3);

    try testing.expectEqualStrings("service.name", kvs[0].key);
    try testing.expectEqualStrings("my-service", kvs[0].value.string);

    try testing.expectEqualStrings("port", kvs[1].key);
    try testing.expect(kvs[1].value.int == 8080);

    try testing.expectEqualStrings("debug", kvs[2].key);
    try testing.expect(kvs[2].value.bool == true);
}

/// High-level attribute builder with functional style and automatic memory management.
///
/// The builder never takes ownership of any values added to it.
pub const AttributeBuilder = union(enum) {
    valid: struct {
        allocator: std.mem.Allocator,
        entries: []AttributeKeyValue,
    },
    invalid: anyerror,

    /// Create a new AttributeBuilder
    pub fn init(allocator: std.mem.Allocator) AttributeBuilder {
        const entries = allocator.alloc(AttributeKeyValue, 0) catch |e| return .{ .invalid = e };
        return AttributeBuilder{ .valid = .{
            .allocator = allocator,
            .entries = entries,
        } };
    }

    /// Free all memory allocated by this builder
    pub fn deinit(self: AttributeBuilder) void {
        switch (self) {
            .valid => |builder| {
                builder.allocator.free(builder.entries);
            },
            .invalid => {},
        }
    }

    /// Add an AttributeValue
    pub inline fn add(self: AttributeBuilder, key: []const u8, value: AttributeValue) AttributeBuilder {
        return self.addKeyValue(.{ .key = key, .value = value });
    }

    /// Add a string attribute
    pub inline fn addString(self: AttributeBuilder, key: []const u8, value: []const u8) AttributeBuilder {
        return self.addKeyValue(.{ .key = key, .value = .{ .string = value } });
    }

    /// Add boolean attribute
    pub inline fn addBool(self: AttributeBuilder, key: []const u8, value: bool) AttributeBuilder {
        return self.addKeyValue(.{ .key = key, .value = .{ .bool = value } });
    }

    /// Add integer attribute
    pub inline fn addInt(self: AttributeBuilder, key: []const u8, value: i64) AttributeBuilder {
        return self.addKeyValue(.{ .key = key, .value = .{ .int = value } });
    }

    /// Add float attribute
    pub inline fn addFloat(self: AttributeBuilder, key: []const u8, value: f64) AttributeBuilder {
        return self.addKeyValue(.{ .key = key, .value = .{ .float = value } });
    }

    /// Add a boolean array attribute
    pub inline fn addBoolArray(self: AttributeBuilder, key: []const u8, values: []const bool) AttributeBuilder {
        return self.addKeyValue(.{ .key = key, .value = .{ .bool_array = values } });
    }

    /// Add an integer array attribute
    pub inline fn addIntArray(self: AttributeBuilder, key: []const u8, values: []const i64) AttributeBuilder {
        return self.addKeyValue(.{ .key = key, .value = .{ .int_array = values } });
    }

    /// Add a float array attribute
    pub inline fn addFloatArray(self: AttributeBuilder, key: []const u8, values: []const f64) AttributeBuilder {
        return self.addKeyValue(.{ .key = key, .value = .{ .float_array = values } });
    }

    /// Add a string array attribute
    pub inline fn addStringArray(self: AttributeBuilder, key: []const u8, values: []const []const u8) AttributeBuilder {
        return self.addKeyValue(.{ .key = key, .value = .{ .string_array = values } });
    }

    /// Add a AttributeAttributeKeyValue pair
    pub fn addKeyValue(self: AttributeBuilder, new_kv: AttributeKeyValue) AttributeBuilder {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                const new_len = builder.entries.len + 1;
                var entries = builder.allocator.alloc(AttributeKeyValue, new_len) catch |e| return AttributeBuilder{ .invalid = e };
                errdefer builder.allocator.free(entries);
                @memcpy(entries[0..builder.entries.len], builder.entries);
                entries[builder.entries.len] = new_kv;

                break :blk .{
                    .valid = .{
                        .allocator = builder.allocator,
                        .entries = entries,
                    },
                };
            },
            .invalid => self,
        };
    }

    /// Add multiple AttributeAttributeKeyValue pairs at once
    pub fn addKeyValues(self: AttributeBuilder, kvs: []const AttributeKeyValue) AttributeBuilder {
        var current = self;
        for (kvs) |kv| {
            current = current.addKeyValue(kv);
        }
        return current;
    }

    /// Get the slice of `AttributeKeyValue`.
    ///
    /// Returned slice is owned by the builder, but the values in the slice
    /// are not owned copies; they still refer to the slices passed in the
    /// `addKeyValue` call (relevant for slice and string types).
    ///
    /// `deinit` must be manually called on the builder when this method is used.
    pub fn build(self: AttributeBuilder) ![]const AttributeKeyValue {
        return switch (self) {
            .valid => |builder| builder.entries,
            .invalid => |e| e,
        };
    }

    /// Get the deep copy slice of `AttributeKeyValue` and destroy this builder.
    ///
    /// Returned slice must be released with `AttributeKeyValue.deinitOwnedSlice` to
    /// release the keys and the values.
    pub fn finish(self: AttributeBuilder, target_allocator: std.mem.Allocator) ![]AttributeKeyValue {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                const kvs = try AttributeKeyValue.initOwnedSlice(target_allocator, builder.entries);
                break :blk kvs;
            },
            .invalid => |e| e,
        };
    }
};

// Tests

test "AttributeBuilder resource detection scenario" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simulate resource detection like DefaultDetector does
    var builder = AttributeBuilder.init(allocator);

    // Add default SDK attributes
    builder = builder.addString("telemetry.sdk.name", "opentelemetry");
    builder = builder.addString("telemetry.sdk.language", "zig");
    builder = builder.addString("telemetry.sdk.version", "0.1.0");

    // Add detected environment attributes
    const detected_attrs = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "service.name", .value = .{ .string = "my-service" } },
        AttributeKeyValue{ .key = "process.pid", .value = .{ .int = 1234 } },
    };
    builder = builder.addKeyValues(&detected_attrs);

    const attrs = try builder.finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 5), attrs.len);

    // Find and verify SDK attributes
    var sdk_name: ?AttributeValue = null;
    var service_name: ?AttributeValue = null;
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "telemetry.sdk.name")) {
            sdk_name = attr.value;
        } else if (std.mem.eql(u8, attr.key, "service.name")) {
            service_name = attr.value;
        }
    }

    try testing.expectEqualStrings("opentelemetry", sdk_name.?.string);
    try testing.expectEqualStrings("my-service", service_name.?.string);
}

test "AttributeBuilder resource merging scenario" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simulate Resource.merge() where other resource overrides self resource
    const other_attrs = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "service.name", .value = .{ .string = "new-service" } },
        AttributeKeyValue{ .key = "service.version", .value = .{ .string = "2.0.0" } },
    };

    const self_attrs = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "service.name", .value = .{ .string = "old-service" } },
        AttributeKeyValue{ .key = "host.name", .value = .{ .string = "host1" } },
    };

    // Add other attributes first (they take precedence), then self attributes
    var builder = AttributeBuilder.init(allocator);
    builder = builder.addKeyValues(&other_attrs);
    builder = builder.addKeyValues(&self_attrs);

    const attrs = try builder.finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 4), attrs.len);

    // service.name should be "new-service" (first occurrence wins in lookup)
    var service_name: ?AttributeValue = null;
    var host_name: ?AttributeValue = null;
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "service.name")) {
            if (service_name == null) service_name = attr.value; // First occurrence
        } else if (std.mem.eql(u8, attr.key, "host.name")) {
            host_name = attr.value;
        }
    }

    try testing.expectEqualStrings("new-service", service_name.?.string);
    try testing.expectEqualStrings("host1", host_name.?.string);
}

test "AttributeBuilder scope copying scenario" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simulate provider copying InstrumentationScope attributes
    const original_scope_attrs = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "instrumentation.name", .value = .{ .string = "test.library" } },
        AttributeKeyValue{ .key = "instrumentation.version", .value = .{ .string = "1.0.0" } },
    };

    const builder = AttributeBuilder.init(allocator);
    const copied_attrs = try builder.addKeyValues(&original_scope_attrs).finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, copied_attrs);

    try testing.expectEqual(@as(usize, 2), copied_attrs.len);

    // Verify the attributes were copied correctly
    var name_found = false;
    var version_found = false;
    for (copied_attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "instrumentation.name")) {
            try testing.expectEqualStrings("test.library", attr.value.string);
            name_found = true;
        } else if (std.mem.eql(u8, attr.key, "instrumentation.version")) {
            try testing.expectEqualStrings("1.0.0", attr.value.string);
            version_found = true;
        }
    }
    try testing.expect(name_found and version_found);
}

test "AttributeBuilder functional chaining pattern" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test the functional immutable pattern used throughout the SDK
    const builder1 = AttributeBuilder.init(allocator);
    const builder2 = builder1.addString("telemetry.sdk.name", "opentelemetry");
    const builder3 = builder2.addString("telemetry.sdk.language", "zig");

    // Each builder is independent - test that builder1 is still empty conceptually
    const empty_attrs = try builder1.finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, empty_attrs);
    try testing.expectEqual(@as(usize, 0), empty_attrs.len);

    // And builder3 has the full chain
    const full_attrs = try builder3.finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, full_attrs);
    try testing.expectEqual(@as(usize, 2), full_attrs.len);

    // Verify chained attributes
    var sdk_name_found = false;
    var sdk_lang_found = false;
    for (full_attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "telemetry.sdk.name")) {
            try testing.expectEqualStrings("opentelemetry", attr.value.string);
            sdk_name_found = true;
        } else if (std.mem.eql(u8, attr.key, "telemetry.sdk.language")) {
            try testing.expectEqualStrings("zig", attr.value.string);
            sdk_lang_found = true;
        }
    }
    try testing.expect(sdk_name_found and sdk_lang_found);
}

test "AttributeBuilder comprehensive types scenario" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simulate complex telemetry data with all attribute types
    const feature_flags = [_]bool{ true, false, true };
    const response_codes = [_]i64{ 200, 404, 500 };
    const response_times = [_]f64{ 0.125, 0.250, 1.500 };
    const endpoints = [_][]const u8{ "/api/users", "/api/orders", "/health" };

    var builder = AttributeBuilder.init(allocator);
    builder = builder.addString("service.name", "api-gateway");
    builder = builder.addInt("service.port", 8080);
    builder = builder.addBool("debug.enabled", true);
    builder = builder.addFloat("cpu.usage", 0.75);
    builder = builder.addBoolArray("feature.flags", &feature_flags);
    builder = builder.addIntArray("http.response_codes", &response_codes);
    builder = builder.addFloatArray("response.times", &response_times);
    builder = builder.addStringArray("monitored.endpoints", &endpoints);

    const attrs = try builder.finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 8), attrs.len);

    // Verify specific attributes by type
    var found_count: usize = 0;
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "service.name")) {
            try testing.expectEqualStrings("api-gateway", attr.value.string);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "service.port")) {
            try testing.expectEqual(@as(i64, 8080), attr.value.int);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "debug.enabled")) {
            try testing.expectEqual(true, attr.value.bool);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "cpu.usage")) {
            try testing.expectEqual(@as(f64, 0.75), attr.value.float);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "feature.flags")) {
            try testing.expectEqual(@as(usize, 3), attr.value.bool_array.len);
            try testing.expectEqual(true, attr.value.bool_array[0]);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "http.response_codes")) {
            try testing.expectEqual(@as(usize, 3), attr.value.int_array.len);
            try testing.expectEqual(@as(i64, 200), attr.value.int_array[0]);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "response.times")) {
            try testing.expectEqual(@as(usize, 3), attr.value.float_array.len);
            try testing.expectEqual(@as(f64, 0.125), attr.value.float_array[0]);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "monitored.endpoints")) {
            try testing.expectEqual(@as(usize, 3), attr.value.string_array.len);
            try testing.expectEqualStrings("/api/users", attr.value.string_array[0]);
            found_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 8), found_count);
}

test "AttributeBuilder empty and edge cases" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test empty builder
    const empty_attrs = try AttributeBuilder.init(allocator).finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, empty_attrs);
    try testing.expectEqual(@as(usize, 0), empty_attrs.len);

    // Test adding empty AttributeKeyValue slice
    const empty_kvs: []const AttributeKeyValue = &[_]AttributeKeyValue{};
    const attrs_from_empty = try AttributeBuilder.init(allocator)
        .addKeyValues(empty_kvs)
        .finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs_from_empty);
    try testing.expectEqual(@as(usize, 0), attrs_from_empty.len);

    // Test single attribute
    const single_attr = try AttributeBuilder.init(allocator)
        .addString("single.key", "single.value")
        .finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, single_attr);
    try testing.expectEqual(@as(usize, 1), single_attr.len);
    try testing.expectEqualStrings("single.key", single_attr[0].key);
    try testing.expectEqualStrings("single.value", single_attr[0].value.string);
}

test "AttributeValue hash/equality contract" {
    const testing = std.testing;

    // Helper function to get hash
    const getHash = struct {
        fn call(value: AttributeValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            value.hash(&hasher);
            return hasher.final();
        }
    }.call;

    // Test primitive types
    const bool_val1: AttributeValue = .{ .bool = true };
    const bool_val2: AttributeValue = .{ .bool = true };
    const bool_val3: AttributeValue = .{ .bool = false };

    try testing.expect(bool_val1.eql(bool_val2));
    try testing.expectEqual(getHash(bool_val1), getHash(bool_val2));
    try testing.expect(!bool_val1.eql(bool_val3));
    try testing.expect(getHash(bool_val1) != getHash(bool_val3));

    const int_val1: AttributeValue = .{ .int = 42 };
    const int_val2: AttributeValue = .{ .int = 42 };
    const int_val3: AttributeValue = .{ .int = 24 };

    try testing.expect(int_val1.eql(int_val2));
    try testing.expectEqual(getHash(int_val1), getHash(int_val2));
    try testing.expect(!int_val1.eql(int_val3));
    try testing.expect(getHash(int_val1) != getHash(int_val3));

    const float_val1: AttributeValue = .{ .float = 3.14 };
    const float_val2: AttributeValue = .{ .float = 3.14 };
    const float_val3: AttributeValue = .{ .float = 2.71 };

    try testing.expect(float_val1.eql(float_val2));
    try testing.expectEqual(getHash(float_val1), getHash(float_val2));
    try testing.expect(!float_val1.eql(float_val3));
    try testing.expect(getHash(float_val1) != getHash(float_val3));

    const str_val1: AttributeValue = .{ .string = "hello" };
    const str_val2: AttributeValue = .{ .string = "hello" };
    const str_val3: AttributeValue = .{ .string = "world" };

    try testing.expect(str_val1.eql(str_val2));
    try testing.expectEqual(getHash(str_val1), getHash(str_val2));
    try testing.expect(!str_val1.eql(str_val3));
    try testing.expect(getHash(str_val1) != getHash(str_val3));
}

test "AttributeValue array hash/equality contract" {
    const testing = std.testing;

    const getHash = struct {
        fn call(value: AttributeValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            value.hash(&hasher);
            return hasher.final();
        }
    }.call;

    // Test array types
    const bool_arr1 = [_]bool{ true, false, true };
    const bool_arr2 = [_]bool{ true, false, true };
    const bool_arr3 = [_]bool{ false, true, false };

    const bool_val1: AttributeValue = .{ .bool_array = &bool_arr1 };
    const bool_val2: AttributeValue = .{ .bool_array = &bool_arr2 };
    const bool_val3: AttributeValue = .{ .bool_array = &bool_arr3 };

    try testing.expect(bool_val1.eql(bool_val2));
    try testing.expectEqual(getHash(bool_val1), getHash(bool_val2));
    try testing.expect(!bool_val1.eql(bool_val3));
    try testing.expect(getHash(bool_val1) != getHash(bool_val3));

    const int_arr1 = [_]i64{ 1, 2, 3 };
    const int_arr2 = [_]i64{ 1, 2, 3 };
    const int_arr3 = [_]i64{ 3, 2, 1 };

    const int_val1: AttributeValue = .{ .int_array = &int_arr1 };
    const int_val2: AttributeValue = .{ .int_array = &int_arr2 };
    const int_val3: AttributeValue = .{ .int_array = &int_arr3 };

    try testing.expect(int_val1.eql(int_val2));
    try testing.expectEqual(getHash(int_val1), getHash(int_val2));
    try testing.expect(!int_val1.eql(int_val3));
    try testing.expect(getHash(int_val1) != getHash(int_val3));

    const str_arr1 = [_][]const u8{ "a", "b", "c" };
    const str_arr2 = [_][]const u8{ "a", "b", "c" };
    const str_arr3 = [_][]const u8{ "ab", "c" }; // Different splitting, same total content

    const str_val1: AttributeValue = .{ .string_array = &str_arr1 };
    const str_val2: AttributeValue = .{ .string_array = &str_arr2 };
    const str_val3: AttributeValue = .{ .string_array = &str_arr3 };

    try testing.expect(str_val1.eql(str_val2));
    try testing.expectEqual(getHash(str_val1), getHash(str_val2));
    try testing.expect(!str_val1.eql(str_val3));
    try testing.expect(getHash(str_val1) != getHash(str_val3)); // Different due to separator
}

test "AttributeValue different types have different hashes" {
    const testing = std.testing;

    const getHash = struct {
        fn call(value: AttributeValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            value.hash(&hasher);
            return hasher.final();
        }
    }.call;

    // Same underlying value, different types should have different hashes
    const bool_val: AttributeValue = .{ .bool = true };
    const int_val: AttributeValue = .{ .int = 1 }; // true as int
    const float_val: AttributeValue = .{ .float = 1.0 }; // true/1 as float
    const str_val: AttributeValue = .{ .string = "1" }; // 1 as string

    const bool_hash = getHash(bool_val);
    const int_hash = getHash(int_val);
    const float_hash = getHash(float_val);
    const str_hash = getHash(str_val);

    // All should be different
    try testing.expect(bool_hash != int_hash);
    try testing.expect(bool_hash != float_hash);
    try testing.expect(bool_hash != str_hash);
    try testing.expect(int_hash != float_hash);
    try testing.expect(int_hash != str_hash);
    try testing.expect(float_hash != str_hash);
}

test "KeyValue hash/equality contract" {
    const testing = std.testing;

    const getHash = struct {
        fn call(kv: AttributeKeyValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            kv.hash(&hasher);
            return hasher.final();
        }
    }.call;

    const kv1 = AttributeKeyValue{ .key = "service.name", .value = .{ .string = "my-service" } };
    const kv2 = AttributeKeyValue{ .key = "service.name", .value = .{ .string = "my-service" } };
    const kv3 = AttributeKeyValue{ .key = "service.name", .value = .{ .string = "other-service" } };
    const kv4 = AttributeKeyValue{ .key = "other.key", .value = .{ .string = "my-service" } };

    // Same key and value should be equal and have same hash
    try testing.expect(kv1.eql(kv2));
    try testing.expectEqual(getHash(kv1), getHash(kv2));

    // Different value should not be equal and should have different hash
    try testing.expect(!kv1.eql(kv3));
    try testing.expect(getHash(kv1) != getHash(kv3));

    // Different key should not be equal and should have different hash
    try testing.expect(!kv1.eql(kv4));
    try testing.expect(getHash(kv1) != getHash(kv4));
}

test "Hash consistency" {
    const testing = std.testing;

    const getHash = struct {
        fn call(value: AttributeValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            value.hash(&hasher);
            return hasher.final();
        }
    }.call;

    // Same value should always produce same hash
    const val: AttributeValue = .{ .string = "consistent" };
    const hash1 = getHash(val);
    const hash2 = getHash(val);
    const hash3 = getHash(val);

    try testing.expectEqual(hash1, hash2);
    try testing.expectEqual(hash2, hash3);

    // Same for KeyValue
    const getKvHash = struct {
        fn call(kv: AttributeKeyValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            kv.hash(&hasher);
            return hasher.final();
        }
    }.call;

    const kv = AttributeKeyValue{ .key = "test.key", .value = .{ .int = 42 } };
    const kv_hash1 = getKvHash(kv);
    const kv_hash2 = getKvHash(kv);
    const kv_hash3 = getKvHash(kv);

    try testing.expectEqual(kv_hash1, kv_hash2);
    try testing.expectEqual(kv_hash2, kv_hash3);
}
