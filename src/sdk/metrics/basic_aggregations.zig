//! Basic Aggregation Types for OpenTelemetry Metrics SDK
//!
//! This module provides the basic aggregation implementations used by the metrics SDK.
//! These aggregations handle the collection and computation of metric data points.

const std = @import("std");

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
        value: T,
        start_timestamp_ns: u64,

        pub fn init() @This() {
            return .{
                .value = 0,
                .start_timestamp_ns = @intCast(std.time.nanoTimestamp()),
            };
        }

        pub fn add(self: *@This(), value: T) void {
            self.value += value;
        }

        pub fn getValue(self: *const @This()) T {
            return self.value;
        }

        pub fn getStartTime(self: *const @This()) u64 {
            return self.start_timestamp_ns;
        }

        pub fn reset(self: *@This()) void {
            self.value = 0;
            self.start_timestamp_ns = @intCast(std.time.nanoTimestamp());
        }
    };
}

/// Simple aggregation state for last value aggregation
pub fn LastValueAggregation(comptime T: type) type {
    return struct {
        value: ?T,

        pub fn init() @This() {
            return .{ .value = null };
        }

        pub fn record(self: *@This(), value: T) void {
            self.value = value;
        }

        pub fn getValue(self: *const @This()) ?T {
            return self.value;
        }

        pub fn reset(self: *@This()) void {
            self.value = null;
        }
    };
}

/// Histogram aggregation state
pub fn HistogramAggregation(comptime T: type) type {
    return struct {
        boundaries: []const f64,
        counts: []u64,
        sum: T,
        count: u64,
        min: ?T,
        max: ?T,
        start_timestamp_ns: u64,
        record_min_max: bool,

        pub fn init(allocator: std.mem.Allocator, config: HistogramAggregationConfig) !@This() {
            const counts = try allocator.alloc(u64, config.boundaries.len + 1);
            @memset(counts, 0);

            return .{
                .boundaries = config.boundaries,
                .counts = counts,
                .sum = 0,
                .count = 0,
                .min = null,
                .max = null,
                .start_timestamp_ns = @intCast(std.time.nanoTimestamp()),
                .record_min_max = config.record_min_max,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.counts);
        }

        pub fn record(self: *@This(), value: T) void {
            self.count += 1;
            self.sum += value;

            if (self.record_min_max) {
                if (self.min) |min| {
                    self.min = @min(min, value);
                } else {
                    self.min = value;
                }

                if (self.max) |max| {
                    self.max = @max(max, value);
                } else {
                    self.max = value;
                }
            }

            const bucket_index = self.findBucketIndex(value);
            self.counts[bucket_index] += 1;
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
            return self.sum;
        }

        pub fn getCount(self: *const @This()) u64 {
            return self.count;
        }

        pub fn getMin(self: *const @This()) ?T {
            return self.min;
        }

        pub fn getMax(self: *const @This()) ?T {
            return self.max;
        }

        pub fn getBoundaries(self: *const @This()) []const f64 {
            return self.boundaries;
        }

        pub fn getCounts(self: *const @This()) []const u64 {
            return self.counts;
        }

        pub fn getStartTime(self: *const @This()) u64 {
            return self.start_timestamp_ns;
        }

        pub fn reset(self: *@This()) void {
            @memset(self.counts, 0);
            self.sum = 0;
            self.count = 0;
            self.min = null;
            self.max = null;
            self.start_timestamp_ns = @intCast(std.time.nanoTimestamp());
        }
    };
}
