//! OpenTelemetry View System for Metrics SDK
//!
//! This module provides the view configuration system that allows transforming
//! how metrics are collected and exported. Views can filter attributes, rename
//! instruments, override aggregation types, and create multiple streams from
//! a single instrument.

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const InstrumentType = @import("metadata.zig").InstrumentType;
};

/// Types of aggregations available for view override
pub const AggregationType = enum {
    sum,
    last_value,
    histogram,
    drop, // Special case: don't aggregate at all
};

/// Instrument selector for matching instruments to views
pub const InstrumentSelector = struct {
    // All fields are optional (null means match any)
    name: ?[]const u8 = null, // "*" = all, supports basic wildcards
    type: ?sdk.InstrumentType = null, // Counter, Histogram, etc.
    unit: ?[]const u8 = null, // Exact match
    meter_name: ?[]const u8 = null, // Exact match
    meter_version: ?[]const u8 = null, // Exact match
    meter_schema_url: ?[]const u8 = null, // Exact match

    /// Check if this selector matches the given instrument metadata
    pub fn matches(
        self: *const @This(),
        instrument_name: []const u8,
        instrument_type: sdk.InstrumentType,
        instrument_unit: []const u8,
        meter_name: []const u8,
        meter_version: ?[]const u8,
        meter_schema_url: ?[]const u8,
    ) bool {
        // Check name (minimal wildcard support per spec requirement)
        if (self.name) |pattern| {
            // Support exact match and "*" for all
            if (!std.mem.eql(u8, pattern, "*") and
                !std.mem.eql(u8, pattern, instrument_name))
            {
                return false;
            }
        }

        // Check type
        if (self.type) |t| {
            if (t != instrument_type) return false;
        }

        // Check unit
        if (self.unit) |u| {
            if (!std.mem.eql(u8, u, instrument_unit)) return false;
        }

        // Check meter properties
        if (self.meter_name) |mn| {
            if (!std.mem.eql(u8, mn, meter_name)) return false;
        }

        if (self.meter_version) |mv| {
            const actual_version = meter_version orelse "";
            if (!std.mem.eql(u8, mv, actual_version)) return false;
        }

        if (self.meter_schema_url) |msu| {
            const actual_schema_url = meter_schema_url orelse "";
            if (!std.mem.eql(u8, msu, actual_schema_url)) return false;
        }

        // All specified criteria matched
        return true;
    }
};

/// View configuration that transforms how metrics are collected
pub const View = struct {
    // Instrument selector (all criteria are additive/AND-ed)
    instrument_selector: InstrumentSelector,

    // Stream configuration (per OTel spec)
    name: ?[]const u8 = null, // Override instrument name
    description: ?[]const u8 = null, // Override instrument description
    attribute_allowed_keys: ?[]const []const u8 = null, // Allow list: null = keep all, empty = drop all
    aggregation_override: ?AggregationType = null, // Override instrument's default aggregation

    // Note: Unit is NOT transformable per spec

    /// Default view that matches any instrument and applies no transformations
    pub const default: View = .{
        .instrument_selector = .{}, // Matches everything
    };

    /// Check if this is a drop aggregation view
    pub fn drops(self: *const @This()) bool {
        return self.aggregation_override == .drop;
    }

    /// Get the effective name for this view (original or override)
    pub fn getName(self: *const @This(), original_name: []const u8) []const u8 {
        return self.name orelse original_name;
    }

    /// Get the effective description for this view (original or override)
    pub fn getDescription(self: *const @This(), original_description: ?[]const u8) ?[]const u8 {
        return self.description orelse original_description;
    }
};

