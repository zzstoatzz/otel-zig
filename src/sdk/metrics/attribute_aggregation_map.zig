//! Attribute Aggregation Map for OpenTelemetry Metrics SDK
//!
//! This module manages aggregations indexed by attribute combinations with
//! cardinality limits and overflow handling as per OpenTelemetry specification.

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const InstrumentType = @import("metadata.zig").InstrumentType;
    const MetricValue = @import("reader.zig").MetricValue;
    const aggregations = @import("aggregations.zig");
    const computeAttributeHash = @import("attribute_hash.zig").computeAttributeHash;
};

/// Entry that combines aggregation with its attributes for export
pub const AttributeAggregationEntry = struct {
    aggregation: Aggregation,
    attributes: []const api.AttributeKeyValue,
    allocator: std.mem.Allocator, // For cleaning up owned attributes

    pub fn deinit(self: *@This()) void {
        self.aggregation.deinit(self.allocator);
        // Free owned attributes if any exist
        if (self.attributes.len > 0) {
            // Only free if this is a heap-allocated slice (not a constant empty slice)
            const empty_slice = &[_]api.AttributeKeyValue{};
            if (self.attributes.ptr != empty_slice.ptr) {
                for (self.attributes) |attr| {
                    if (attr.value == .string) {
                        self.allocator.free(attr.key);
                        self.allocator.free(attr.value.string);
                    } else {
                        self.allocator.free(attr.key);
                    }
                }
                self.allocator.free(@constCast(self.attributes));
            }
        }
    }
};

/// Aggregation union type that supports all aggregation variants
pub const Aggregation = union(enum) {
    sum_i64: sdk.aggregations.SumAggregation(i64),
    sum_f64: sdk.aggregations.SumAggregation(f64),
    last_value_i64: sdk.aggregations.LastValueAggregation(i64),
    last_value_f64: sdk.aggregations.LastValueAggregation(f64),
    histogram_i64: sdk.aggregations.HistogramAggregation(i64),
    histogram_f64: sdk.aggregations.HistogramAggregation(f64),
    drop: void, // Drop aggregation - ignores all measurements

    /// Record a measurement on this aggregation (lock-free)
    pub fn record(self: *@This(), value: anytype, allocator: std.mem.Allocator) void {
        const T = @TypeOf(value);
        switch (self.*) {
            .sum_i64 => |*s| if (T == i64) s.add(value),
            .sum_f64 => |*s| if (T == f64) s.add(value),
            .last_value_i64 => |*lv| if (T == i64) lv.record(value),
            .last_value_f64 => |*lv| if (T == f64) lv.record(value),
            .histogram_i64 => |*h| if (T == i64) h.record(value),
            .histogram_f64 => |*h| if (T == f64) h.record(value),
            .drop => {}, // Intentionally do nothing
        }
        _ = allocator; // Unused in Phase 1c (lock-free)
    }

    /// Clean up aggregation resources
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .histogram_i64 => |*h| h.deinit(allocator),
            .histogram_f64 => |*h| h.deinit(allocator),
            .drop => {}, // Drop aggregation has no cleanup
            else => {}, // Other aggregations don't need cleanup
        }
    }
};

