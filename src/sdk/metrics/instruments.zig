//! OpenTelemetry SDK Metric Instruments Implementation
//!
//! This module provides the concrete implementations of metric instruments for the SDK.
//! These implementations handle the actual measurement recording and aggregation.
//!
//! For the MVP, we're implementing simple aggregations:
//! - Counter: Sum aggregation
//! - UpDownCounter: Sum aggregation (allowing negative values)
//! - Gauge: Last value aggregation
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md

const std = @import("std");
const otel_api = @import("otel-api");

const InstrumentationScope = otel_api.common.InstrumentationScope;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const Context = otel_api.Context;
const Resource = @import("../resource/resource.zig").Resource;
const ResourceBuilder = @import("../resource/resource.zig").ResourceBuilder;

/// Default histogram bucket boundaries as per OpenTelemetry specification
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

            // Binary search to find the right bucket
            const bucket_index = self.findBucketIndex(value);
            self.counts[bucket_index] += 1;
        }

        fn findBucketIndex(self: *const @This(), value: T) usize {
            const float_value = switch (T) {
                i64 => @as(f64, @floatFromInt(value)),
                f64 => value,
                else => unreachable,
            };

            // Binary search for the bucket
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

/// Standard Counter implementation with sum aggregation
pub fn StandardCounter(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        scope: InstrumentationScope,
        resource: Resource,
        aggregation: SumAggregation(T),
        mutex: std.Thread.Mutex,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            scope: InstrumentationScope,
            resource: Resource,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .scope = scope,
                .resource = resource,
                .aggregation = SumAggregation(T).init(),
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
            // No dynamic allocations to clean up for now
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == i64) {

                // For MVP, we ignore attributes and just aggregate all values together
                self.mutex.lock();
                defer self.mutex.unlock();

                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn addF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;

            if (T == f64) {
                // For MVP, we ignore attributes and just aggregate all values together
                self.mutex.lock();
                defer self.mutex.unlock();

                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn recordI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn recordF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn getValue(self: *@This()) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.aggregation.getValue();
        }

        pub fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.aggregation.reset();
        }

        pub fn getStartTimestamp(self: *@This()) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.aggregation.getStartTime();
        }
    };
}

/// Standard UpDownCounter implementation with sum aggregation (allowing negative)
pub fn StandardUpDownCounter(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        scope: InstrumentationScope,
        resource: Resource,
        aggregation: SumAggregation(T),
        mutex: std.Thread.Mutex,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            scope: InstrumentationScope,
            resource: Resource,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .scope = scope,
                .resource = resource,
                .aggregation = SumAggregation(T).init(),
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
            // No dynamic allocations to clean up for now
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == i64) {

                // For MVP, we ignore attributes and just aggregate all values together
                self.mutex.lock();
                defer self.mutex.unlock();

                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn addF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;

            if (T == f64) {
                // For MVP, we ignore attributes and just aggregate all values together
                self.mutex.lock();
                defer self.mutex.unlock();

                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn recordI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn recordF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn getValue(self: *@This()) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.aggregation.getValue();
        }

        pub fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.aggregation.reset();
        }

        pub fn getStartTimestamp(self: *@This()) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.aggregation.getStartTime();
        }
    };
}

/// Standard Gauge implementation with last value aggregation
pub fn StandardGauge(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        scope: InstrumentationScope,
        resource: Resource,
        aggregation: LastValueAggregation(T),
        mutex: std.Thread.Mutex,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            scope: InstrumentationScope,
            resource: Resource,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .scope = scope,
                .resource = resource,
                .aggregation = LastValueAggregation(T).init(),
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
            // No dynamic allocations to clean up for now
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn addF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn recordI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == i64) {

                // For MVP, we ignore attributes and just aggregate all values together
                self.mutex.lock();
                defer self.mutex.unlock();

                self.aggregation.record(value);
            } else {
                unreachable;
            }
        }

        pub fn recordF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;

            if (T == f64) {
                // For MVP, we ignore attributes and just aggregate all values together
                self.mutex.lock();
                defer self.mutex.unlock();

                self.aggregation.record(value);
            } else {
                unreachable;
            }
        }

        pub fn getValue(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.aggregation.getValue();
        }

        pub fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.aggregation.reset();
        }
    };
}

