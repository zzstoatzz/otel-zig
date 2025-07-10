//! OpenTelemetry Configuration Value API
//!
//! This module defines the ConfigValue type for representing configuration data
//! with support for hierarchical navigation and type-safe value extraction.
//!
//! ConfigValue supports the three-state null handling required by the OpenTelemetry
//! configuration specification: not_set, null, and actual values.
//!
//! ## Usage
//!
//! ```zig
//! // Navigation with chaining
//! const headers = config.get("general").get("http").get("client").get("request_captured_headers");
//! const header_list = headers.asStringArray() orelse &[_][]const u8{};
//!
//! // Array access
//! const first_processor = config.get("processors").at(0).get("batch");
//!
//! // State checking
//! const value = config.get("timeout");
//! if (value.isSet()) {
//!     const timeout = value.asInt() orelse 30000;
//! }
//! ```

const std = @import("std");
const ConfigProperties = @import("config_properties.zig").ConfigProperties;
const reportValidationError = @import("../common/error_handler.zig").reportValidationError;

/// ConfigValue represents a configuration value with support for hierarchical navigation
/// and type-safe value extraction. It follows a three-state model: not_set, null, and value.
pub const ConfigValue = union(enum) {
    /// Property is not present in the configuration
    not_set: void,

    /// Property is present but explicitly set to null
    null: void,

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

    /// Nested configuration properties (non-owning)
    map: ConfigProperties,

    /// Array of configuration values (non-owning)
    array: []const ConfigValue,

    /// Navigate to a nested property by key
    /// Returns not_set if the key doesn't exist or this value is not a map
    pub fn get(self: ConfigValue, key: []const u8) ConfigValue {
        return switch (self) {
            .map => |props| props.get(key),
            .not_set, .null => .not_set,
            else => .not_set,
        };
    }

    /// Access an array element by index
    /// Returns not_set if the index is out of bounds or this value is not an array
    pub fn at(self: ConfigValue, index: usize) ConfigValue {
        return switch (self) {
            .array => |arr| if (index < arr.len) arr[index] else .not_set,
            .bool_array => |arr| if (index < arr.len) .{ .bool = arr[index] } else .not_set,
            .int_array => |arr| if (index < arr.len) .{ .int = arr[index] } else .not_set,
            .float_array => |arr| if (index < arr.len) .{ .float = arr[index] } else .not_set,
            .string_array => |arr| if (index < arr.len) .{ .string = arr[index] } else .not_set,
            .not_set, .null => .not_set,
            else => .not_set,
        };
    }

    /// Extract string value, returns null if not a string or not set/null
    pub fn asString(self: ConfigValue) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            .not_set, .null => null,
            else => {
                reportValidationError(.config, "asString", "Expected string, got type", self.getTypeName());
                return null;
            },
        };
    }

    /// Extract boolean value, returns null if not a boolean or not set/null
    pub fn asBool(self: ConfigValue) ?bool {
        return switch (self) {
            .bool => |b| b,
            .not_set, .null => null,
            else => {
                reportValidationError(.config, "asBool", "Expected bool, got type", self.getTypeName());
                return null;
            },
        };
    }

    /// Extract integer value, returns null if not an integer or not set/null
    pub fn asInt(self: ConfigValue) ?i64 {
        return switch (self) {
            .int => |i| i,
            .not_set, .null => null,
            else => {
                reportValidationError(.config, "asInt", "Expected int, got type", self.getTypeName());
                return null;
            },
        };
    }

    /// Extract float value, returns null if not a float or not set/null
    pub fn asFloat(self: ConfigValue) ?f64 {
        return switch (self) {
            .float => |f| f,
            .not_set, .null => null,
            else => {
                reportValidationError(.config, "asFloat", "Expected float, got type", self.getTypeName());
                return null;
            },
        };
    }

    /// Extract string array, returns null if not a string array or not set/null
    pub fn asStringArray(self: ConfigValue) ?[]const []const u8 {
        return switch (self) {
            .string_array => |arr| arr,
            .not_set, .null => null,
            else => {
                reportValidationError(.config, "asStringArray", "Expected string_array, got type", self.getTypeName());
                return null;
            },
        };
    }

    /// Extract boolean array, returns null if not a boolean array or not set/null
    pub fn asBoolArray(self: ConfigValue) ?[]const bool {
        return switch (self) {
            .bool_array => |arr| arr,
            .not_set, .null => null,
            else => {
                reportValidationError(.config, "asBoolArray", "Expected bool_array, got type", self.getTypeName());
                return null;
            },
        };
    }

    /// Extract integer array, returns null if not an integer array or not set/null
    pub fn asIntArray(self: ConfigValue) ?[]const i64 {
        return switch (self) {
            .int_array => |arr| arr,
            .not_set, .null => null,
            else => {
                reportValidationError(.config, "asIntArray", "Expected int_array, got type", self.getTypeName());
                return null;
            },
        };
    }

    /// Extract float array, returns null if not a float array or not set/null
    pub fn asFloatArray(self: ConfigValue) ?[]const f64 {
        return switch (self) {
            .float_array => |arr| arr,
            .not_set, .null => null,
            else => {
                reportValidationError(.config, "asFloatArray", "Expected float_array, got type", self.getTypeName());
                return null;
            },
        };
    }

    /// Extract array of ConfigValues, returns null if not an array or not set/null
    pub fn asArray(self: ConfigValue) ?[]const ConfigValue {
        return switch (self) {
            .array => |arr| arr,
            .not_set, .null => null,
            else => {
                reportValidationError(.config, "asArray", "Expected array, got type", self.getTypeName());
                return null;
            },
        };
    }

    /// Check if this value is set (not not_set)
    pub inline fn isSet(self: ConfigValue) bool {
        return self != .not_set;
    }

    /// Check if this value is explicitly null
    pub inline fn isNull(self: ConfigValue) bool {
        return self == .null;
    }

    /// Get the type name of this value for error reporting
    pub fn getTypeName(self: ConfigValue) []const u8 {
        return switch (self) {
            .not_set => "not_set",
            .null => "null",
            .bool => "bool",
            .int => "int",
            .float => "float",
            .string => "string",
            .bool_array => "bool_array",
            .int_array => "int_array",
            .float_array => "float_array",
            .string_array => "string_array",
            .map => "map",
            .array => "array",
        };
    }

    /// Format this ConfigValue for debugging and logging
    pub fn format(self: ConfigValue, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        switch (self) {
            .not_set => try writer.writeAll("not_set"),
            .null => try writer.writeAll("null"),
            .bool => |b| try writer.print("{}", .{b}),
            .int => |i| try writer.print("{}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .bool_array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{item});
                }
                try writer.writeAll("]");
            },
            .int_array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{item});
                }
                try writer.writeAll("]");
            },
            .float_array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{item});
                }
                try writer.writeAll("]");
            },
            .string_array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("\"{s}\"", .{item});
                }
                try writer.writeAll("]");
            },
            .map => try writer.writeAll("map{...}"),
            .array => |arr| try writer.print("array[{}]", .{arr.len}),
        }
    }
};

