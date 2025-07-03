//! W3C compliant TraceState implementation
//!
//! TraceState carries tracing-system specific context in a list of key-value pairs.
//! TraceState allows different vendors to propagate additional information and
//! inter-operate with their legacy id formats.
//!
//! This implementation follows the W3C Trace Context specification:
//! https://www.w3.org/TR/trace-context/#tracestate-header
//!
//! ## Key Requirements
//! - Maximum 32 key-value pairs
//! - Keys follow specific ABNF grammar (simple-key or multi-tenant-key)
//! - Values are 0-256 printable ASCII characters (except comma and equals)
//! - All operations are immutable (return new TraceState instances)
//! - Proper W3C validation for interoperability

const std = @import("std");

/// W3C compliant TraceState implementation
pub const TraceState = struct {
    /// Internal storage of key-value pairs
    /// Note: Stored in order of insertion, with most recent first (left-most)
    entries: []const Entry,

    /// Key-value pair entry
    pub const Entry = struct {
        key: []const u8,
        value: []const u8,

        /// Create a new entry (keys and values are not owned)
        pub fn init(key: []const u8, value: []const u8) Entry {
            return Entry{
                .key = key,
                .value = value,
            };
        }

        /// Create a new entry with owned memory
        pub fn initOwned(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !Entry {
            const owned_key = try allocator.dupe(u8, key);
            const owned_value = try allocator.dupe(u8, value);
            return Entry{
                .key = owned_key,
                .value = owned_value,
            };
        }

        /// Free owned memory for this entry
        pub fn deinitOwned(self: Entry, allocator: std.mem.Allocator) void {
            allocator.free(self.key);
            allocator.free(self.value);
        }
    };

    // W3C specification constants
    pub const MAX_KEY_VALUE_PAIRS = 32;
    pub const MAX_KEY_LENGTH = 256;
    pub const MAX_VALUE_LENGTH = 256;

    /// Create an empty TraceState
    pub fn empty() TraceState {
        return TraceState{
            .entries = &[_]Entry{},
        };
    }

    /// Parse TraceState from W3C tracestate header string
    /// Returns error if parsing fails or validation fails
    pub fn fromString(input: []const u8, allocator: std.mem.Allocator) !TraceState {
        if (input.len == 0) {
            return empty();
        }

        var entries = std.ArrayList(Entry).init(allocator);
        defer entries.deinit();

        // Split by comma to get individual list members
        var iterator = std.mem.splitScalar(u8, input, ',');
        while (iterator.next()) |member| {
            // Trim whitespace (OWS in W3C spec)
            const trimmed = std.mem.trim(u8, member, " \t");

            // Skip empty members (allowed by W3C spec)
            if (trimmed.len == 0) continue;

            // Find the equals sign
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                // Validate key and value
                if (!validateKey(key) or !validateValue(value)) {
                    return error.InvalidTraceState;
                }

                // Check for maximum entries
                if (entries.items.len >= MAX_KEY_VALUE_PAIRS) {
                    return error.TooManyEntries;
                }

                // Create owned entry
                const entry = try Entry.initOwned(allocator, key, value);
                try entries.append(entry);
            } else {
                // Invalid format (no equals sign)
                return error.InvalidTraceState;
            }
        }

        // Convert to owned slice
        const owned_entries = try allocator.dupe(Entry, entries.items);
        return TraceState{
            .entries = owned_entries,
        };
    }

    /// Convert TraceState to W3C tracestate header string
    pub fn toString(self: TraceState, allocator: std.mem.Allocator) ![]const u8 {
        if (self.isEmpty()) {
            return try allocator.dupe(u8, "");
        }

        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        for (self.entries, 0..) |entry, i| {
            if (i > 0) {
                try result.append(',');
            }
            try result.appendSlice(entry.key);
            try result.append('=');
            try result.appendSlice(entry.value);
        }

        return try result.toOwnedSlice();
    }

    /// Get value for a given key (returns null if key not found)
    pub fn get(self: TraceState, key: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        return null;
    }

    /// Create new TraceState with key-value pair added/updated
    /// Modified keys are moved to the beginning (left) of the list per W3C spec
    /// Returns error if validation fails or max entries exceeded
    pub fn put(self: TraceState, key: []const u8, value: []const u8, allocator: std.mem.Allocator) !TraceState {
        // Validate input
        if (!validateKey(key) or !validateValue(value)) {
            return error.InvalidKeyOrValue;
        }

        var new_entries = std.ArrayList(Entry).init(allocator);
        defer new_entries.deinit();

        // Add the new/updated entry first (left-most position)
        const new_entry = try Entry.initOwned(allocator, key, value);
        try new_entries.append(new_entry);

        // Add existing entries, skipping any with the same key
        for (self.entries) |entry| {
            if (!std.mem.eql(u8, entry.key, key)) {
                const copied_entry = try Entry.initOwned(allocator, entry.key, entry.value);
                try new_entries.append(copied_entry);
            }
        }

        // Check maximum entries limit
        if (new_entries.items.len > MAX_KEY_VALUE_PAIRS) {
            // Clean up allocated entries
            for (new_entries.items) |entry| {
                entry.deinitOwned(allocator);
            }
            return error.TooManyEntries;
        }

        // Convert to owned slice
        const owned_entries = try allocator.dupe(Entry, new_entries.items);
        return TraceState{
            .entries = owned_entries,
        };
    }

    /// Create new TraceState with key removed
    pub fn remove(self: TraceState, key: []const u8, allocator: std.mem.Allocator) !TraceState {
        var new_entries = std.ArrayList(Entry).init(allocator);
        defer new_entries.deinit();

        // Copy all entries except the one with the matching key
        for (self.entries) |entry| {
            if (!std.mem.eql(u8, entry.key, key)) {
                const copied_entry = try Entry.initOwned(allocator, entry.key, entry.value);
                try new_entries.append(copied_entry);
            }
        }

        // Convert to owned slice
        const owned_entries = try allocator.dupe(Entry, new_entries.items);
        return TraceState{
            .entries = owned_entries,
        };
    }

    /// Check if TraceState is empty
    pub fn isEmpty(self: TraceState) bool {
        return self.entries.len == 0;
    }

    /// Get number of key-value pairs
    pub fn size(self: TraceState) usize {
        return self.entries.len;
    }

    /// Free all owned memory for this TraceState
    pub fn deinit(self: TraceState, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            entry.deinitOwned(allocator);
        }
        allocator.free(self.entries);
    }

    /// Validate key according to W3C specification
    /// Keys must follow ABNF grammar: simple-key or multi-tenant-key format
    /// simple-key = lcalpha 0*255( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )
    /// multi-tenant-key = tenant-id "@" system-id
    pub fn validateKey(key: []const u8) bool {
        if (key.len == 0 or key.len > MAX_KEY_LENGTH) {
            return false;
        }

        // Check for multi-tenant key (contains @)
        if (std.mem.indexOf(u8, key, "@")) |at_pos| {
            return validateMultiTenantKey(key, at_pos);
        } else {
            return validateSimpleKey(key);
        }
    }

    /// Validate simple key format
    fn validateSimpleKey(key: []const u8) bool {
        // simple-key = lcalpha 0*255( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )

        // First character must be lowercase letter
        if (key.len == 0 or !std.ascii.isLower(key[0]) or !std.ascii.isAlphabetic(key[0])) {
            return false;
        }

        // Subsequent characters: lowercase letters, digits, or allowed symbols
        for (key[1..]) |c| {
            if (!(std.ascii.isLower(c) and std.ascii.isAlphabetic(c)) and
                !std.ascii.isDigit(c) and
                c != '_' and c != '-' and c != '*' and c != '/')
            {
                return false;
            }
        }

        return true;
    }

    /// Validate multi-tenant key format
    fn validateMultiTenantKey(key: []const u8, at_pos: usize) bool {
        // multi-tenant-key = tenant-id "@" system-id
        // tenant-id = ( lcalpha / DIGIT ) 0*240( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )
        // system-id = lcalpha 0*13( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )

        if (at_pos == 0 or at_pos >= key.len - 1) {
            return false; // @ cannot be at start or end
        }

        const tenant_id = key[0..at_pos];
        const system_id = key[at_pos + 1 ..];

        // Validate tenant-id (up to 241 chars, starts with lowercase letter or digit)
        if (tenant_id.len == 0 or tenant_id.len > 241) {
            return false;
        }

        if (!std.ascii.isLower(tenant_id[0]) and !std.ascii.isDigit(tenant_id[0])) {
            return false;
        }

        for (tenant_id[1..]) |c| {
            if (!(std.ascii.isLower(c) and std.ascii.isAlphabetic(c)) and
                !std.ascii.isDigit(c) and
                c != '_' and c != '-' and c != '*' and c != '/')
            {
                return false;
            }
        }

        // Validate system-id (up to 14 chars, starts with lowercase letter)
        if (system_id.len == 0 or system_id.len > 14) {
            return false;
        }

        if (!std.ascii.isLower(system_id[0]) or !std.ascii.isAlphabetic(system_id[0])) {
            return false;
        }

        for (system_id[1..]) |c| {
            if (!(std.ascii.isLower(c) and std.ascii.isAlphabetic(c)) and
                !std.ascii.isDigit(c) and
                c != '_' and c != '-' and c != '*' and c != '/')
            {
                return false;
            }
        }

        return true;
    }

    /// Validate value according to W3C specification
    /// Values: 0-256 printable ASCII chars (0x20-0x7E) except comma (0x2C) and equals (0x3D)
    pub fn validateValue(value: []const u8) bool {
        if (value.len > MAX_VALUE_LENGTH) {
            return false;
        }

        for (value) |c| {
            // Check printable ASCII range, excluding comma and equals
            if (c < 0x20 or c > 0x7E or c == ',' or c == '=') {
                return false;
            }
        }

        return true;
    }
};