/// Standard Histogram implementation with configurable buckets
pub fn StandardHistogram(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        scope: InstrumentationScope,
        resource: Resource,
        aggregation: HistogramAggregation(T),
        mutex: std.Thread.Mutex,
        allocator: std.mem.Allocator,

        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            scope: InstrumentationScope,
            resource: Resource,
            config: HistogramAggregationConfig,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .scope = scope,
                .resource = resource,
                .aggregation = try HistogramAggregation(T).init(allocator, config),
                .mutex = std.Thread.Mutex{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.aggregation.deinit(self.allocator);
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn addF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn recordI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == i64) {
                self.mutex.lock();
                defer self.mutex.unlock();

                self.aggregation.record(value);
            } else {
                unreachable;
            }
        }

        pub fn recordF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == f64) {
                self.mutex.lock();
                defer self.mutex.unlock();

                self.aggregation.record(value);
            } else {
                unreachable;
            }
        }

        pub fn getSum(self: *@This()) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.aggregation.getSum();
        }

        pub fn getCount(self: *@This()) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.aggregation.getCount();
        }

        pub fn getMin(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.aggregation.getMin();
        }

        pub fn getMax(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.aggregation.getMax();
        }

        pub fn getBoundaries(self: *@This()) []const f64 {
            // Boundaries are immutable, no lock needed
            return self.aggregation.getBoundaries();
        }

        pub fn getCounts(self: *@This(), allocator: std.mem.Allocator) ![]u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Return a copy to avoid race conditions
            const counts = try allocator.dupe(u64, self.aggregation.getCounts());
            return counts;
        }

        pub fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.aggregation.reset();
        }

        pub fn getStartTimestamp(self: *@This()) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.aggregation.getStartTime();
        }
    };
}

// Tests

test "StandardCounter operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    const scope = try InstrumentationScope.initWithName("test");
    var counter = try StandardCounter(i64).init(
        "test.counter",
        "Test counter",
        "1",
        scope,
        resource,
    );
    defer counter.deinit();

    const ctx = Context.empty(allocator);
    const attrs = [_]AttributeKeyValue{};

    // Initial value should be 0
    try testing.expectEqual(@as(i64, 0), counter.getValue());

    // Add some values
    counter.addI64(ctx, 10, &attrs);
    counter.addI64(ctx, 5, &attrs);
    counter.addI64(ctx, 3, &attrs);

    // Should sum to 18
    try testing.expectEqual(@as(i64, 18), counter.getValue());

    // Reset and verify
    counter.reset();
    try testing.expectEqual(@as(i64, 0), counter.getValue());
}

test "StandardUpDownCounter operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    const scope = try InstrumentationScope.initWithName("test");
    var counter = try StandardUpDownCounter(f64).init(
        "test.updown",
        "Test up-down counter",
        "ms",
        scope,
        resource,
    );
    defer counter.deinit();

    const ctx = Context.empty(allocator);
    const attrs = [_]AttributeKeyValue{};

    // Initial value should be 0
    try testing.expectEqual(@as(f64, 0), counter.getValue());

    // Add positive and negative values
    counter.addF64(ctx, 10.5, &attrs);
    counter.addF64(ctx, -3.2, &attrs);
    counter.addF64(ctx, 5.7, &attrs);

    // Should sum to 13.0
    try testing.expectApproxEqRel(@as(f64, 13.0), counter.getValue(), 0.001);

    // Reset and verify
    counter.reset();
    try testing.expectEqual(@as(f64, 0), counter.getValue());
}

test "StandardGauge operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    const scope = try InstrumentationScope.initWithName("test");
    var gauge = try StandardGauge(f64).init(
        "test.gauge",
        "Test gauge",
        "°C",
        scope,
        resource,
    );
    defer gauge.deinit();

    const ctx = Context.empty(allocator);
    const attrs = [_]AttributeKeyValue{};

    // Initial value should be null
    try testing.expect(gauge.getValue() == null);

    // Record some values
    gauge.recordF64(ctx, 23.5, &attrs);
    try testing.expectEqual(@as(f64, 23.5), gauge.getValue().?);

    gauge.recordF64(ctx, 24.1, &attrs);
    try testing.expectEqual(@as(f64, 24.1), gauge.getValue().?);

    gauge.recordF64(ctx, 22.8, &attrs);
    try testing.expectEqual(@as(f64, 22.8), gauge.getValue().?);

    // Reset and verify
    gauge.reset();
    try testing.expect(gauge.getValue() == null);
}

