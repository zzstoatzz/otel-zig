//! OpenTelemetry View System for Metrics SDK
//!
//! This module provides the view configuration system that allows transforming
//! how metrics are collected and exported. Views can filter attributes, rename
//! instruments, override aggregation types, and create multiple streams from
//! a single instrument.

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const metrics = struct {
        const AggregationType = @import("aggregations.zig").AggregationType;
        const InstrumentType = @import("metadata.zig").InstrumentType;
    };
};

// Label for the main struct.
const View = @This();

/// View configuration that transforms how metrics are collected
// Instrument selector (all criteria are additive/AND-ed)
instrument_selector: View.Selector,

// Stream configuration (per OTel spec)
name: ?[]const u8 = null, // Override instrument name
description: ?[]const u8 = null, // Override instrument description
attribute_allowed_keys: ?[]const []const u8 = null, // Allow list: null = keep all, empty = drop all
aggregation_override: ?sdk.metrics.AggregationType = null, // Override instrument's default aggregation

/// Default view that matches any instrument and applies no transformations
pub const default: View = .{
    .instrument_selector = .{}, // Matches everything, changes nothing.
};

/// Types of aggregations available for view override
/// Instrument selector for matching instruments to views
pub const Selector = struct {
    // All fields are optional (null means match any)
    name: ?[]const u8 = null, // "*" = all, supports basic wildcards
    type: ?sdk.metrics.InstrumentType = null, // Counter, Histogram, etc.
    unit: ?[]const u8 = null, // Exact match
    meter_name: ?[]const u8 = null, // Exact match
    meter_version: ?[]const u8 = null, // Exact match
    meter_schema_url: ?[]const u8 = null, // Exact match

    /// Check if this selector matches the given instrument metadata
    pub fn matches(
        self: *const Selector,
        instrument_name: []const u8,
        instrument_type: sdk.metrics.InstrumentType,
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

/// Application of a view to an instrument, handling attribute transformation
pub const Application = struct {
    view: View,

    /// Check if this application drops measurements
    pub fn drops(self: *const Application) bool {
        return self.view.aggregation_override == .drop;
    }

    /// Transform attributes according to view configuration
    pub fn transformAttributes(
        self: *const Application,
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
        var filtered = std.ArrayList(api.AttributeKeyValue).empty;
        defer filtered.deinit(allocator);

        for (input) |attr| {
            for (keep_keys) |allowed_key| {
                if (std.mem.eql(u8, attr.key, allowed_key)) {
                    try filtered.append(allocator, attr);
                    break;
                }
            }
        }

        return try filtered.toOwnedSlice(allocator);
    }

    /// Get the effective name for this view application
    pub fn getName(self: *const Application, original_name: []const u8) []const u8 {
        return self.view.name orelse original_name;
    }

    /// Get the effective description for this view application
    pub fn getDescription(self: *const Application, original_description: ?[]const u8) ?[]const u8 {
        return self.view.description orelse original_description;
    }

    /// Get the aggregation type for this view (original selector or override)
    pub fn getAggregationType(self: *const Application, instrument_type: sdk.InstrumentType) sdk.metrics.AggregationType {
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

    const selector = View.Selector{
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

    const selector = View.Selector{
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

    const app = View.Application{ .view = view };

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

    const app = View.Application{ .view = view };

    const input_attrs = [_]api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "GET" } },
        .{ .key = "status", .value = .{ .int = 200 } },
    };

    const filtered = try app.transformAttributes(&input_attrs, allocator);
    defer allocator.free(filtered);

    try testing.expectEqual(@as(usize, 0), filtered.len);
}