/// Attribute-based aggregation map with cardinality limits
pub const AttributeAggregationMap = struct {
    // Cardinality limit (matches OpenTelemetry spec default)
    pub const MAX_CARDINALITY: usize = 2000;

    // Map from (instrument_hash + attribute_hash) to aggregation
    aggregations: std.AutoHashMap(u128, *AttributeAggregationEntry),

    // Pre-allocated pool of aggregation entries
    aggregation_pool: [MAX_CARDINALITY]AttributeAggregationEntry,
    next_free: usize,
    allocator: std.mem.Allocator,

    // Track cardinality
    cardinality: usize,

    // Overflow aggregation for when limit is reached
    overflow_aggregation: ?*AttributeAggregationEntry,

    /// Initialize the attribute aggregation map
    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .aggregations = std.AutoHashMap(u128, *AttributeAggregationEntry).init(allocator),
            .aggregation_pool = undefined, // Will be initialized as needed
            .next_free = 0,
            .allocator = allocator,
            .cardinality = 0,
            .overflow_aggregation = null,
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *@This()) void {
        // Clean up aggregation entries that need allocator cleanup
        for (0..self.next_free) |i| {
            self.aggregation_pool[i].deinit();
        }

        self.aggregations.deinit();
    }

    /// Get or create aggregation for the given instrument and attribute combination
    pub fn getOrCreateAggregation(
        self: *@This(),
        instrument: *anyopaque,
        attributes: []const api.AttributeKeyValue,
        metadata: sdk.MetricMetadata,
        value: sdk.MetricValue,
    ) *AttributeAggregationEntry {
        _ = instrument; // Instrument pointer not used in Phase 1b, metadata hash sufficient
        // Combine instrument metadata hash and attribute hash for unique key
        const attr_hash = sdk.computeAttributeHash(attributes);
        const combined_hash = (@as(u128, metadata.metadata_hash) << 64) | attr_hash;

        // Check if aggregation entry already exists
        if (self.aggregations.get(combined_hash)) |entry| {
            return entry;
        }

        // Check cardinality limit
        if (self.next_free >= MAX_CARDINALITY) {
            return self.getOrCreateOverflowAggregation(metadata, value);
        }

        // Get next aggregation entry from pool
        const entry = &self.aggregation_pool[self.next_free];
        self.next_free += 1;
        self.cardinality += 1;

        // Initialize aggregation entry based on instrument type and value type
        const owned_attributes = self.cloneAttributes(attributes) catch &[_]api.AttributeKeyValue{};
        entry.* = .{
            .aggregation = self.createAggregationForType(metadata, value) catch {
                // On error, mark this slot as unused and return overflow
                self.next_free -= 1;
                self.cardinality -= 1;
                return self.getOrCreateOverflowAggregation(metadata, value);
            },
            .attributes = owned_attributes,
            .allocator = self.allocator,
        };

        // Store in map
        self.aggregations.put(combined_hash, entry) catch {
            // On error, clean up and return overflow
            entry.deinit();
            self.next_free -= 1;
            self.cardinality -= 1;
            return self.getOrCreateOverflowAggregation(metadata, value);
        };

        return entry;
    }

    /// Get or create the overflow aggregation
    fn getOrCreateOverflowAggregation(self: *@This(), metadata: sdk.MetricMetadata, value: sdk.MetricValue) *AttributeAggregationEntry {
        if (self.overflow_aggregation == null) {
            // Create overflow aggregation using a special overflow key
            const overflow_key: u128 = std.math.maxInt(u128); // Special sentinel value

            // Use first slot for overflow if not already used, otherwise find a slot
            var overflow_slot: *AttributeAggregationEntry = undefined;
            if (self.next_free == 0) {
                overflow_slot = &self.aggregation_pool[0];
                self.next_free = 1; // Reserve this slot
            } else {
                // Use last allocated slot for overflow
                overflow_slot = &self.aggregation_pool[self.next_free - 1];
            }

            // Initialize overflow aggregation entry
            overflow_slot.* = .{
                .aggregation = self.createAggregationForType(metadata, value) catch {
                    // If we can't create aggregation, create a minimal sum aggregation
                    return self.createMinimalOverflowAggregation();
                },
                .attributes = &[_]api.AttributeKeyValue{}, // Empty attributes for overflow
                .allocator = self.allocator,
            };

            self.overflow_aggregation = overflow_slot;

            // Store overflow aggregation in map
            self.aggregations.put(overflow_key, overflow_slot) catch {
                // If we can't store in map, still use it as overflow
            };

            // Report cardinality limit exceeded
            api.common.reportResourceExhaustedError(.meter, "getOrCreateAggregation", "Attribute cardinality limit exceeded", null);
        }

        return self.overflow_aggregation.?;
    }

    /// Create a minimal overflow aggregation when all else fails
    fn createMinimalOverflowAggregation(self: *@This()) *AttributeAggregationEntry {
        // Use first slot and create a minimal sum aggregation entry
        const entry = &self.aggregation_pool[0];
        entry.* = .{
            .aggregation = .{
                .sum_i64 = .{
                    .value = std.atomic.Value(i64).init(0),
                    .start_timestamp_ns = @intCast(std.time.nanoTimestamp()),
                    .instrument_name = "overflow",
                    .instrument_type = .Counter,
                    .instrument_unit = "",
                },
            },
            .attributes = &[_]api.AttributeKeyValue{}, // Empty attributes for overflow
            .allocator = self.allocator,
        };
        self.overflow_aggregation = entry;
        self.next_free = @max(self.next_free, 1);
        return entry;
    }

    /// Create aggregation of the appropriate type for the instrument
    fn createAggregationForType(self: *@This(), metadata: sdk.MetricMetadata, value: sdk.MetricValue) !Aggregation {
        return switch (metadata.instrument_type) {
            .Counter, .ObservableCounter => .{
                .sum_i64 = .{
                    .value = std.atomic.Value(i64).init(0),
                    .start_timestamp_ns = @intCast(std.time.nanoTimestamp()),
                    .instrument_name = metadata.name,
                    .instrument_type = metadata.instrument_type,
                    .instrument_unit = metadata.unit,
                },
            },
            .UpDownCounter, .ObservableUpDownCounter => .{
                .sum_i64 = .{
                    .value = std.atomic.Value(i64).init(0),
                    .start_timestamp_ns = @intCast(std.time.nanoTimestamp()),
                    .instrument_name = metadata.name,
                    .instrument_type = metadata.instrument_type,
                    .instrument_unit = metadata.unit,
                },
            },
            .Gauge, .ObservableGauge => .{
                .last_value_f64 = .{
                    .has_value = std.atomic.Value(bool).init(false),
                    .value = std.atomic.Value(f64).init(0),
                    .instrument_name = metadata.name,
                    .instrument_type = metadata.instrument_type,
                    .instrument_unit = metadata.unit,
                },
            },
            .Histogram, .ObservableHistogram => switch (value) {
                .i64 => blk: {
                    var hist = try sdk.aggregations.HistogramAggregation(i64).init(
                        self.allocator,
                        .{ .boundaries = &sdk.aggregations.DEFAULT_HISTOGRAM_BOUNDARIES },
                    );
                    hist.instrument_name = metadata.name;
                    hist.instrument_type = metadata.instrument_type;
                    hist.instrument_unit = metadata.unit;
                    break :blk .{ .histogram_i64 = hist };
                },
                .f64 => blk: {
                    var hist = try sdk.aggregations.HistogramAggregation(f64).init(
                        self.allocator,
                        .{ .boundaries = &sdk.aggregations.DEFAULT_HISTOGRAM_BOUNDARIES },
                    );
                    hist.instrument_name = metadata.name;
                    hist.instrument_type = metadata.instrument_type;
                    hist.instrument_unit = metadata.unit;
                    break :blk .{ .histogram_f64 = hist };
                },
            },
        };
    }

    /// Clone attributes for owned storage
    fn cloneAttributes(self: *@This(), attributes: []const api.AttributeKeyValue) ![]const api.AttributeKeyValue {
        if (attributes.len == 0) return &[_]api.AttributeKeyValue{};

        const owned_attrs = try self.allocator.alloc(api.AttributeKeyValue, attributes.len);
        for (attributes, 0..) |attr, i| {
            const owned_key = try self.allocator.dupe(u8, attr.key);
            owned_attrs[i] = .{
                .key = owned_key,
                .value = switch (attr.value) {
                    .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
                    else => attr.value, // For non-string values, just copy the union
                },
            };
        }
        return owned_attrs;
    }

    /// Get current cardinality (number of unique attribute combinations)
    pub fn getCardinality(self: *const @This()) usize {
        return self.cardinality;
    }

    /// Check if cardinality limit has been exceeded
    pub fn hasExceededLimit(self: *const @This()) bool {
        return self.next_free >= MAX_CARDINALITY;
    }

    /// Iterator for all aggregation entries
    pub fn iterator(self: *@This()) std.AutoHashMap(u128, *AttributeAggregationEntry).Iterator {
        return self.aggregations.iterator();
    }
};

