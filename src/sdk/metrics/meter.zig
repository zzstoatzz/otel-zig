//! OpenTelemetry Meter SDK Implementation
//!
//! This module provides the concrete implementation of Meter for the SDK.
//! It manages instrument lifecycle and provides the actual measurement recording.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md

const std = @import("std");
const otel_api = @import("otel-api");

const InstrumentationScope = otel_api.common.InstrumentationScope;
const KeyValue = otel_api.common.KeyValue;
const Context = otel_api.Context;
const Resource = @import("../resource/resource.zig").Resource;

// Import instrument implementations
const StandardCounter = @import("instruments.zig").StandardCounter;
const StandardUpDownCounter = @import("instruments.zig").StandardUpDownCounter;
const StandardGauge = @import("instruments.zig").StandardGauge;
const MetricData = @import("processor.zig").MetricData;
const MetricDataPoint = @import("processor.zig").MetricDataPoint;
const MetricType = @import("processor.zig").MetricType;
const MetricValue = @import("processor.zig").MetricValue;

/// Standard meter implementation
pub const StandardMeter = struct {
    allocator: std.mem.Allocator,
    scope: InstrumentationScope,
    resource: *const Resource,
    
    // Track created instruments for cleanup
    counters_i64: std.ArrayList(*StandardCounter(i64)),
    counters_f64: std.ArrayList(*StandardCounter(f64)),
    up_down_counters_i64: std.ArrayList(*StandardUpDownCounter(i64)),
    up_down_counters_f64: std.ArrayList(*StandardUpDownCounter(f64)),
    gauges_i64: std.ArrayList(*StandardGauge(i64)),
    gauges_f64: std.ArrayList(*StandardGauge(f64)),
    
    // Track API wrappers for cleanup
    api_counters_i64: std.ArrayList(*otel_api.metrics.Counter(i64)),
    api_counters_f64: std.ArrayList(*otel_api.metrics.Counter(f64)),
    api_up_down_counters_i64: std.ArrayList(*otel_api.metrics.UpDownCounter(i64)),
    api_up_down_counters_f64: std.ArrayList(*otel_api.metrics.UpDownCounter(f64)),
    api_gauges_i64: std.ArrayList(*otel_api.metrics.Gauge(i64)),
    api_gauges_f64: std.ArrayList(*otel_api.metrics.Gauge(f64)),

    pub fn init(
        allocator: std.mem.Allocator,
        scope: InstrumentationScope,
        resource: *const Resource,
    ) !StandardMeter {
        return .{
            .allocator = allocator,
            .scope = scope,
            .resource = resource,
            .counters_i64 = std.ArrayList(*StandardCounter(i64)).init(allocator),
            .counters_f64 = std.ArrayList(*StandardCounter(f64)).init(allocator),
            .up_down_counters_i64 = std.ArrayList(*StandardUpDownCounter(i64)).init(allocator),
            .up_down_counters_f64 = std.ArrayList(*StandardUpDownCounter(f64)).init(allocator),
            .gauges_i64 = std.ArrayList(*StandardGauge(i64)).init(allocator),
            .gauges_f64 = std.ArrayList(*StandardGauge(f64)).init(allocator),
            .api_counters_i64 = std.ArrayList(*otel_api.metrics.Counter(i64)).init(allocator),
            .api_counters_f64 = std.ArrayList(*otel_api.metrics.Counter(f64)).init(allocator),
            .api_up_down_counters_i64 = std.ArrayList(*otel_api.metrics.UpDownCounter(i64)).init(allocator),
            .api_up_down_counters_f64 = std.ArrayList(*otel_api.metrics.UpDownCounter(f64)).init(allocator),
            .api_gauges_i64 = std.ArrayList(*otel_api.metrics.Gauge(i64)).init(allocator),
            .api_gauges_f64 = std.ArrayList(*otel_api.metrics.Gauge(f64)).init(allocator),
        };
    }

    pub fn deinit(self: *StandardMeter) void {
        // Clean up all instruments
        for (self.counters_i64.items) |counter| {
            counter.deinit();
            self.allocator.destroy(counter);
        }
        self.counters_i64.deinit();

        for (self.counters_f64.items) |counter| {
            counter.deinit();
            self.allocator.destroy(counter);
        }
        self.counters_f64.deinit();

        for (self.up_down_counters_i64.items) |counter| {
            counter.deinit();
            self.allocator.destroy(counter);
        }
        self.up_down_counters_i64.deinit();

        for (self.up_down_counters_f64.items) |counter| {
            counter.deinit();
            self.allocator.destroy(counter);
        }
        self.up_down_counters_f64.deinit();

        for (self.gauges_i64.items) |gauge| {
            gauge.deinit();
            self.allocator.destroy(gauge);
        }
        self.gauges_i64.deinit();

        for (self.gauges_f64.items) |gauge| {
            gauge.deinit();
            self.allocator.destroy(gauge);
        }
        self.gauges_f64.deinit();
        
        // Clean up API wrappers
        for (self.api_counters_i64.items) |counter| {
            self.allocator.destroy(counter);
        }
        self.api_counters_i64.deinit();
        
        for (self.api_counters_f64.items) |counter| {
            self.allocator.destroy(counter);
        }
        self.api_counters_f64.deinit();
        
        for (self.api_up_down_counters_i64.items) |counter| {
            self.allocator.destroy(counter);
        }
        self.api_up_down_counters_i64.deinit();
        
        for (self.api_up_down_counters_f64.items) |counter| {
            self.allocator.destroy(counter);
        }
        self.api_up_down_counters_f64.deinit();
        
        for (self.api_gauges_i64.items) |gauge| {
            self.allocator.destroy(gauge);
        }
        self.api_gauges_i64.deinit();
        
        for (self.api_gauges_f64.items) |gauge| {
            self.allocator.destroy(gauge);
        }
        self.api_gauges_f64.deinit();
    }

    pub fn getInstrumentationScope(self: *const StandardMeter) InstrumentationScope {
        return self.scope;
    }

    pub fn createCounterI64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*otel_api.metrics.Counter(i64) {
        const counter = try self.allocator.create(StandardCounter(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardCounter(i64).init(
            self.allocator,
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer counter.deinit();

        try self.counters_i64.append(counter);

        // Wrap for API use
        const api_counter = try @import("../bridge/root.zig").wrapStandardCounter(i64, self.allocator, counter);
        try self.api_counters_i64.append(api_counter);
        return api_counter;
    }

    pub fn createCounterF64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*otel_api.metrics.Counter(f64) {
        const counter = try self.allocator.create(StandardCounter(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardCounter(f64).init(
            self.allocator,
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer counter.deinit();

        try self.counters_f64.append(counter);

        // Wrap for API use
        const api_counter = try @import("../bridge/root.zig").wrapStandardCounter(f64, self.allocator, counter);
        try self.api_counters_f64.append(api_counter);
        return api_counter;
    }

    pub fn createUpDownCounterI64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*otel_api.metrics.UpDownCounter(i64) {
        const counter = try self.allocator.create(StandardUpDownCounter(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardUpDownCounter(i64).init(
            self.allocator,
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer counter.deinit();

        try self.up_down_counters_i64.append(counter);

        // Wrap for API use
        const api_counter = try @import("../bridge/root.zig").wrapStandardUpDownCounter(i64, self.allocator, counter);
        try self.api_up_down_counters_i64.append(api_counter);
        return api_counter;
    }

    pub fn createUpDownCounterF64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*otel_api.metrics.UpDownCounter(f64) {
        const counter = try self.allocator.create(StandardUpDownCounter(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardUpDownCounter(f64).init(
            self.allocator,
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer counter.deinit();

        try self.up_down_counters_f64.append(counter);

        // Wrap for API use
        const api_counter = try @import("../bridge/root.zig").wrapStandardUpDownCounter(f64, self.allocator, counter);
        try self.api_up_down_counters_f64.append(api_counter);
        return api_counter;
    }

    pub fn createGaugeI64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*otel_api.metrics.Gauge(i64) {
        const gauge = try self.allocator.create(StandardGauge(i64));
        errdefer self.allocator.destroy(gauge);

        gauge.* = try StandardGauge(i64).init(
            self.allocator,
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer gauge.deinit();

        try self.gauges_i64.append(gauge);

        // Wrap for API use
        const api_gauge = try @import("../bridge/root.zig").wrapStandardGauge(i64, self.allocator, gauge);
        try self.api_gauges_i64.append(api_gauge);
        return api_gauge;
    }

    pub fn createGaugeF64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*otel_api.metrics.Gauge(f64) {
        const gauge = try self.allocator.create(StandardGauge(f64));
        errdefer self.allocator.destroy(gauge);

        gauge.* = try StandardGauge(f64).init(
            self.allocator,
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer gauge.deinit();

        try self.gauges_f64.append(gauge);

        // Wrap for API use
        const api_gauge = try @import("../bridge/root.zig").wrapStandardGauge(f64, self.allocator, gauge);
        try self.api_gauges_f64.append(api_gauge);
        return api_gauge;
    }

    /// Collect metrics from all instruments managed by this meter
    pub fn collectMetrics(self: *StandardMeter, allocator: std.mem.Allocator) ![]MetricData {
        var metrics = std.ArrayList(MetricData).init(allocator);
        errdefer metrics.deinit();

        const timestamp_ns = @as(u64, @intCast(std.time.nanoTimestamp()));

        // Collect from i64 counters
        for (self.counters_i64.items) |counter| {
            const value = counter.getValue();
            if (value == 0) continue; // Skip empty counters

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]KeyValue{}, // MVP: no attribute support yet
                .value = .{ .i64_sum = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = counter.name,
                .description = counter.description,
                .unit = counter.unit,
                .type = .sum,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from f64 counters
        for (self.counters_f64.items) |counter| {
            const value = counter.getValue();
            if (value == 0) continue; // Skip empty counters

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]KeyValue{}, // MVP: no attribute support yet
                .value = .{ .f64_sum = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = counter.name,
                .description = counter.description,
                .unit = counter.unit,
                .type = .sum,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from i64 up-down counters
        for (self.up_down_counters_i64.items) |counter| {
            const value = counter.getValue();

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]KeyValue{}, // MVP: no attribute support yet
                .value = .{ .i64_sum = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = counter.name,
                .description = counter.description,
                .unit = counter.unit,
                .type = .sum,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from f64 up-down counters
        for (self.up_down_counters_f64.items) |counter| {
            const value = counter.getValue();

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]KeyValue{}, // MVP: no attribute support yet
                .value = .{ .f64_sum = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = counter.name,
                .description = counter.description,
                .unit = counter.unit,
                .type = .sum,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from i64 gauges
        for (self.gauges_i64.items) |gauge| {
            const value = gauge.getValue() orelse continue; // Skip if no value recorded

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = null, // Gauges don't have start times
                .attributes = &[_]KeyValue{}, // MVP: no attribute support yet
                .value = .{ .i64_gauge = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = gauge.name,
                .description = gauge.description,
                .unit = gauge.unit,
                .type = .gauge,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from f64 gauges
        for (self.gauges_f64.items) |gauge| {
            const value = gauge.getValue() orelse continue; // Skip if no value recorded

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = null, // Gauges don't have start times
                .attributes = &[_]KeyValue{}, // MVP: no attribute support yet
                .value = .{ .f64_gauge = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = gauge.name,
                .description = gauge.description,
                .unit = gauge.unit,
                .type = .gauge,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        return metrics.toOwnedSlice();
    }
};

/// Create a standard meter
pub fn createStandardMeter(
    allocator: std.mem.Allocator,
    scope: InstrumentationScope,
    resource: *const Resource,
) !StandardMeter {
    return try StandardMeter.init(allocator, scope, resource);
}

// Tests

test "StandardMeter basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);

    const scope = try InstrumentationScope.initWithName("test.meter");
    var meter = try createStandardMeter(allocator, scope, &resource);
    defer meter.deinit();

    // Test creating instruments
    const counter = try meter.createCounterI64("test.counter", "A test counter", "1");
    try testing.expectEqualStrings("test.counter", counter.getName());

    const up_down = try meter.createUpDownCounterF64("test.updown", "A test up-down counter", "ms");
    try testing.expectEqualStrings("test.updown", up_down.getName());

    const gauge = try meter.createGaugeF64("test.gauge", "A test gauge", "°C");
    try testing.expectEqualStrings("test.gauge", gauge.getName());

    // Test getting instrumentation scope
    const meter_scope = meter.getInstrumentationScope();
    try testing.expectEqualStrings("test.meter", meter_scope.name);
}

test "StandardMeter instrument creation and usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);

    const scope = try InstrumentationScope.initWithName("test.meter");
    var meter = try createStandardMeter(allocator, scope, &resource);
    defer meter.deinit();

    // Create and use a counter
    const counter = try meter.createCounterI64("requests.total", "Total requests", "1");
    const ctx = Context.empty(allocator);
    const attrs = [_]KeyValue{
        KeyValue.init("method", .{ .string = "GET" }),
        KeyValue.init("status", .{ .int = 200 }),
    };
    counter.add(ctx, 1, &attrs);
    counter.addSimple(ctx, 5);

    // Create and use an up-down counter
    const connections = try meter.createUpDownCounterI64("connections.active", "Active connections", "1");
    connections.add(ctx, 10, &attrs);
    connections.add(ctx, -3, &attrs);

    // Create and use a gauge
    const temperature = try meter.createGaugeF64("room.temperature", "Room temperature", "°C");
    temperature.record(ctx, 23.5, &attrs);
    temperature.recordSimple(ctx, 24.1);
}

test "StandardMeter multiple instruments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);

    const scope = try InstrumentationScope.initWithName("test.app");
    var meter = try createStandardMeter(allocator, scope, &resource);
    defer meter.deinit();

    // Create multiple instruments of different types
    const counter1 = try meter.createCounterI64("counter1", null, null);
    const counter2 = try meter.createCounterF64("counter2", null, null);
    const updown1 = try meter.createUpDownCounterI64("updown1", null, null);
    const updown2 = try meter.createUpDownCounterF64("updown2", null, null);
    const gauge1 = try meter.createGaugeI64("gauge1", null, null);
    const gauge2 = try meter.createGaugeF64("gauge2", null, null);

    // Verify they all have different names
    try testing.expectEqualStrings("counter1", counter1.getName());
    try testing.expectEqualStrings("counter2", counter2.getName());
    try testing.expectEqualStrings("updown1", updown1.getName());
    try testing.expectEqualStrings("updown2", updown2.getName());
    try testing.expectEqualStrings("gauge1", gauge1.getName());
    try testing.expectEqualStrings("gauge2", gauge2.getName());
}