// Tests
test "ConfigValue basic types" {
    const testing = std.testing;

    const str_val = ConfigValue{ .string = "hello" };
    try testing.expectEqualStrings("hello", str_val.asString().?);
    try testing.expect(str_val.isSet());
    try testing.expect(!str_val.isNull());

    const bool_val = ConfigValue{ .bool = true };
    try testing.expect(bool_val.asBool().? == true);

    const not_set_val = ConfigValue{ .not_set = {} };
    try testing.expect(not_set_val.asString() == null);
    try testing.expect(!not_set_val.isSet());
    try testing.expect(!not_set_val.isNull());

    const null_val = ConfigValue{ .null = {} };
    try testing.expect(null_val.asString() == null);
    try testing.expect(null_val.isSet());
    try testing.expect(null_val.isNull());
}

test "ConfigValue array access" {
    const testing = std.testing;

    const values = [_]ConfigValue{
        .{ .string = "first" },
        .{ .int = 42 },
        .{ .bool = true },
    };

    const array_val = ConfigValue{ .array = &values };

    try testing.expectEqualStrings("first", array_val.at(0).asString().?);
    try testing.expect(array_val.at(1).asInt().? == 42);
    try testing.expect(array_val.at(2).asBool().? == true);
    try testing.expect(array_val.at(999).isSet() == false);

    // Test null propagation
    const not_set_val = ConfigValue{ .not_set = {} };
    try testing.expect(not_set_val.at(0).isSet() == false);
}

test "ConfigValue type names" {
    const testing = std.testing;

    try testing.expectEqualStrings("string", (ConfigValue{ .string = "test" }).getTypeName());
    try testing.expectEqualStrings("bool", (ConfigValue{ .bool = true }).getTypeName());
    try testing.expectEqualStrings("int", (ConfigValue{ .int = 42 }).getTypeName());
    try testing.expectEqualStrings("not_set", (ConfigValue{ .not_set = {} }).getTypeName());
    try testing.expectEqualStrings("null", (ConfigValue{ .null = {} }).getTypeName());
}

test "ConfigValue arrays" {
    const testing = std.testing;

    const strings = [_][]const u8{ "hello", "world" };
    const string_array_val = ConfigValue{ .string_array = &strings };

    const result = string_array_val.asStringArray().?;
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("hello", result[0]);
    try testing.expectEqualStrings("world", result[1]);

    const ints = [_]i64{ 1, 2, 3 };
    const int_array_val = ConfigValue{ .int_array = &ints };

    const int_result = int_array_val.asIntArray().?;
    try testing.expectEqual(@as(usize, 3), int_result.len);
    try testing.expectEqual(@as(i64, 1), int_result[0]);
    try testing.expectEqual(@as(i64, 2), int_result[1]);
    try testing.expectEqual(@as(i64, 3), int_result[2]);
}

