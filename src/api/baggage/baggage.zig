//! OpenTelemetry Baggage API Implementation
//!
//! This module provides the baggage API types according to the OpenTelemetry specification.
//! Baggage is an immutable container for string key-value pairs that propagate across
//! process boundaries.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/baggage/api.md

const std = @import("std");

/// A single baggage entry consisting of a key-value pair and optional metadata
pub const BaggageEntry = struct {
    /// The baggage key
    key: []const u8,

    /// The baggage value
    value: []const u8,

    /// Optional metadata
    metadata: ?[]const u8 = null,

    /// Create a new baggage entry
    pub fn init(key: []const u8, value: []const u8, metadata: ?[]const u8) BaggageEntry {
        return .{
            .key = key,
            .value = value,
            .metadata = metadata,
        };
    }

    pub fn initOwned(
        allocator: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
        metadata: ?[]const u8,
    ) !BaggageEntry {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);
        const owned_metadata = if (metadata) |md| try allocator.dupe(u8, md) else null;
        errdefer if (owned_metadata) |md| allocator.free(md);

        return init(owned_key, owned_value, owned_metadata);
    }

    pub fn deinitOwned(self: BaggageEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        if (self.metadata) |metadata| {
            allocator.free(metadata);
        }
    }

    /// Check if two entries are equal
    pub fn eql(self: BaggageEntry, other: BaggageEntry) bool {
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
        self: BaggageEntry,
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

/// Baggage is an immutable collection of key-value pairs
///
/// Baggage is self managed, and makes copies of all the values
/// that it stores.
pub const Baggage = struct {
    /// Internal storage of entries
    entries: []const BaggageEntry,

    /// Allocator used for this baggage instance
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, entries: []const BaggageEntry) Baggage {
        return .{
            .entries = entries,
            .allocator = allocator,
        };
    }

    pub fn initBuildFn(allocator: std.mem.Allocator, context: anytype, buildFn: BaggageBuildFn(@TypeOf(context))) !Baggage {
        var builder = BaggageBuilder.init(allocator);
        errdefer builder.deinit();
        try builder.putFunction(context, buildFn);
        return try builder.finish(allocator);
    }

    pub fn empty(allocator: std.mem.Allocator) Baggage {
        return .{
            .entries = &[_]BaggageEntry{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Baggage) void {
        for (self.entries) |entry| entry.deinitOwned(self.allocator);
        if (self.entries.len > 0) self.allocator.free(self.entries);
    }

    /// Get a value by key
    pub fn getValue(self: *const Baggage, key: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        return null;
    }

    /// Check if baggage is empty
    pub fn isEmpty(self: *const Baggage) bool {
        return self.entries.len == 0;
    }
};

pub fn BaggageBuildFn(comptime T: type) type {
    return fn (T, *BaggageBuilder) anyerror!void;
}

/// Builder for constructing baggage instances
pub const BaggageBuilder = struct {
    entries: std.StringHashMapUnmanaged(BaggageEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BaggageBuilder {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn initFromBaggage(baggage: Baggage, allocator: std.mem.Allocator) !BaggageBuilder {
        var new_builder = init(allocator);
        errdefer new_builder.deinit();

        for (baggage.entries) |entry| {
            try new_builder.putWithMetadata(entry.key, entry.value, entry.metadata);
        }

        return new_builder;
    }

    pub fn deinit(self: *BaggageBuilder) void {
        self.entries.deinit(self.allocator);
    }

    /// Add or update an entry
    pub fn putWithMetadata(self: *BaggageBuilder, key: []const u8, value: []const u8, metadata: ?[]const u8) !void {
        // Letting the hashmap squash duplicates.
        try self.entries.put(
            self.allocator,
            key,
            BaggageEntry.init(key, value, metadata),
        );
    }

    /// Add or update a simple entry without metadata
    pub inline fn put(self: *BaggageBuilder, key: []const u8, value: []const u8) !void {
        try self.putWithMetadata(key, value, null);
    }

    pub fn putMany(self: *BaggageBuilder, pairs: []const struct { []const u8, []const u8 }) !void {
        for (pairs) |pair| try self.putWithMetadata(pair[0], pair[1], null);
    }

    pub fn putFunction(self: *BaggageBuilder, context: anytype, buildFn: BaggageBuildFn(@TypeOf(context))) !void {
        try buildFn(context, self);
    }

    pub inline fn get(self: BaggageBuilder, key: []const u8) ?BaggageEntry {
        return self.entries.get(key);
    }

    /// Remove an entry
    pub fn remove(self: *BaggageBuilder, key: []const u8) bool {
        return self.entries.remove(key);
    }

    /// Build the final slice of `BaggageEntry`.
    ///
    /// The `BaggageEntry`s in the arraylist are unowned. It is the callers
    /// responsibility to call `deinit()` on the `ArrayList`.
    pub fn build(self: *const BaggageBuilder) ![]BaggageEntry {
        var entries = std.ArrayListUnmanaged(BaggageEntry).empty;
        defer entries.deinit(self.allocator);
        try entries.ensureTotalCapacityPrecise(self.allocator, self.entries.count());

        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            try entries.append(self.allocator, kv.value_ptr.*);
        }

        return entries.toOwnedSlice(self.allocator);
    }

    pub fn finish(self: *BaggageBuilder, target_allocator: std.mem.Allocator) !Baggage {
        const source = try self.build();
        defer self.allocator.free(source);

        var entries = std.ArrayListUnmanaged(BaggageEntry).empty;
        defer entries.deinit(target_allocator);
        try entries.ensureTotalCapacityPrecise(target_allocator, source.len);

        errdefer for (entries.items) |entry| entry.deinitOwned(target_allocator);
        for (source) |entry| {
            const owned_entry = try BaggageEntry.initOwned(
                target_allocator,
                entry.key,
                entry.value,
                entry.metadata,
            );
            errdefer owned_entry.deinitOwned(target_allocator);
            try entries.append(target_allocator, owned_entry);
        }
        defer self.deinit();
        return Baggage.init(target_allocator, try entries.toOwnedSlice(target_allocator));
    }
};

test "Baggage basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var baggage = Baggage.empty(allocator);
    defer baggage.deinit();

    try testing.expect(baggage.isEmpty());
    try testing.expectEqual(@as(usize, 0), baggage.entries.len);
    try testing.expect(baggage.getValue("any.key") == null);

    // Add a value
    const baggage2 = try Baggage.initBuildFn(allocator, {}, struct {
        fn add(_: void, builder: *BaggageBuilder) anyerror!void {
            try builder.put("user.id", "12345");
        }
    }.add);
    defer baggage2.deinit();

    try testing.expect(!baggage2.isEmpty());
    try testing.expectEqual(@as(usize, 1), baggage2.entries.len);
    try testing.expectEqualStrings("12345", baggage2.getValue("user.id").?);
}

test "BaggageBuilder operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder_instance = BaggageBuilder.init(allocator);
    errdefer builder_instance.deinit();

    try builder_instance.put("key1", "value1");
    try builder_instance.put("key2", "value2");
    try builder_instance.putWithMetadata("key3", "value3", "metadata");
    try builder_instance.putFunction({}, struct {
        pub fn add(_: void, builder: *BaggageBuilder) anyerror!void {
            try builder.putMany(&.{
                .{ "key4", "value4" },
                .{ "key5", "value5" },
            });
        }
    }.add);

    const baggage = try builder_instance.finish(allocator);
    defer baggage.deinit();

    try testing.expectEqual(@as(usize, 5), baggage.entries.len);
    try testing.expectEqualStrings("value1", baggage.getValue("key1").?);
    try testing.expectEqualStrings("value2", baggage.getValue("key2").?);
    try testing.expectEqualStrings("value3", baggage.getValue("key3").?);
    try testing.expectEqualStrings("value4", baggage.getValue("key4").?);
    try testing.expectEqualStrings("value5", baggage.getValue("key5").?);
}