// Tests
test "TraceState empty" {
    const empty_state = TraceState.empty();
    try std.testing.expect(empty_state.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), empty_state.size());
    try std.testing.expectEqual(@as(?[]const u8, null), empty_state.get("any_key"));
}

test "TraceState fromString basic parsing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test empty string
    const empty_state = try TraceState.fromString("", allocator);
    defer empty_state.deinit(allocator);
    try std.testing.expect(empty_state.isEmpty());

    // Test single entry
    const single_state = try TraceState.fromString("vendor1=value1", allocator);
    defer single_state.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), single_state.size());
    try std.testing.expectEqualStrings("value1", single_state.get("vendor1").?);

    // Test multiple entries
    const multi_state = try TraceState.fromString("vendor1=value1,vendor2=value2", allocator);
    defer multi_state.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), multi_state.size());
    try std.testing.expectEqualStrings("value1", multi_state.get("vendor1").?);
    try std.testing.expectEqualStrings("value2", multi_state.get("vendor2").?);
}

test "TraceState toString serialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test empty state
    const empty_state = TraceState.empty();
    const empty_string = try empty_state.toString(allocator);
    defer allocator.free(empty_string);
    try std.testing.expectEqualStrings("", empty_string);

    // Test state with entries
    const state = try TraceState.fromString("vendor1=value1,vendor2=value2", allocator);
    defer state.deinit(allocator);
    const state_string = try state.toString(allocator);
    defer allocator.free(state_string);
    try std.testing.expectEqualStrings("vendor1=value1,vendor2=value2", state_string);
}

