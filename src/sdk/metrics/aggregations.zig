//! Basic Aggregation Types for OpenTelemetry Metrics SDK
//!
//! This module provides the basic aggregation implementations used by the metrics SDK.
//! These aggregations handle the collection and computation of metric data points.

const std = @import("std");

const InstrumentType = @import("metadata.zig").InstrumentType;

pub const DEFAULT_HISTOGRAM_BOUNDARIES = [_]f64{
    0.0,   5.0,   10.0,   25.0,   50.0,   75.0,   100.0,   250.0,
    500.0, 750.0, 1000.0, 2500.0, 5000.0, 7500.0, 10000.0,
};

/// Configuration for histogram aggregation
pub const HistogramAggregationConfig = struct {
    boundaries: []const f64 = &DEFAULT_HISTOGRAM_BOUNDARIES,
    record_min_max: bool = true,
};

/// Simple aggregation state for sum aggregation
pub fn SumAggregation(comptime T: type) type {
    return struct {
        value: std.atomic.Value(T),
        start_timestamp_ns: u64,

        // Metadata fields for Phase 1b preparation
        instrument_name: []const u8,
        instrument_type: InstrumentType,
        instrument_unit: []const u8,

        pub fn init() @This() {
            return .{
                .value = std.atomic.Value(T).init(0),
                .start_timestamp_ns = @intCast(std.time.nanoTimestamp()),
                .instrument_name = "",
                .instrument_type = .Counter,
                .instrument_unit = "",
            };
        }

        pub fn add(self: *@This(), value: T) void {
            _ = self.value.fetchAdd(value, .monotonic);
        }

        pub fn getValue(self: *const @This()) T {
            return self.value.load(.monotonic);
        }

        pub fn getStartTime(self: *const @This()) u64 {
            return self.start_timestamp_ns;
        }

        pub fn reset(self: *@This()) void {
            self.value.store(0, .monotonic);
            self.start_timestamp_ns = @intCast(std.time.nanoTimestamp());
        }
    };
}

/// Simple aggregation state for last value aggregation
pub fn LastValueAggregation(comptime T: type) type {
    return struct {
        has_value: std.atomic.Value(bool),
        value: std.atomic.Value(T),

        // Metadata fields for Phase 1b preparation
        instrument_name: []const u8,
        instrument_type: InstrumentType,
        instrument_unit: []const u8,

        pub fn init() @This() {
            return .{
                .has_value = std.atomic.Value(bool).init(false),
                .value = std.atomic.Value(T).init(0),
                .instrument_name = "",
                .instrument_type = .Gauge,
                .instrument_unit = "",
            };
        }

        pub fn record(self: *@This(), value: T) void {
            self.value.store(value, .monotonic);
            self.has_value.store(true, .monotonic);
        }

        pub fn getValue(self: *const @This()) ?T {
            if (self.has_value.load(.monotonic)) {
                return self.value.load(.monotonic);
            }
            return null;
        }

        pub fn reset(self: *@This()) void {
            self.has_value.store(false, .monotonic);
            self.value.store(0, .monotonic);
        }
    };
}

/// Histogram aggregation state
pub fn HistogramAggregation(comptime T: type) type {
    return struct {
        boundaries: []const f64,
        counts: []std.atomic.Value(u64),
        sum: std.atomic.Value(T),
        count: std.atomic.Value(u64),
        has_min: std.atomic.Value(bool),
        min: std.atomic.Value(T),
        has_max: std.atomic.Value(bool),
        max: std.atomic.Value(T),
        start_timestamp_ns: u64,
        record_min_max: bool,

        // Metadata fields for Phase 1b preparation
        instrument_name: []const u8,
        instrument_type: InstrumentType,
        instrument_unit: []const u8,

        pub fn init(allocator: std.mem.Allocator, config: HistogramAggregationConfig) !@This() {
            const counts = try allocator.alloc(std.atomic.Value(u64), config.boundaries.len + 1);
            for (counts) |*count| {
                count.* = std.atomic.Value(u64).init(0);
            }

            return .{
                .boundaries = config.boundaries,
                .counts = counts,
                .sum = std.atomic.Value(T).init(0),
                .count = std.atomic.Value(u64).init(0),
                .has_min = std.atomic.Value(bool).init(false),
                .min = std.atomic.Value(T).init(0),
                .has_max = std.atomic.Value(bool).init(false),
                .max = std.atomic.Value(T).init(0),
                .start_timestamp_ns = @intCast(std.time.nanoTimestamp()),
                .record_min_max = config.record_min_max,
                .instrument_name = "",
                .instrument_type = .Histogram,
                .instrument_unit = "",
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.counts);
        }

        pub fn record(self: *@This(), value: T) void {
            // Atomic operations for sum and count
            _ = self.count.fetchAdd(1, .monotonic);
            _ = self.sum.fetchAdd(value, .monotonic);

            if (self.record_min_max) {
                // Simple atomic min/max (not fully lock-free for f64, but functional)
                if (self.has_min.load(.monotonic)) {
                    const current_min = self.min.load(.monotonic);
                    if (value < current_min) {
                        self.min.store(value, .monotonic);
                    }
                } else {
                    self.min.store(value, .monotonic);
                    self.has_min.store(true, .monotonic);
                }

                if (self.has_max.load(.monotonic)) {
                    const current_max = self.max.load(.monotonic);
                    if (value > current_max) {
                        self.max.store(value, .monotonic);
                    }
                } else {
                    self.max.store(value, .monotonic);
                    self.has_max.store(true, .monotonic);
                }
            }

            const bucket_index = self.findBucketIndex(value);
            _ = self.counts[bucket_index].fetchAdd(1, .monotonic);
        }

        pub fn findBucketIndex(self: *const @This(), value: T) usize {
            const float_value = switch (T) {
                i64 => @as(f64, @floatFromInt(value)),
                f64 => value,
                else => unreachable,
            };

            var left: usize = 0;
            var right: usize = self.boundaries.len;

            while (left < right) {
                const mid = left + (right - left) / 2;
                if (float_value < self.boundaries[mid]) {
                    right = mid;
                } else {
                    left = mid + 1;
                }
            }

            return left;
        }

        pub fn getSum(self: *const @This()) T {
            return self.sum.load(.monotonic);
        }

        pub fn getCount(self: *const @This()) u64 {
            return self.count.load(.monotonic);
        }

        pub fn getMin(self: *const @This()) ?T {
            if (self.has_min.load(.monotonic)) {
                return self.min.load(.monotonic);
            }
            return null;
        }

        pub fn getMax(self: *const @This()) ?T {
            if (self.has_max.load(.monotonic)) {
                return self.max.load(.monotonic);
            }
            return null;
        }

        pub fn getBoundaries(self: *const @This()) []const f64 {
            return self.boundaries;
        }

        pub fn getCounts(self: *const @This()) []const std.atomic.Value(u64) {
            return self.counts;
        }

        pub fn getStartTime(self: *const @This()) u64 {
            return self.start_timestamp_ns;
        }

        pub fn reset(self: *@This()) void {
            for (self.counts) |*count| {
                count.store(0, .monotonic);
            }
            self.sum.store(0, .monotonic);
            self.count.store(0, .monotonic);
            self.has_min.store(false, .monotonic);
            self.min.store(0, .monotonic);
            self.has_max.store(false, .monotonic);
            self.max.store(0, .monotonic);
            self.start_timestamp_ns = @intCast(std.time.nanoTimestamp());
        }
    };
}
