//! OpenTelemetry Context Implementation
//!
//! This module provides an immutable context for propagating request-scoped values
//! across API boundaries. Context follows explicit Zig idioms with clear ownership
//! and predictable performance characteristics.

const std = @import("std");
const ContextKey = @import("context_key.zig").ContextKey;
const ContextValue = @import("context_key.zig").ContextValue;

/// A key-value pair stored in a context
const KeyValuePair = struct {
    key_id: u64,
    value: ContextValue,
};

/// An immutable context that stores key-value pairs for cross-cutting concerns.
/// Creating new contexts with additional values is explicit via `withValue()`.
pub const Context = struct {
    pairs: []const KeyValuePair,
    allocator: std.mem.Allocator,

    /// Create an empty context
    pub fn empty(allocator: std.mem.Allocator) Context {
        return Context{
            .pairs = &[_]KeyValuePair{},
            .allocator = allocator,
        };
    }

    /// Initialize context with pre-allocated storage
    pub fn init(allocator: std.mem.Allocator) Context {
        return empty(allocator);
    }

    /// Clean up context memory
    pub fn deinit(self: Context) void {
        if (self.pairs.len > 0) {
            self.allocator.free(self.pairs);
        }
    }

    /// Create a new context with an additional key-value pair.
    /// The original context remains unchanged.
    pub fn withValue(self: Context, comptime key: anytype, value: key.ValueType) !Context {
        // Validate that key is a ContextKey type
        comptime {
            if (!@hasDecl(key, "key_id") or !@hasDecl(key, "ValueType")) {
                @compileError("Expected a ContextKey type, got " ++ @typeName(@TypeOf(key)));
            }
        }

        const wrapped_value = key.wrapValue(value);
        const new_pair = KeyValuePair{
            .key_id = key.key_id,
            .value = wrapped_value,
        };

        // Check if key already exists and replace it
        for (self.pairs, 0..) |pair, i| {
            if (pair.key_id == key.key_id) {
                // Replace existing key
                var new_pairs = try self.allocator.alloc(KeyValuePair, self.pairs.len);
                @memcpy(new_pairs, self.pairs);
                new_pairs[i] = new_pair;

                return Context{
                    .pairs = new_pairs,
                    .allocator = self.allocator,
                };
            }
        }

        // Add new key
        var new_pairs = try self.allocator.alloc(KeyValuePair, self.pairs.len + 1);
        @memcpy(new_pairs[0..self.pairs.len], self.pairs);
        new_pairs[self.pairs.len] = new_pair;

        return Context{
            .pairs = new_pairs,
            .allocator = self.allocator,
        };
    }

    /// Retrieve a value by key with compile-time type safety
    pub fn getValue(self: Context, comptime key: anytype) ?key.ValueType {
        // Validate that key is a ContextKey type
        comptime {
            if (!@hasDecl(key, "key_id") or !@hasDecl(key, "ValueType")) {
                @compileError("Expected a ContextKey type, got " ++ @typeName(@TypeOf(key)));
            }
        }

        for (self.pairs) |pair| {
            if (pair.key_id == key.key_id) {
                return key.unwrapValue(pair.value);
            }
        }
        return null;
    }

    /// Check if a key exists in the context
    pub fn hasValue(self: Context, comptime key: anytype) bool {
        // Validate that key is a ContextKey type
        comptime {
            if (!@hasDecl(key, "key_id") or !@hasDecl(key, "ValueType")) {
                @compileError("Expected a ContextKey type, got " ++ @typeName(@TypeOf(key)));
            }
        }

        for (self.pairs) |pair| {
            if (pair.key_id == key.key_id) {
                return true;
            }
        }
        return false;
    }

    /// Create an exact copy of this context
    pub fn clone(self: Context) !Context {
        if (self.pairs.len == 0) {
            return Context.empty(self.allocator);
        }

        const new_pairs = try self.allocator.alloc(KeyValuePair, self.pairs.len);
        @memcpy(new_pairs, self.pairs);

        return Context{
            .pairs = new_pairs,
            .allocator = self.allocator,
        };
    }

    /// Get the number of key-value pairs in this context
    pub fn len(self: Context) usize {
        return self.pairs.len;
    }

    /// Check if the context is empty
    pub fn isEmpty(self: Context) bool {
        return self.pairs.len == 0;
    }

    /// Iterator for walking through all key-value pairs
    pub fn iterator(self: Context) Iterator {
        return Iterator{
            .pairs = self.pairs,
            .index = 0,
        };
    }

    /// Debug formatting for contexts
    pub fn format(
        self: Context,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("Context{ ");
        for (self.pairs, 0..) |pair, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("0x{x}={}", .{ pair.key_id, pair.value });
        }
        try writer.writeAll(" }");
    }
};