test "TraceState put operation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start with empty state
    const empty_state = TraceState.empty();

    // Add first entry
    const state1 = try empty_state.put("vendor1", "value1", allocator);
    defer state1.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), state1.size());
    try std.testing.expectEqualStrings("value1", state1.get("vendor1").?);

    // Add second entry (should be at the beginning)
    const state2 = try state1.put("vendor2", "value2", allocator);
    defer state2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), state2.size());
    try std.testing.expectEqualStrings("value2", state2.get("vendor2").?);
    try std.testing.expectEqualStrings("value1", state2.get("vendor1").?);

    // Update existing entry (should move to beginning)
    const state3 = try state2.put("vendor1", "new_value1", allocator);
    defer state3.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), state3.size());
    try std.testing.expectEqualStrings("new_value1", state3.get("vendor1").?);
}

test "TraceState remove operation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create state with multiple entries
    const state = try TraceState.fromString("vendor1=value1,vendor2=value2,vendor3=value3", allocator);
    defer state.deinit(allocator);

    // Remove middle entry
    const state2 = try state.remove("vendor2", allocator);
    defer state2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), state2.size());
    try std.testing.expectEqual(@as(?[]const u8, null), state2.get("vendor2"));
    try std.testing.expectEqualStrings("value1", state2.get("vendor1").?);
    try std.testing.expectEqualStrings("value3", state2.get("vendor3").?);

    // Remove non-existent entry (should be no-op)
    const state3 = try state2.remove("nonexistent", allocator);
    defer state3.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), state3.size());
}

