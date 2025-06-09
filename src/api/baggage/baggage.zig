//! OpenTelemetry Baggage API Implementation
//!
//! This module provides the baggage API types according to the OpenTelemetry specification.
//! Baggage is an immutable container for string key-value pairs that propagate across
//! process boundaries.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/baggage/api.md

const std = @import("std");

/// A single baggage entry consisting of a key-value pair and optional metadata
pub const BaggageKeyValue = struct {
    /// The baggage key
    key: []const u8,

    /// The baggage value
    value: []const u8,

    /// Optional metadata
    metadata: ?[]const u8 = null,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
        metadata: ?[]const u8,
    ) !BaggageKeyValue {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);
        const owned_metadata = if (metadata) |md| try allocator.dupe(u8, md) else null;
        errdefer if (owned_metadata) |md| allocator.free(md);

        return .{ .key = owned_key, .value = owned_value, .metadata = owned_metadata };
    }

    pub fn initOwnedSlice(allocator: std.mem.Allocator, unowned: []BaggageKeyValue) ![]BaggageKeyValue {
        var owned = try allocator.alloc(BaggageKeyValue, unowned.len);
        for (0..unowned.len) |h| {
            owned[h] = try initOwned(allocator, unowned[h].key, unowned[h].value, unowned[h].metadata);
        }
        return owned;
    }

    pub fn deinitOwned(self: BaggageKeyValue, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        if (self.metadata) |metadata| {
            allocator.free(metadata);
        }
    }

    /// Destroy a deep copied slice of BaggageKeyValue.
    pub fn deinitOwnedSlice(allocator: std.mem.Allocator, slice: []const BaggageKeyValue) void {
        for (0..slice.len) |h| slice[h].deinitOwned(allocator);
        allocator.free(slice);
    }

    /// Check if two entries are equal
    pub fn eql(self: BaggageKeyValue, other: BaggageKeyValue) bool {
        if (!std.mem.eql(u8, self.key, other.key)) return false;
        if (!std.mem.eql(u8, self.value, other.value)) return false;

        // Compare metadata
        // TODO decide if metadata should really be part of the
        // baggage equality.
        if (self.metadata == null and other.metadata == null) return true;
        if (self.metadata == null or other.metadata == null) return false;

        return true;
    }

    /// Format the entry for debugging/display
    pub fn format(
        self: BaggageKeyValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s}={s}", .{ self.key, self.value });
        if (self.metadata) |meta| {
            try writer.print("{s}", .{meta});
        }
    }
};

/// BaggageBuilder provides a functional interface for constructing arrays of BaggageKeyValue
pub const BaggageBuilder = union(enum) {
    valid: struct {
        allocator: std.mem.Allocator,
        entries: []BaggageKeyValue,
    },
    invalid: anyerror,

    /// Initialize a new BaggageBuilder
    pub fn init(allocator: std.mem.Allocator) BaggageBuilder {
        const entries = allocator.alloc(BaggageKeyValue, 0) catch |e| return .{ .invalid = e };
        return .{
            .valid = .{
                .allocator = allocator,
                .entries = entries,
            },
        };
    }

    /// Clean up resources held by the builder
    pub fn deinit(self: BaggageBuilder) void {
        switch (self) {
            .valid => |valid| {
                valid.allocator.free(valid.entries);
            },
            .invalid => {},
        }
    }

    /// Add a baggage entry without metadata
    pub inline fn add(self: BaggageBuilder, key: []const u8, value: []const u8) BaggageBuilder {
        return self.addKeyValue(.{ .key = key, .value = value });
    }

    /// Add a baggage entry with metadata
    pub fn addWithMetadata(self: BaggageBuilder, key: []const u8, value: []const u8, metadata: ?[]const u8) BaggageBuilder {
        return self.addKeyValue(.{ .key = key, .value = value, .metadata = metadata });
    }

    /// Add a pre-constructed baggage entry
    pub fn addKeyValue(self: BaggageBuilder, new_kv: BaggageKeyValue) BaggageBuilder {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                const new_len = builder.entries.len + 1;
                const new_entries = builder.allocator.alloc(BaggageKeyValue, new_len) catch |e| return .{ .invalid = e };
                errdefer builder.allocator.free(new_entries);
                @memcpy(new_entries[0..builder.entries.len], builder.entries);
                new_entries[builder.entries.len] = new_kv;

                break :blk .{
                    .valid = .{
                        .allocator = builder.allocator,
                        .entries = new_entries,
                    },
                };
            },
            .invalid => self,
        };
    }

    /// Add multiple BaggageKeyValue pairs at once
    pub fn addKeyValues(self: BaggageBuilder, kvs: []const BaggageKeyValue) BaggageBuilder {
        var current = self;
        for (kvs) |kv| {
            current = current.add(kv);
        }
        return current;
    }

    /// Finish building and return the final array of BaggageKeyValue
    /// This consumes the builder and automatically handles cleanup
    pub fn finish(self: BaggageBuilder, target_allocator: std.mem.Allocator) ![]BaggageKeyValue {
        defer self.deinit();
        return switch (self) {
            .valid => |builder| blk: {
                const kvs = try BaggageKeyValue.initOwnedSlice(target_allocator, builder.entries);
                break :blk kvs;
            },
            .invalid => |e| e,
        };
    }
};