/// Iterator for context key-value pairs
pub const Iterator = struct {
    pairs: []const KeyValuePair,
    index: usize,

    /// Get the next key-value pair, or null if at the end
    pub fn next(self: *Iterator) ?KeyValuePair {
        if (self.index >= self.pairs.len) return null;
        defer self.index += 1;
        return self.pairs[self.index];
    }

    /// Reset iterator to the beginning
    pub fn reset(self: *Iterator) void {
        self.index = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Context creation and basic operations" {
    const testing = std.testing;

    // Create empty context
    var ctx = Context.empty(testing.allocator);
    defer ctx.deinit();

    try testing.expect(ctx.isEmpty());
    try testing.expectEqual(@as(usize, 0), ctx.len());
}

test "Context withValue and getValue" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "test.string");
    const IntKey = ContextKey(i64, "test.int");
    const BoolKey = ContextKey(bool, "test.bool");

    var ctx = Context.empty(testing.allocator);
    defer ctx.deinit();

    // Add string value
    const test_string: []const u8 = "hello";
    const ctx2 = try ctx.withValue(StringKey, test_string);
    defer ctx2.deinit();

    try testing.expectEqual(@as(usize, 1), ctx2.len());
    try testing.expect(!ctx2.isEmpty());

    // Retrieve string value
    const retrieved_string = ctx2.getValue(StringKey);
    try testing.expect(retrieved_string != null);
    try testing.expectEqualStrings("hello", retrieved_string.?);

    // Add int value
    const ctx3 = try ctx2.withValue(IntKey, 42);
    defer ctx3.deinit();

    try testing.expectEqual(@as(usize, 2), ctx3.len());

    // Both values should be accessible
    try testing.expectEqualStrings("hello", ctx3.getValue(StringKey).?);
    try testing.expectEqual(@as(i64, 42), ctx3.getValue(IntKey).?);

    // Add bool value
    const ctx4 = try ctx3.withValue(BoolKey, true);
    defer ctx4.deinit();

    try testing.expectEqual(@as(usize, 3), ctx4.len());
    try testing.expectEqualStrings("hello", ctx4.getValue(StringKey).?);
    try testing.expectEqual(@as(i64, 42), ctx4.getValue(IntKey).?);
    try testing.expectEqual(true, ctx4.getValue(BoolKey).?);
}

test "Context hasValue" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "test.string");
    const IntKey = ContextKey(i64, "test.int");
    const UnusedKey = ContextKey(bool, "unused.key");

    var ctx = Context.empty(testing.allocator);
    defer ctx.deinit();

    // Empty context has no values
    try testing.expect(!ctx.hasValue(StringKey));
    try testing.expect(!ctx.hasValue(IntKey));

    // Add a value
    const test_string: []const u8 = "test";
    const ctx2 = try ctx.withValue(StringKey, test_string);
    defer ctx2.deinit();

    try testing.expect(ctx2.hasValue(StringKey));
    try testing.expect(!ctx2.hasValue(IntKey));
    try testing.expect(!ctx2.hasValue(UnusedKey));
}

test "Context key replacement" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "test.key");

    var ctx = Context.empty(testing.allocator);
    defer ctx.deinit();

    // Add initial value
    const first_value: []const u8 = "first";
    const ctx2 = try ctx.withValue(StringKey, first_value);
    defer ctx2.deinit();

    try testing.expectEqualStrings("first", ctx2.getValue(StringKey).?);
    try testing.expectEqual(@as(usize, 1), ctx2.len());

    // Replace with new value
    const second_value: []const u8 = "second";
    const ctx3 = try ctx2.withValue(StringKey, second_value);
    defer ctx3.deinit();

    try testing.expectEqualStrings("second", ctx3.getValue(StringKey).?);
    try testing.expectEqual(@as(usize, 1), ctx3.len()); // Length should stay the same
}