test "TraceState key validation" {
    // Valid simple keys
    try std.testing.expect(TraceState.validateKey("vendor"));
    try std.testing.expect(TraceState.validateKey("a"));
    try std.testing.expect(TraceState.validateKey("vendor123"));
    try std.testing.expect(TraceState.validateKey("vendor_name"));
    try std.testing.expect(TraceState.validateKey("vendor-name"));
    try std.testing.expect(TraceState.validateKey("vendor*name"));
    try std.testing.expect(TraceState.validateKey("vendor/name"));

    // Valid multi-tenant keys
    try std.testing.expect(TraceState.validateKey("tenant@system"));
    try std.testing.expect(TraceState.validateKey("123@vendor"));
    try std.testing.expect(TraceState.validateKey("tenant123@system_name"));

    // Invalid keys
    try std.testing.expect(!TraceState.validateKey("")); // empty
    try std.testing.expect(!TraceState.validateKey("Vendor")); // uppercase
    try std.testing.expect(!TraceState.validateKey("123vendor")); // simple key can't start with digit
    try std.testing.expect(!TraceState.validateKey("vendor@")); // multi-tenant missing system
    try std.testing.expect(!TraceState.validateKey("@system")); // multi-tenant missing tenant
    try std.testing.expect(!TraceState.validateKey("vendor@@system")); // double @
    try std.testing.expect(!TraceState.validateKey("vendor name")); // space not allowed
}

test "TraceState value validation" {
    // Valid values
    try std.testing.expect(TraceState.validateValue(""));
    try std.testing.expect(TraceState.validateValue("simple_value"));
    try std.testing.expect(TraceState.validateValue("Value123"));
    try std.testing.expect(TraceState.validateValue("!@#$%^&*()_+-[]{}|;':\"<>?./~`"));

    // Invalid values
    try std.testing.expect(!TraceState.validateValue("value,with,comma"));
    try std.testing.expect(!TraceState.validateValue("value=with=equals"));
    try std.testing.expect(!TraceState.validateValue("value\nwith\nnewline"));
    try std.testing.expect(!TraceState.validateValue("value\twith\ttab"));

    // Test length limit
    const long_value = "a" ** 257;
    try std.testing.expect(!TraceState.validateValue(long_value));
    const max_value = "a" ** 256;
    try std.testing.expect(TraceState.validateValue(max_value));
}

test "TraceState parsing edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with whitespace
    const state_ws = try TraceState.fromString(" vendor1 = value1 , vendor2 = value2 ", allocator);
    defer state_ws.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), state_ws.size());
    try std.testing.expectEqualStrings("value1", state_ws.get("vendor1").?);

    // Test with empty members (should be skipped)
    const state_empty = try TraceState.fromString("vendor1=value1,,vendor2=value2", allocator);
    defer state_empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), state_empty.size());

    // Test invalid format (should fail)
    try std.testing.expectError(error.InvalidTraceState, TraceState.fromString("invalid_format", allocator));
}
