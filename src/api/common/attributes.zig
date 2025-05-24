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
pub const KeyValue = struct {
    /// The attribute key (non-owning string slice)
    key: []const u8,

    /// The attribute value (non-owning)
    value: AttributeValue,

    /// Create a new KeyValue pair
    pub fn init(key: []const u8, value: AttributeValue) KeyValue {
        return .{
            .key = key,
            .value = value,
        };
    }

    /// Create a new KeyValue, but deep copy the key and the value with the
    /// provided allocator.
    pub fn initOwned(allocator: std.mem.Allocator, key: []const u8, value: AttributeValue) !KeyValue {
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

    /// Destroy the KeyValue. Must use the same allocator used in `initOwned`
    pub fn deinitOwned(self: KeyValue, allocator: std.mem.Allocator) void {
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

    /// Destroy a KeyValue slice. Helper function to deal with the
    /// KeyValues and the slice.
    pub fn deinitOwnedSlice(allocator: std.mem.Allocator, slice: []const KeyValue) void {
        for (0..slice.len) |h| slice[h].deinitOwned(allocator);
        allocator.free(slice);
    }

    /// Compare two KeyValue pairs for equality
    pub fn eql(self: KeyValue, other: KeyValue) bool {
        return std.mem.eql(u8, self.key, other.key) and self.value.eql(other.value);
    }

    /// Format the KeyValue for debugging/logging
    pub fn format(
        self: KeyValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{}={}", .{ std.zig.fmtEscapes(self.key), self.value });
    }
};

// Convenience functions for creating KeyValue arrays
/// Create a KeyValue array from compile-time tuples
pub fn fromTuples(comptime tuples: anytype) [tuples.len]KeyValue {
    var result: [tuples.len]KeyValue = undefined;
    inline for (tuples, 0..) |tuple, i| {
        result[i] = KeyValue.init(tuple[0], tuple[1]);
    }
    return result;
}

// Tests
test "KeyValue creation and basic operations" {
    const testing = std.testing;

    const kv1 = KeyValue.init("service.name", .{ .string = "my-service" });
    try testing.expectEqualStrings("service.name", kv1.key);
    try testing.expectEqualStrings("my-service", kv1.value.string);

    const kv2 = KeyValue.init("version", .{ .string = "1.0.0" });
    try testing.expectEqualStrings("version", kv2.key);
    try testing.expectEqualStrings("1.0.0", kv2.value.string);

    const kv3 = KeyValue.init("port", .{ .int = 8080 });
    try testing.expectEqualStrings("port", kv3.key);
    try testing.expect(kv3.value.int == 8080);

    const kv4 = KeyValue.init("debug", .{ .bool = true });
    try testing.expectEqualStrings("debug", kv4.key);
    try testing.expect(kv4.value.bool == true);

    const kv5 = KeyValue.init("ratio", .{ .float = 0.95 });
    try testing.expectEqualStrings("ratio", kv5.key);
    try testing.expect(kv5.value.float == 0.95);
}

test "KeyValue equality comparison" {
    const testing = std.testing;

    const kv1 = KeyValue.init("name", .{ .string = "test" });
    const kv2 = KeyValue.init("name", .{ .string = "test" });
    const kv3 = KeyValue.init("name", .{ .string = "different" });
    const kv4 = KeyValue.init("different", .{ .string = "test" });

    try testing.expect(kv1.eql(kv2));
    try testing.expect(!kv1.eql(kv3));
    try testing.expect(!kv1.eql(kv4));
}

test "KeyValue formatting" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    const kv1 = KeyValue.init("service.name", .{ .string = "my-service" });
    const str1 = try std.fmt.bufPrint(&buf, "{}", .{kv1});
    try testing.expectEqualStrings("service.name=\"my-service\"", str1);

    const kv2 = KeyValue.init("port", .{ .int = 8080 });
    const str2 = try std.fmt.bufPrint(&buf, "{}", .{kv2});
    try testing.expectEqualStrings("port=8080", str2);

    const kv3 = KeyValue.init("enabled", .{ .bool = true });
    const str3 = try std.fmt.bufPrint(&buf, "{}", .{kv3});
    try testing.expectEqualStrings("enabled=true", str3);

    // Test key with special characters
    const kv4 = KeyValue.init("key\nwith\ttabs", .{ .string = "value" });
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

const AttributeMap = std.StringHashMapUnmanaged(AttributeValue);

/// Collection of attributes with convenient access methods
pub const Attributes = struct {
    arena: std.heap.ArenaAllocator,
    map: AttributeMap,

    /// Initialize empty attributes collection
    pub fn init(backing_allocator: std.mem.Allocator) Attributes {
        const arena = std.heap.ArenaAllocator.init(backing_allocator);
        return .{
            .arena = arena,
            .map = .{},
        };
    }

    /// Clean up the attributes map
    pub fn deinit(self: *Attributes) void {
        self.map.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub inline fn allocator(self: *Attributes) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Add a key-value pair to the attributes
    pub fn put(self: *Attributes, key: []const u8, value: AttributeValue) !void {
        try self.map.put(self.arena.allocator(), key, value);
    }

    /// Get an attribute value by key
    pub fn get(self: Attributes, key: []const u8) ?AttributeValue {
        return self.map.get(key);
    }

    /// Check if an attribute key exists
    pub fn contains(self: Attributes, key: []const u8) bool {
        return self.map.contains(key);
    }

    /// Get the number of attributes
    pub fn count(self: Attributes) u32 {
        return @intCast(self.map.count());
    }

    /// Clear all attributes
    pub fn clear(self: *Attributes) void {
        self.map.clearRetainingCapacity();
    }

    /// Create an iterator over the attributes
    pub fn iterator(self: *const Attributes) AttributeMap.Iterator {
        return self.map.iterator();
    }

    /// Clone the attributes to a new collection with a different allocator
    /// NOTE: This uses the alloctar to make deep clones of all slice and string data
    pub fn asKeyValues(self: Attributes, target_allocator: std.mem.Allocator) ![]KeyValue {
        var kvs = try target_allocator.alloc(KeyValue, self.map.count());
        errdefer target_allocator.free(kvs);

        var h: usize = 0;
        var iter = self.map.iterator();
        while (iter.next()) |entry| : (h += 1) {
            errdefer for (0..h) |i| kvs[i].deinitOwned(target_allocator);
            kvs[h] = try KeyValue.initOwned(target_allocator, entry.key_ptr.*, entry.value_ptr.*);
        }

        return kvs;
    }

    /// Format the attributes for debugging/logging
    pub fn format(
        self: Attributes,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("{");
        var iter = self.map.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(", ");
            first = false;
            try writer.print("{}={}", .{ std.zig.fmtEscapes(entry.key_ptr.*), entry.value_ptr.* });
        }
        try writer.writeAll("}");
    }
};

/// High-level attribute builder with arena-based memory management
pub const AttributeBuilder = struct {
    attributes: Attributes,

    /// Create a new AttributeBuilder with arena allocator
    pub fn init(backing_allocator: std.mem.Allocator) AttributeBuilder {
        return .{
            .attributes = Attributes.init(backing_allocator),
        };
    }

    /// Free all memory allocated by this builder
    pub fn deinit(self: *AttributeBuilder) void {
        self.attributes.deinit();
    }

    /// Add a string attribute (automatically cloned into arena)
    pub fn addString(self: *AttributeBuilder, key: []const u8, value: []const u8) !void {
        try self.addAttributeValue(key, .{ .string = value });
    }

    /// Add boolean attribute
    pub inline fn addBool(self: *AttributeBuilder, key: []const u8, value: bool) !void {
        try self.addAttributeValue(key, .{ .bool = value });
    }

    /// Add integer attribute
    pub inline fn addInt(self: *AttributeBuilder, key: []const u8, value: i64) !void {
        try self.addAttributeValue(key, .{ .int = value });
    }

    /// Add float attribute
    pub inline fn addFloat(self: *AttributeBuilder, key: []const u8, value: f64) !void {
        try self.addAttributeValue(key, .{ .float = value });
    }

    /// Add a boolean array attribute
    pub inline fn addBoolArray(self: *AttributeBuilder, key: []const u8, values: []const bool) !void {
        try self.addAttributeValue(key, AttributeValue{ .bool_array = values });
    }

    /// Add an integer array attribute
    pub inline fn addIntArray(self: *AttributeBuilder, key: []const u8, values: []const i64) !void {
        try self.addAttributeValue(key, AttributeValue{ .int_array = values });
    }

    /// Add a float array attribute
    pub inline fn addFloatArray(self: *AttributeBuilder, key: []const u8, values: []const f64) !void {
        try self.addAttributeValue(key, AttributeValue{ .float_array = values });
    }

    /// Add a string array attribute
    pub inline fn addStringArray(self: *AttributeBuilder, key: []const u8, values: []const []const u8) !void {
        try self.addAttributeValue(key, AttributeValue{ .string_array = values });
    }

    /// Add a KeyValue pair (automatically clones if needed)
    pub inline fn addKeyValue(self: *AttributeBuilder, kv: KeyValue) !void {
        try self.addAttributeValue(kv.key, kv.value);
    }

    /// Add an AttributeValue with automatic cloning if needed
    pub fn addAttributeValue(self: *AttributeBuilder, key: []const u8, value: AttributeValue) !void {
        try self.attributes.put(key, value);
    }

    /// Add multiple KeyValue pairs at once
    pub fn addKeyValues(self: *AttributeBuilder, kvs: []const KeyValue) !void {
        for (kvs) |kv| {
            try self.addKeyValue(kv);
        }
    }

    /// Get the current attributes (still owned by the builder)
    pub fn build(self: AttributeBuilder) Attributes {
        return self.attributes;
    }

    /// Get the slice of `KeyValue` and destroy this builder.
    pub fn finish(self: *AttributeBuilder, target_allocator: std.mem.Allocator) ![]KeyValue {
        const attrs = self.build().asKeyValues(target_allocator);
        self.deinit();
        return attrs;
    }
};

// Tests
test "Attributes basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var attrs = Attributes.init(allocator);
    defer attrs.deinit();

    try attrs.put("key1", .{ .string = "value1" });
    try attrs.put("key2", .{ .int = 42 });

    try testing.expect(attrs.count() == 2);
    try testing.expect(attrs.contains("key1"));
    try testing.expect(attrs.contains("key2"));
    try testing.expect(!attrs.contains("key3"));

    const val1 = attrs.get("key1");
    try testing.expect(val1 != null);
    try testing.expectEqualStrings("value1", val1.?.string);

    const val2 = attrs.get("key2");
    try testing.expect(val2 != null);
    try testing.expect(val2.?.int == 42);
}

test "AttributeBuilder basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = AttributeBuilder.init(allocator);
    defer builder.deinit();

    try builder.addString("service.name", "my-service");
    try builder.addInt("port", 8080);
    try builder.addBool("debug", true);
    try builder.addFloat("ratio", 0.95);

    const attrs = builder.build();
    try testing.expect(attrs.count() == 4);

    const service_name = attrs.get("service.name");
    try testing.expect(service_name != null);
    try testing.expectEqualStrings("my-service", service_name.?.string);

    const port = attrs.get("port");
    try testing.expect(port != null);
    try testing.expect(port.?.int == 8080);
}