test "Context immutability" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "test.string");
    const IntKey = ContextKey(i64, "test.int");

    var ctx = Context.empty(testing.allocator);
    defer ctx.deinit();

    const test_string: []const u8 = "hello";
    const ctx2 = try ctx.withValue(StringKey, test_string);
    defer ctx2.deinit();

    const ctx3 = try ctx2.withValue(IntKey, 42);
    defer ctx3.deinit();

    // Original contexts should be unchanged
    try testing.expect(ctx.isEmpty());
    try testing.expectEqual(@as(usize, 1), ctx2.len());
    try testing.expect(ctx2.hasValue(StringKey));
    try testing.expect(!ctx2.hasValue(IntKey));

    // New context should have both values
    try testing.expectEqual(@as(usize, 2), ctx3.len());
    try testing.expect(ctx3.hasValue(StringKey));
    try testing.expect(ctx3.hasValue(IntKey));
}

test "Context clone" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "test.string");
    const IntKey = ContextKey(i64, "test.int");

    var ctx = Context.empty(testing.allocator);
    defer ctx.deinit();

    const test_string: []const u8 = "hello";
    const ctx2 = try ctx.withValue(StringKey, test_string);
    defer ctx2.deinit();

    const ctx3 = try ctx2.withValue(IntKey, 42);
    defer ctx3.deinit();

    // Clone the context
    const cloned = try ctx3.clone();
    defer cloned.deinit();

    // Clone should have same values
    try testing.expectEqual(ctx3.len(), cloned.len());
    try testing.expectEqualStrings("hello", cloned.getValue(StringKey).?);
    try testing.expectEqual(@as(i64, 42), cloned.getValue(IntKey).?);

    // Clone empty context
    const empty_clone = try ctx.clone();
    defer empty_clone.deinit();
    try testing.expect(empty_clone.isEmpty());
}

test "Context iterator" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "test.string");
    const IntKey = ContextKey(i64, "test.int");
    const BoolKey = ContextKey(bool, "test.bool");

    var ctx = Context.empty(testing.allocator);
    defer ctx.deinit();

    const test_string: []const u8 = "hello";
    const ctx2 = try ctx.withValue(StringKey, test_string);
    defer ctx2.deinit();

    const ctx3 = try ctx2.withValue(IntKey, 42);
    defer ctx3.deinit();

    const ctx4 = try ctx3.withValue(BoolKey, true);
    defer ctx4.deinit();

    // Iterate through all pairs
    var iter = ctx4.iterator();
    var count: usize = 0;
    var found_string = false;
    var found_int = false;
    var found_bool = false;

    while (iter.next()) |pair| {
        count += 1;
        if (pair.key_id == StringKey.key_id) found_string = true;
        if (pair.key_id == IntKey.key_id) found_int = true;
        if (pair.key_id == BoolKey.key_id) found_bool = true;
    }

    try testing.expectEqual(@as(usize, 3), count);
    try testing.expect(found_string);
    try testing.expect(found_int);
    try testing.expect(found_bool);

    // Reset and iterate again
    iter.reset();
    count = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "Context getValue with wrong key returns null" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "test.string");
    const IntKey = ContextKey(i64, "test.int");
    const UnusedKey = ContextKey(bool, "unused.key");

    var ctx = Context.empty(testing.allocator);
    defer ctx.deinit();

    const test_string: []const u8 = "hello";
    const ctx2 = try ctx.withValue(StringKey, test_string);
    defer ctx2.deinit();

    // Existing key should return value
    try testing.expect(ctx2.getValue(StringKey) != null);

    // Non-existent keys should return null
    try testing.expect(ctx2.getValue(IntKey) == null);
    try testing.expect(ctx2.getValue(UnusedKey) == null);
}

test "Context with different value types" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "string.key");
    const IntKey = ContextKey(i64, "int.key");
    const UintKey = ContextKey(u64, "uint.key");
    const FloatKey = ContextKey(f64, "float.key");
    const BoolKey = ContextKey(bool, "bool.key");

    var ctx = Context.empty(testing.allocator);
    defer ctx.deinit();

    const test_string: []const u8 = "test";
    const ctx2 = try ctx.withValue(StringKey, test_string);
    defer ctx2.deinit();

    const ctx3 = try ctx2.withValue(IntKey, -123);
    defer ctx3.deinit();

    const ctx4 = try ctx3.withValue(UintKey, 456);
    defer ctx4.deinit();

    const ctx5 = try ctx4.withValue(FloatKey, 3.14);
    defer ctx5.deinit();

    const ctx6 = try ctx5.withValue(BoolKey, false);
    defer ctx6.deinit();

    // All values should be retrievable with correct types
    try testing.expectEqualStrings("test", ctx6.getValue(StringKey).?);
    try testing.expectEqual(@as(i64, -123), ctx6.getValue(IntKey).?);
    try testing.expectEqual(@as(u64, 456), ctx6.getValue(UintKey).?);
    try testing.expectEqual(@as(f64, 3.14), ctx6.getValue(FloatKey).?);
    try testing.expectEqual(false, ctx6.getValue(BoolKey).?);
}