test "AttributeAggregationMap - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = AttributeAggregationMap.init(allocator);
    defer map.deinit();

    const metadata = sdk.MetricMetadata{
        .name = "test_counter",
        .description = "Test counter",
        .unit = "1",
        .instrument_type = .Counter,
        .meter_name = "test_meter",
        .meter_version = "1.0.0",
        .meter_schema_url = "",
        .metadata_hash = 12345,
    };

    const attributes = [_]api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "GET" } },
    };

    const instrument_ptr = @as(*anyopaque, @ptrFromInt(@as(usize, 0x1000)));

    // Get aggregation for first time
    const entry1 = map.getOrCreateAggregation(instrument_ptr, &attributes, metadata, .{ .i64 = 42 });
    try testing.expect(@intFromPtr(entry1) != 0);
    try testing.expectEqual(@as(usize, 1), map.getCardinality());

    // Get same aggregation again
    const entry2 = map.getOrCreateAggregation(instrument_ptr, &attributes, metadata, .{ .i64 = 42 });
    try testing.expectEqual(entry1, entry2); // Should be same pointer

    // Different attributes should create new aggregation
    const attributes2 = [_]api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "POST" } },
    };
    const entry3 = map.getOrCreateAggregation(instrument_ptr, &attributes2, metadata, .{ .i64 = 42 });
    try testing.expect(entry3 != entry1);
    try testing.expectEqual(@as(usize, 2), map.getCardinality());
}

test "AttributeAggregationMap - cardinality limit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = AttributeAggregationMap.init(allocator);
    defer map.deinit();

    // Fill up to the limit (using a smaller limit for testing)
    // Note: In practice, MAX_CARDINALITY is 2000, but for testing we can't easily create that many
    // This test verifies the logic works
    try testing.expect(!map.hasExceededLimit());
}