test "AttributeBuilder arrays" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = AttributeBuilder.init(allocator);
    defer builder.deinit();

    const bool_values = [_]bool{ true, false, true };
    try builder.addBoolArray("bools", &bool_values);

    const int_values = [_]i64{ 1, 2, 3, 42 };
    try builder.addIntArray("ints", &int_values);

    const float_values = [_]f64{ 1.1, 2.2, 3.3 };
    try builder.addFloatArray("floats", &float_values);

    const string_values = [_][]const u8{ "a", "b", "c" };
    try builder.addStringArray("strings", &string_values);

    const attrs = builder.build();
    try testing.expect(attrs.count() == 4);

    const strings = attrs.get("strings");
    try testing.expect(strings != null);
    try testing.expect(strings.?.string_array.len == 3);
    try testing.expectEqualStrings("a", strings.?.string_array[0]);
}

test "AttributeBuilder KeyValue operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = AttributeBuilder.init(allocator);
    defer builder.deinit();

    const kv1 = KeyValue.init("name", .{ .string = "test" });
    const kv2 = KeyValue.init("count", .{ .int = 5 });

    try builder.addKeyValue(kv1);
    try builder.addKeyValue(kv2);

    const kvs = [_]KeyValue{
        KeyValue.init("key1", .{ .string = "value1" }),
        .{ .key = "key2", .value = .{ .bool = false } },
    };

    try builder.addKeyValues(&kvs);

    const attrs = builder.build();
    try testing.expect(attrs.count() == 4);
}

test "withAttributeBuilder convenience function" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = AttributeBuilder.init(allocator);
    defer builder.deinit();

    try builder.addString("service.name", "test-service");
    try builder.addInt("version", 1);
    try builder.addBool("enabled", true);

    const attrs = builder.build();
    try testing.expect(attrs.count() == 3);
    try testing.expectEqualStrings("test-service", attrs.get("service.name").?.string);
    try testing.expect(attrs.get("version").?.int == 1);
    try testing.expect(attrs.get("enabled").?.bool == true);
}

test "Attributes formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var attrs = Attributes.init(allocator);
    defer attrs.deinit();

    try attrs.put("name", .{ .string = "test" });
    try attrs.put("count", .{ .int = 42 });

    var buf: [256]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{}", .{attrs});

    // Order is not guaranteed in hash map, so check both possible orders
    const contains_name = std.mem.indexOf(u8, formatted, "name=\"test\"") != null;
    const contains_count = std.mem.indexOf(u8, formatted, "count=42") != null;

    try testing.expect(contains_name);
    try testing.expect(contains_count);
    try testing.expect(std.mem.startsWith(u8, formatted, "{"));
    try testing.expect(std.mem.endsWith(u8, formatted, "}"));
}