test "StandardHistogram operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    const scope = try InstrumentationScope.initWithName("test");
    var histogram = try StandardHistogram(f64).init(
        allocator,
        "test.histogram",
        "Test histogram",
        "ms",
        scope,
        resource,
        .{}, // Use default config
    );
    defer histogram.deinit();

    const ctx = Context.empty(allocator);
    const attrs = [_]AttributeKeyValue{};

    // Initial state
    try testing.expectEqual(@as(u64, 0), histogram.getCount());
    try testing.expectEqual(@as(f64, 0), histogram.getSum());
    try testing.expectEqual(@as(?f64, null), histogram.getMin());
    try testing.expectEqual(@as(?f64, null), histogram.getMax());

    // Record some values
    histogram.recordF64(ctx, 2.5, &attrs);
    histogram.recordF64(ctx, 7.8, &attrs);
    histogram.recordF64(ctx, 15.3, &attrs);
    histogram.recordF64(ctx, 125.6, &attrs);

    // Check aggregation
    try testing.expectEqual(@as(u64, 4), histogram.getCount());
    try testing.expectApproxEqRel(@as(f64, 151.2), histogram.getSum(), 0.001);
    try testing.expectEqual(@as(f64, 2.5), histogram.getMin().?);
    try testing.expectEqual(@as(f64, 125.6), histogram.getMax().?);

    // Check bucket counts
    const counts = try histogram.getCounts(allocator);
    defer allocator.free(counts);

    // Based on default boundaries: [0, 5, 10, 25, 50, 75, 100, 250, ...]
    // 2.5 -> bucket 1 (0-5)
    // 7.8 -> bucket 2 (5-10)
    // 15.3 -> bucket 3 (10-25)
    // 125.6 -> bucket 7 (100-250)
    try testing.expectEqual(@as(u64, 0), counts[0]); // (-inf, 0)
    try testing.expectEqual(@as(u64, 1), counts[1]); // [0, 5)
    try testing.expectEqual(@as(u64, 1), counts[2]); // [5, 10)
    try testing.expectEqual(@as(u64, 1), counts[3]); // [10, 25)
    try testing.expectEqual(@as(u64, 0), counts[4]); // [25, 50)
    try testing.expectEqual(@as(u64, 0), counts[5]); // [50, 75)
    try testing.expectEqual(@as(u64, 0), counts[6]); // [75, 100)
    try testing.expectEqual(@as(u64, 1), counts[7]); // [100, 250)

    // Reset and verify
    histogram.reset();
    try testing.expectEqual(@as(u64, 0), histogram.getCount());
    try testing.expectEqual(@as(f64, 0), histogram.getSum());
    try testing.expectEqual(@as(?f64, null), histogram.getMin());
    try testing.expectEqual(@as(?f64, null), histogram.getMax());
}

test "StandardHistogram with custom buckets" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    const scope = try InstrumentationScope.initWithName("test");

    const custom_boundaries = [_]f64{ 0.0, 1.0, 2.0, 5.0, 10.0 };
    var histogram = try StandardHistogram(i64).init(
        allocator,
        "test.custom.histogram",
        "Test histogram with custom buckets",
        "items",
        scope,
        resource,
        .{
            .boundaries = &custom_boundaries,
            .record_min_max = true,
        },
    );
    defer histogram.deinit();

    const ctx = Context.empty(allocator);
    const attrs = [_]AttributeKeyValue{};

    // Record values
    histogram.recordI64(ctx, 0, &attrs);
    histogram.recordI64(ctx, 1, &attrs);
    histogram.recordI64(ctx, 3, &attrs);
    histogram.recordI64(ctx, 7, &attrs);
    histogram.recordI64(ctx, 15, &attrs);

    // Check counts
    const counts = try histogram.getCounts(allocator);
    defer allocator.free(counts);

    try testing.expectEqual(@as(usize, 6), counts.len); // 5 boundaries + 1
    try testing.expectEqual(@as(u64, 0), counts[0]); // (-inf, 0)
    try testing.expectEqual(@as(u64, 1), counts[1]); // [0, 1)
    try testing.expectEqual(@as(u64, 1), counts[2]); // [1, 2)
    try testing.expectEqual(@as(u64, 1), counts[3]); // [2, 5)
    try testing.expectEqual(@as(u64, 1), counts[4]); // [5, 10)
    try testing.expectEqual(@as(u64, 1), counts[5]); // [10, +inf)

    // Check aggregates
    try testing.expectEqual(@as(u64, 5), histogram.getCount());
    try testing.expectEqual(@as(i64, 26), histogram.getSum());
    try testing.expectEqual(@as(i64, 0), histogram.getMin().?);
    try testing.expectEqual(@as(i64, 15), histogram.getMax().?);
}
