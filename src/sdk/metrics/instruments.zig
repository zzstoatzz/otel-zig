//! OpenTelemetry Basic Meter Provider SDK Implementation
//!
//! This module provides the basic concrete implementation of MeterProvider for the SDK.
//! It manages meter lifecycle, caching, and configuration.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const Meter = @import("meter.zig").Meter;
    const aggregations = @import("aggregations.zig");
};

/// Standard Counter implementation with sum aggregation
pub fn StandardCounter(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        parent_meter: *sdk.Meter,
        aggregation: sdk.aggregations.SumAggregation(T),
        mutex: std.Thread.Mutex,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .parent_meter = parent_meter,
                .aggregation = .init(),
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateCounterValue(i64, value)) {
                api.common.reportValidationError(.meter, "Counter.add", "Negative value provided", "counter values must be non-negative");
                return; // Return early in validation mode
            }
            _ = ctx;
            _ = attributes;
            if (T == i64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn addF64(self: *@This(), ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateCounterValue(f64, value)) {
                api.common.reportValidationError(.meter, "Counter.add", "Negative value provided", "counter values must be non-negative");
                return; // Return early in validation mode
            }
            _ = ctx;
            _ = attributes;
            if (T == f64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn recordI64(_: *@This(), _: api.Context, _: i64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn recordF64(_: *@This(), _: api.Context, _: f64, _: []const api.AttributeKeyValue) void {
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

        pub fn enabled(self: *@This()) bool {
            _ = self;
            return true;
        }
    };
}

/// Standard UpDownCounter implementation with sum aggregation (allowing negative)
pub fn StandardUpDownCounter(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        parent_meter: *sdk.Meter,
        aggregation: sdk.aggregations.SumAggregation(T),
        mutex: std.Thread.Mutex,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .parent_meter = parent_meter,
                .aggregation = .init(),
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == i64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn addF64(self: *@This(), ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == f64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn recordI64(_: *@This(), _: api.Context, _: i64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn recordF64(_: *@This(), _: api.Context, _: f64, _: []const api.AttributeKeyValue) void {
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

        pub fn enabled(self: *@This()) bool {
            _ = self;
            return true;
        }
    };
}

/// Standard Gauge implementation with last value aggregation
pub fn StandardGauge(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        parent_meter: *sdk.Meter,
        aggregation: sdk.aggregations.LastValueAggregation(T),
        mutex: std.Thread.Mutex,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .parent_meter = parent_meter,
                .aggregation = .init(),
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn addF64(self: *@This(), ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn recordI64(self: *@This(), ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
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

        pub fn recordF64(self: *@This(), ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
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

        pub fn enabled(self: *@This()) bool {
            _ = self;
            return true;
        }
    };
}

/// Standard Histogram implementation with histogram aggregation
pub fn StandardHistogram(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        parent_meter: *sdk.Meter,
        aggregation: sdk.aggregations.HistogramAggregation(T),
        mutex: std.Thread.Mutex,
        allocator: std.mem.Allocator,

        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
            config: sdk.aggregations.HistogramAggregationConfig,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .parent_meter = parent_meter,
                .aggregation = try .init(allocator, config),
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

        pub fn addI64(_: *@This(), _: api.Context, _: i64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn addF64(_: *@This(), _: api.Context, _: f64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn recordI64(self: *@This(), ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateHistogramValue(i64, value)) {
                api.common.reportValidationError(.meter, "Histogram.record", "Negative value provided", "histogram values must be non-negative");
                return; // Return early in validation mode
            }
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

        pub fn recordF64(self: *@This(), ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateHistogramValue(f64, value)) {
                api.common.reportValidationError(.meter, "Histogram.record", "Negative value provided", "histogram values must be non-negative");
                return; // Return early in validation mode
            }
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

        pub fn getCount(self: *@This()) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getCount();
        }

        pub fn getSum(self: *@This()) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getSum();
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

        pub fn getStartTimestamp(self: *@This()) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getStartTime();
        }

        pub fn getBoundaries(self: *@This()) []const f64 {
            return self.aggregation.getBoundaries();
        }

        pub fn getCounts(self: *@This(), allocator: std.mem.Allocator) ![]u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            const counts = try allocator.dupe(u64, self.aggregation.getCounts());
            return counts;
        }

        pub fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.aggregation.reset();
        }

        pub fn enabled(self: *@This()) bool {
            _ = self;
            return true;
        }
    };
}