/// Application of a view to an instrument, handling attribute transformation
pub const ViewApplication = struct {
    view: View,

    /// Check if this application drops measurements
    pub fn drops(self: *const @This()) bool {
        return self.view.drops();
    }

    /// Transform attributes according to view configuration
    pub fn transformAttributes(
        self: *const @This(),
        input: []const api.AttributeKeyValue,
        allocator: std.mem.Allocator,
    ) ![]api.AttributeKeyValue {
        // If no attribute filtering specified, return copy of input
        if (self.view.attribute_allowed_keys == null) {
            const result = try allocator.alloc(api.AttributeKeyValue, input.len);
            @memcpy(result, input);
            return result;
        }

        const keep_keys = self.view.attribute_allowed_keys.?;

        // Empty allow list means drop all attributes
        if (keep_keys.len == 0) {
            return try allocator.alloc(api.AttributeKeyValue, 0);
        }

        // Filter to only specified keys
        var filtered = std.ArrayList(api.AttributeKeyValue).init(allocator);
        defer filtered.deinit();

        for (input) |attr| {
            for (keep_keys) |allowed_key| {
                if (std.mem.eql(u8, attr.key, allowed_key)) {
                    try filtered.append(attr);
                    break;
                }
            }
        }

        return try filtered.toOwnedSlice();
    }

    /// Get the effective name for this view application
    pub fn getName(self: *const @This(), original_name: []const u8) []const u8 {
        return self.view.getName(original_name);
    }

    /// Get the effective description for this view application
    pub fn getDescription(self: *const @This(), original_description: ?[]const u8) ?[]const u8 {
        return self.view.getDescription(original_description);
    }

    /// Get the aggregation type for this view (original selector or override)
    pub fn getAggregationType(self: *const @This(), instrument_type: sdk.InstrumentType) AggregationType {
        if (self.view.aggregation_override) |override_type| {
            return override_type;
        }

        // Use default aggregation based on instrument type
        return switch (instrument_type) {
            .Counter, .UpDownCounter, .ObservableCounter, .ObservableUpDownCounter => .sum,
            .Gauge, .ObservableGauge => .last_value,
            .Histogram => .histogram,
        };
    }
};

// Tests
test "InstrumentSelector - basic matching" {
    const testing = std.testing;

    const selector = InstrumentSelector{
        .name = "http.requests",
        .type = .Counter,
    };

    // Should match
    try testing.expect(selector.matches(
        "http.requests",
        .Counter,
        "requests",
        "test.meter",
        "1.0.0",
        null,
    ));

    // Should not match different name
    try testing.expect(!selector.matches(
        "http.duration",
        .Counter,
        "requests",
        "test.meter",
        "1.0.0",
        null,
    ));

    // Should not match different type
    try testing.expect(!selector.matches(
        "http.requests",
        .Histogram,
        "requests",
        "test.meter",
        "1.0.0",
        null,
    ));
}

test "InstrumentSelector - wildcard matching" {
    const testing = std.testing;

    const selector = InstrumentSelector{
        .name = "*",
    };

    // Should match any name
    try testing.expect(selector.matches(
        "http.requests",
        .Counter,
        "requests",
        "test.meter",
        "1.0.0",
        null,
    ));

    try testing.expect(selector.matches(
        "database.queries",
        .Histogram,
        "queries",
        "db.meter",
        "2.0.0",
        "https://example.com/schema",
    ));
}

test "ViewApplication - attribute filtering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const view = View{
        .instrument_selector = .{ .name = "test.metric" },
        .attribute_allowed_keys = &[_][]const u8{ "method", "status" },
    };

    const app = ViewApplication{ .view = view };

    const input_attrs = [_]api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "GET" } },
        .{ .key = "status", .value = .{ .int = 200 } },
        .{ .key = "user_id", .value = .{ .string = "12345" } }, // Should be filtered out
    };

    const filtered = try app.transformAttributes(&input_attrs, allocator);
    defer allocator.free(filtered);

    try testing.expectEqual(@as(usize, 2), filtered.len);
    try testing.expectEqualStrings("method", filtered[0].key);
    try testing.expectEqualStrings("status", filtered[1].key);
}

test "ViewApplication - drop all attributes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const view = View{
        .instrument_selector = .{ .name = "test.metric" },
        .attribute_allowed_keys = &[_][]const u8{}, // Empty = drop all
    };

    const app = ViewApplication{ .view = view };

    const input_attrs = [_]api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "GET" } },
        .{ .key = "status", .value = .{ .int = 200 } },
    };

    const filtered = try app.transformAttributes(&input_attrs, allocator);
    defer allocator.free(filtered);

    try testing.expectEqual(@as(usize, 0), filtered.len);
}

test "View - name and description override" {
    const testing = std.testing;

    const view = View{
        .instrument_selector = .{ .name = "http_requests" },
        .name = "http.requests.total",
        .description = "Total HTTP requests",
    };

    try testing.expectEqualStrings("http.requests.total", view.getName("http_requests"));
    try testing.expectEqualStrings("Total HTTP requests", view.getDescription("Old description").?);
}

test "View - drop aggregation" {
    const testing = std.testing;

    const drop_view = View{
        .instrument_selector = .{ .name = "debug.metric" },
        .aggregation_override = .drop,
    };

    const normal_view = View{
        .instrument_selector = .{ .name = "prod.metric" },
    };

    try testing.expect(drop_view.drops());
    try testing.expect(!normal_view.drops());
}