test "ConfigValue null propagation" {
    const testing = std.testing;

    const not_set_val = ConfigValue{ .not_set = {} };
    const null_val = ConfigValue{ .null = {} };

    // get() on not_set/null should return not_set
    try testing.expect(not_set_val.get("any_key") == .not_set);
    try testing.expect(null_val.get("any_key") == .not_set);

    // at() on not_set/null should return not_set
    try testing.expect(not_set_val.at(0) == .not_set);
    try testing.expect(null_val.at(0) == .not_set);

    // Non-map/array types should return not_set for navigation
    const string_val = ConfigValue{ .string = "test" };
    try testing.expect(string_val.get("key") == .not_set);
    try testing.expect(string_val.at(0) == .not_set);
}

test "ConfigValue comprehensive instrumentation scenario" {
    const testing = std.testing;
    const ConfigPropertiesBridge = @import("config_properties.zig").ConfigPropertiesBridge;

    // Simulate a realistic instrumentation configuration scenario
    // Testing the full chain: ConfigProvider -> ConfigProperties -> ConfigValue navigation

    // Static data that persists throughout the test
    const headers = [_][]const u8{ "Content-Type", "Accept", "Authorization" };

    // Mock HTTP instrumentation configuration structure
    const HttpClientConfig = struct {
        const Self = @This();

        pub fn get(self: *const Self, key: []const u8) ConfigValue {
            _ = self;
            if (std.mem.eql(u8, key, "request_captured_headers")) {
                return ConfigValue{ .string_array = &headers };
            } else if (std.mem.eql(u8, key, "timeout")) {
                return ConfigValue{ .int = 30000 };
            } else if (std.mem.eql(u8, key, "enabled")) {
                return ConfigValue{ .bool = true };
            } else if (std.mem.eql(u8, key, "debug")) {
                return ConfigValue{ .null = {} }; // Explicitly set to null
            }
            return .not_set;
        }
    };

    // Make structs static to avoid stack issues
    var client_config = HttpClientConfig{};
    const client_props = ConfigProperties{ .bridge = ConfigPropertiesBridge.init(&client_config) };

    const HttpConfig = struct {
        props: ConfigProperties,

        pub fn get(self: *const @This(), key: []const u8) ConfigValue {
            if (std.mem.eql(u8, key, "client")) {
                return ConfigValue{ .map = self.props };
            }
            return .not_set;
        }
    };

    var http_config = HttpConfig{ .props = client_props };
    const http_props = ConfigProperties{ .bridge = ConfigPropertiesBridge.init(&http_config) };

    const GeneralConfig = struct {
        props: ConfigProperties,

        pub fn get(self: *const @This(), key: []const u8) ConfigValue {
            if (std.mem.eql(u8, key, "http")) {
                return ConfigValue{ .map = self.props };
            }
            return .not_set;
        }
    };

    var general_config = GeneralConfig{ .props = http_props };
    const general_props = ConfigProperties{ .bridge = ConfigPropertiesBridge.init(&general_config) };

    const RootConfig = struct {
        props: ConfigProperties,

        pub fn get(self: *const @This(), key: []const u8) ConfigValue {
            if (std.mem.eql(u8, key, "general")) {
                return ConfigValue{ .map = self.props };
            }
            return .not_set;
        }
    };

    var root_config = RootConfig{ .props = general_props };
    const root_props = ConfigProperties{ .bridge = ConfigPropertiesBridge.init(&root_config) };
    const config_root = ConfigValue{ .map = root_props };

    // Test instrumentation library usage patterns

    // 1. Navigate to HTTP client configuration
    const http_client = config_root.get("general").get("http").get("client");
    try testing.expect(http_client.isSet());

    // 2. Extract headers to capture (common instrumentation use case)
    const header_result = http_client.get("request_captured_headers").asStringArray() orelse &[_][]const u8{};
    try testing.expectEqual(@as(usize, 3), header_result.len);
    try testing.expectEqualStrings("Content-Type", header_result[0]);
    try testing.expectEqualStrings("Accept", header_result[1]);
    try testing.expectEqualStrings("Authorization", header_result[2]);

    // 3. Get timeout with default value
    const timeout = http_client.get("timeout").asInt() orelse 10000;
    try testing.expectEqual(@as(i64, 30000), timeout);

    // 4. Check if feature is enabled
    const enabled = http_client.get("enabled").asBool() orelse false;
    try testing.expect(enabled);

    // 5. Handle three-state null scenario (not_set vs null vs value)
    const debug_setting = http_client.get("debug");
    try testing.expect(debug_setting.isSet()); // Present in config
    try testing.expect(debug_setting.isNull()); // But explicitly set to null
    const debug_enabled = debug_setting.asBool() orelse false; // Use default for null
    try testing.expect(!debug_enabled);

    // 6. Test missing configuration with fallback
    const missing_setting = http_client.get("missing_key");
    try testing.expect(!missing_setting.isSet());
    const fallback_value = missing_setting.asString() orelse "default_value";
    try testing.expectEqualStrings("default_value", fallback_value);

    // 7. Test invalid navigation path
    const invalid_path = config_root.get("nonexistent").get("path").get("here");
    try testing.expect(!invalid_path.isSet());

    // 8. Test navigation chains successfully complete
    try testing.expect(http_client.isSet());
}
