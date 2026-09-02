const std = @import("std");

const api = struct {
    const ErrorInfo = @import("error_handler.zig").ErrorInfo;
    const isValidatingMode = @import("error_handler.zig").isValidatingMode;
    const reportError = @import("error_handler.zig").reportError;
};

/// The Builder is a base type for the various key/value pairs that OpenTelemetry
/// defines. Mutation methods, like `add` and `addMany` invalidate the previous state
/// and return the new state. The `build` method provides a way to snapshot the
/// current collection of the builder. The `finish` method provides a way to snapshot
/// and discard the builder in a single call.
///
/// A typical usage would look like:
/// ```zig
/// var collection = Builder(KeyValueType).init(arena_allocator)
///     .add(.{ .key = "key", .value = "value" })
///     .finish(allocator) catch try allocator.alloc(KeyValueType, 0); // finish automatically calls deinit()
/// defer KeyValueType.deinitOwnedSlice(allocator);
/// ```
///
/// Mutation methods, do not fail or return errors.  Calls to `add` after the
/// Builder is invalid silently discard. In a validation mode, the builder will
/// become invalide when adding an invalid entry. This check is skipped in
/// non-validating modes (release fast).
///
/// `build` and `finish` will return any errors encountered when mutating the
/// Builder. They also dedupe the resulting collection, retaining the original
/// insert order.
pub fn Builder(comptime Entry: type) type {
    const canValidate = @hasDecl(Entry, "validationErrorInfo");
    if (!@hasDecl(Entry, "initOwnedSlice"))
        @compileError("Builder template requires " ++ @typeName(Entry) ++ " to have initOwnedSlice function.");
    if (!@hasField(Entry, "key"))
        @compileError("Builder template requires " ++ @typeName(Entry) ++ " to have key field.");

    const KeyType = @FieldType(Entry, "key");

    return union(enum) {
        const Self = @This();
        const Valid = struct {
            const AddOrder = enum {
                /// Preserve the order inserted, last set wins.
                preserve,
                /// Move the added key to the beginning, last set still wins.
                prepend,
            };
            allocator: std.mem.Allocator,
            entries: []Entry,

            pub fn addEntry(bldr: Valid, item: Entry, order: AddOrder) !Valid {
                var entries = std.ArrayList(Entry).empty;
                defer entries.deinit(bldr.allocator);

                if (order == .prepend) try entries.append(bldr.allocator, item); // prepend the value to the head to change the order.
                try entries.appendSlice(bldr.allocator, bldr.entries);
                try entries.append(bldr.allocator, item); // set the value at the end since last set wins.

                // The dedupe call will clean up the double insert.

                return .{
                    .allocator = bldr.allocator,
                    .entries = try entries.toOwnedSlice(bldr.allocator),
                };
            }

            pub fn addEntries(bldr: Valid, items: []const Entry) !Valid {
                var entries = std.ArrayList(Entry).empty;
                defer entries.deinit(bldr.allocator);

                try entries.appendSlice(bldr.allocator, bldr.entries);
                try entries.appendSlice(bldr.allocator, items);
                return .{
                    .allocator = bldr.allocator,
                    .entries = try entries.toOwnedSlice(bldr.allocator),
                };
            }

            pub fn dedupe(bldr: Valid) ![]Entry {
                // basically a clean, without a key to remove.
                return dedupeRemove(bldr, null);
            }

            pub fn dedupeRemove(bldr: Valid, remove_key: ?KeyType) ![]Entry {
                // de-dupe the entries.
                var index = comptime switch (KeyType) {
                    []u8, []const u8 => std.StringArrayHashMapUnmanaged(Entry).empty,
                    else => std.AutoArrayHashMapUnmanaged(KeyType, Entry).empty,
                };
                defer index.deinit(bldr.allocator);
                for (bldr.entries) |item| try index.put(bldr.allocator, item.key, item);
                if (remove_key) |unwanted| _ = index.orderedRemove(unwanted); // depending on the map to deal with types for us.

                // Collect the remaining.
                var entries = std.ArrayList(Entry).empty;
                defer entries.deinit(bldr.allocator);
                var iter = index.iterator();
                while (iter.next()) |entry| try entries.append(bldr.allocator, entry.value_ptr.*);

                // Give back the new slice.
                return try entries.toOwnedSlice(bldr.allocator);
            }
        };
        valid: Valid,
        invalid: api.ErrorInfo,

        /// Create a new builder using the provided allocator
        pub fn init(allocator: std.mem.Allocator) Self {
            const entries = allocator.alloc(Entry, 0) catch |e| return .{ .invalid = .{
                .component = .general,
                .operation = "Builder(" ++ @typeName(Entry) ++ ").init",
                .error_type = .resource_exhausted,
                .message = "Failed to allocate memory",
                .source_error = e,
            } };
            return .{ .valid = .{
                .allocator = allocator,
                .entries = entries,
            } };
        }

        pub fn initFrom(allocator: std.mem.Allocator, source: Self) Self {
            return switch (source) {
                .valid => |bldr| blk: {
                    const entries = allocator.dupe(Entry, bldr.entries) catch |e| break :blk .{ .invalid = .{
                        .component = .general,
                        .operation = "Builder(" ++ @typeName(Entry) ++ ").initFrom",
                        .error_type = .resource_exhausted,
                        .message = "Failed to allocate memory",
                        .source_error = e,
                    } };
                    break :blk .{ .valid = .{
                        .allocator = allocator,
                        .entries = entries,
                    } };
                },
                .invalid => source,
            };
        }

        /// Clean up the builder.
        pub fn deinit(self: Self) void {
            switch (self) {
                .valid => |bldr| bldr.allocator.free(bldr.entries),
                .invalid => {},
            }
        }

        /// Add a single entry to the builder.
        pub fn add(self: Self, item: Entry) Self {
            defer self.deinit();
            return switch (self) {
                .valid => |bldr| blk: {
                    // Validation
                    if (canValidate) {
                        if (Entry.validationErrorInfo(item)) |errInfo| break :blk .{ .invalid = errInfo };
                    }

                    const valid = bldr.addEntry(item, .preserve) catch |e| break :blk .{ .invalid = .{
                        .component = .general,
                        .operation = "Builder(" ++ @typeName(Entry) ++ ").add",
                        .error_type = .resource_exhausted,
                        .message = "Failed to allocate memory",
                        .source_error = e,
                    } };
                    break :blk .{ .valid = valid };
                },
                .invalid => self,
            };
        }

        pub fn addFirst(self: Self, item: Entry) Self {
            defer self.deinit();
            return switch (self) {
                .valid => |bldr| blk: {
                    // Validation
                    if (canValidate) {
                        if (Entry.validationErrorInfo(item)) |errInfo| break :blk .{ .invalid = errInfo };
                    }

                    const valid = bldr.addEntry(item, .prepend) catch |e| break :blk .{ .invalid = .{
                        .component = .general,
                        .operation = "Builder(" ++ @typeName(Entry) ++ ").addFirst",
                        .error_type = .resource_exhausted,
                        .message = "Failed to allocate memory",
                        .source_error = e,
                    } };
                    break :blk .{ .valid = valid };
                },
                .invalid => self,
            };
        }

        /// Add multiple entries to the builder.
        pub fn addMany(self: Self, items: []const Entry) Self {
            defer self.deinit();
            return switch (self) {
                .valid => |bldr| blk: {
                    // Validation
                    if (canValidate) {
                        for (items) |item| {
                            if (Entry.validationErrorInfo(item)) |errInfo| break :blk .{ .invalid = errInfo };
                        }
                    }

                    const valid = bldr.addEntries(items) catch |e| break :blk .{ .invalid = .{
                        .component = .general,
                        .operation = "Builder(" ++ @typeName(Entry) ++ ").addMany",
                        .error_type = .resource_exhausted,
                        .message = "Failed to allocate memory",
                        .source_error = e,
                    } };
                    break :blk .{ .valid = valid };
                },
                .invalid => self,
            };
        }

        /// Merge two builders together.
        pub fn merge(self: Self, other: Self) Self {
            defer self.deinit();
            return switch (self) {
                .valid => |bldr| switch (other) {
                    .valid => |other_bldr| blk: {
                        // skip validation since the other source is a buider.
                        const valid = bldr.addEntries(other_bldr.entries) catch |e| break :blk .{ .invalid = .{
                            .component = .general,
                            .operation = "Builder(" ++ @typeName(Entry) ++ ").addMany",
                            .error_type = .resource_exhausted,
                            .message = "Failed to allocate memory",
                            .source_error = e,
                        } };
                        break :blk .{ .valid = valid };
                    },
                    .invalid => .{ .invalid = api.ErrorInfo{
                        .component = .general,
                        .operation = "Builder(" ++ @typeName(Entry) ++ ").merge",
                        .error_type = .validation,
                        .message = "Attempt to merge an invalid builder",
                    } },
                },
                .invalid => self,
            };
        }

        /// Remove a provided key (also removes duplicates)
        pub fn remove(self: Self, key: KeyType) Self {
            defer self.deinit();
            return switch (self) {
                .valid => |bldr| blk: {
                    const valid = bldr.dedupeRemove(key) catch |e| break :blk .{ .invalid = .{
                        .component = .general,
                        .operation = "Builder(" ++ @typeName(Entry) ++ ").remove",
                        .error_type = .resource_exhausted,
                        .message = "Failed to allocate memory",
                        .source_error = e,
                    } };
                    break :blk .{
                        .valid = .{
                            .allocator = bldr.allocator,
                            .entries = valid,
                        },
                    };
                },
                .invalid => self,
            };
        }

        /// Snapshot entries, retain the builder.
        pub fn build(self: Self) ![]Entry {
            return switch (self) {
                .valid => |bldr| try bldr.dedupe(),
                .invalid => |errInfo| blk: {
                    if (api.isValidatingMode()) api.reportError(errInfo);
                    break :blk errInfo.source_error orelse error.InvalidBuilder;
                },
            };
        }

        /// Deep copy entries, dispose of builder.
        pub fn finish(self: Self, allocator: std.mem.Allocator) ![]Entry {
            defer self.deinit();
            return switch (self) {
                .valid => |bldr| blk: {
                    const deduped = try bldr.dedupe();
                    defer bldr.allocator.free(deduped);
                    break :blk try Entry.initOwnedSlice(allocator, deduped);
                },
                .invalid => |errInfo| blk: {
                    if (api.isValidatingMode()) api.reportError(errInfo);
                    break :blk errInfo.source_error orelse error.InvalidBuilder;
                },
            };
        }
    };
}
