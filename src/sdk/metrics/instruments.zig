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

// Tests

test "StandardCounter operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
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

    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
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

    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
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