test "BaggageBuilder basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test empty builder
    const empty_entries = try BaggageBuilder.init(allocator).finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, empty_entries);

    try testing.expectEqual(@as(usize, 0), empty_entries.len);

    // Test single entry
    const single_entries = try BaggageBuilder.init(allocator)
        .add("user.id", "12345")
        .finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, single_entries);

    try testing.expectEqual(@as(usize, 1), single_entries.len);
    try testing.expectEqualStrings("user.id", single_entries[0].key);
    try testing.expectEqualStrings("12345", single_entries[0].value);
}

test "BaggageBuilder functional chaining" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entries = try BaggageBuilder.init(allocator)
        .add("key1", "value1")
        .addWithMetadata("key2", "value2", "metadata")
        .add("key1", "duplicate_value") // duplicate key appended
        .finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, entries);

    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("key1", entries[0].key);
    try testing.expectEqualStrings("value1", entries[0].value);
    try testing.expectEqualStrings("key2", entries[1].key);
    try testing.expectEqualStrings("value2", entries[1].value);
    try testing.expectEqualStrings("key1", entries[2].key);
    try testing.expectEqualStrings("duplicate_value", entries[2].value);
}

test "BaggageBuilder with pre-constructed entries" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use non-owned entry since the builder will create owned copies
    const entry = BaggageKeyValue{ .key = "test.key", .value = "test.value", .metadata = "some.metadata" };

    const entries = try BaggageBuilder.init(allocator)
        .addKeyValue(entry)
        .add("another.key", "another.value")
        .finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("test.key", entries[0].key);
    try testing.expectEqualStrings("test.value", entries[0].value);
    try testing.expectEqualStrings("another.key", entries[1].key);
    try testing.expectEqualStrings("another.value", entries[1].value);
}

test "BaggageKeyValue basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test creating and using individual entries
    const entry1 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = null };
    const entry2 = BaggageKeyValue{ .key = "session.id", .value = "abcdef", .metadata = "metadata" };

    try testing.expectEqualStrings("user.id", entry1.key);
    try testing.expectEqualStrings("12345", entry1.value);
    try testing.expect(entry1.metadata == null);

    try testing.expectEqualStrings("session.id", entry2.key);
    try testing.expectEqualStrings("abcdef", entry2.value);
    try testing.expectEqualStrings("metadata", entry2.metadata.?);

    // Test owned entries
    const owned_entry = try BaggageKeyValue.initOwned(allocator, "owned.key", "owned.value", "owned.metadata");
    defer owned_entry.deinitOwned(allocator);

    try testing.expectEqualStrings("owned.key", owned_entry.key);
    try testing.expectEqualStrings("owned.value", owned_entry.value);
    try testing.expectEqualStrings("owned.metadata", owned_entry.metadata.?);
}