test "Context and ContextKey integration" {
    const testing = std.testing;

    // Define some realistic OpenTelemetry-style keys
    const USER_ID_KEY = ContextKey([]const u8, "user.id");
    const REQUEST_ID_KEY = ContextKey([]const u8, "request.id");
    const TIMEOUT_MS_KEY = ContextKey(i64, "request.timeout_ms");
    const DEBUG_ENABLED_KEY = ContextKey(bool, "debug.enabled");
    const RETRY_COUNT_KEY = ContextKey(u64, "retry.count");
    const QUALITY_SCORE_KEY = ContextKey(f64, "quality.score");

    // Build a realistic request context
    var base_ctx = Context.empty(testing.allocator);
    defer base_ctx.deinit();

    // Add user context
    const user_id: []const u8 = "user-12345";
    const user_ctx = try base_ctx.withValue(USER_ID_KEY, user_id);
    defer user_ctx.deinit();

    // Add request context
    const request_id: []const u8 = "req-67890";
    const request_ctx = try user_ctx.withValue(REQUEST_ID_KEY, request_id);
    defer request_ctx.deinit();

    // Add operational context
    const ops_ctx = try request_ctx.withValue(TIMEOUT_MS_KEY, 5000);
    defer ops_ctx.deinit();

    const debug_ctx = try ops_ctx.withValue(DEBUG_ENABLED_KEY, true);
    defer debug_ctx.deinit();

    const retry_ctx = try debug_ctx.withValue(RETRY_COUNT_KEY, 3);
    defer retry_ctx.deinit();

    const final_ctx = try retry_ctx.withValue(QUALITY_SCORE_KEY, 0.95);
    defer final_ctx.deinit();

    // Verify all values are accessible and type-safe
    try testing.expectEqualStrings("user-12345", final_ctx.getValue(USER_ID_KEY).?);
    try testing.expectEqualStrings("req-67890", final_ctx.getValue(REQUEST_ID_KEY).?);
    try testing.expectEqual(@as(i64, 5000), final_ctx.getValue(TIMEOUT_MS_KEY).?);
    try testing.expectEqual(true, final_ctx.getValue(DEBUG_ENABLED_KEY).?);
    try testing.expectEqual(@as(u64, 3), final_ctx.getValue(RETRY_COUNT_KEY).?);
    try testing.expectEqual(@as(f64, 0.95), final_ctx.getValue(QUALITY_SCORE_KEY).?);

    // Verify intermediate contexts are unchanged (immutability)
    try testing.expectEqualStrings("user-12345", user_ctx.getValue(USER_ID_KEY).?);
    try testing.expect(user_ctx.getValue(REQUEST_ID_KEY) == null);
    try testing.expect(user_ctx.getValue(TIMEOUT_MS_KEY) == null);

    // Test context composition pattern
    const minimal_ctx = try base_ctx.withValue(USER_ID_KEY, user_id);
    defer minimal_ctx.deinit();

    const composed_ctx = try minimal_ctx.withValue(DEBUG_ENABLED_KEY, false);
    defer composed_ctx.deinit();

    try testing.expectEqualStrings("user-12345", composed_ctx.getValue(USER_ID_KEY).?);
    try testing.expectEqual(false, composed_ctx.getValue(DEBUG_ENABLED_KEY).?);
    try testing.expect(composed_ctx.getValue(REQUEST_ID_KEY) == null);

    // Test key replacement
    const updated_timeout_ctx = try final_ctx.withValue(TIMEOUT_MS_KEY, 10000);
    defer updated_timeout_ctx.deinit();

    try testing.expectEqual(@as(i64, 10000), updated_timeout_ctx.getValue(TIMEOUT_MS_KEY).?);
    try testing.expectEqual(@as(i64, 5000), final_ctx.getValue(TIMEOUT_MS_KEY).?); // Original unchanged

    // Verify final context properties
    try testing.expectEqual(@as(usize, 6), final_ctx.len());
    try testing.expect(!final_ctx.isEmpty());
    try testing.expect(final_ctx.hasValue(USER_ID_KEY));
    try testing.expect(final_ctx.hasValue(QUALITY_SCORE_KEY));
    try testing.expect(!final_ctx.hasValue(ContextKey([]const u8, "nonexistent.key")));
}
