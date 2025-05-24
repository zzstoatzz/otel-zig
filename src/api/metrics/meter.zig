//! OpenTelemetry Meter API
//!
//! This module defines the Meter interface for creating metric instruments.
//! A Meter is responsible for creating instruments (Counter, Gauge, etc.) that
//! are used to record measurements.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/api.md#meter

const std = @import("std");

// Import from relative paths
const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const KeyValue = @import("../common/root.zig").KeyValue;
const Context = @import("../context/root.zig").Context;

// Forward declarations for instruments
const Counter = @import("instrument.zig").Counter;
const UpDownCounter = @import("instrument.zig").UpDownCounter;
const Gauge = @import("instrument.zig").Gauge;

/// Meter interface using tagged union for polymorphism
pub const Meter = union(enum) {
    noop: NoopMeter,
    sdk: SdkMeterBridge,

    /// Get the instrumentation scope associated with this meter
    pub inline fn getInstrumentationScope(self: *const Meter) InstrumentationScope {
        return switch (self.*) {
            .noop => |meter| meter.scope,
            .sdk => |bridge| bridge.vtable.getInstrumentationScope(bridge.meter_ptr),
        };
    }

    /// Create a Counter instrument for i64 values
    pub inline fn createCounterI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*Counter(i64) {
        return switch (self.*) {
            .noop => |*meter| meter.createCounterI64(name, description, unit),
            .sdk => |*bridge| bridge.vtable.createCounterI64(bridge.meter_ptr, name, description, unit),
        };
    }

    /// Create a Counter instrument for f64 values
    pub inline fn createCounterF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*Counter(f64) {
        return switch (self.*) {
            .noop => |*meter| meter.createCounterF64(name, description, unit),
            .sdk => |*bridge| bridge.vtable.createCounterF64(bridge.meter_ptr, name, description, unit),
        };
    }

    /// Create an UpDownCounter instrument for i64 values
    pub inline fn createUpDownCounterI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*UpDownCounter(i64) {
        return switch (self.*) {
            .noop => |*meter| meter.createUpDownCounterI64(name, description, unit),
            .sdk => |*bridge| bridge.vtable.createUpDownCounterI64(bridge.meter_ptr, name, description, unit),
        };
    }

    /// Create an UpDownCounter instrument for f64 values
    pub inline fn createUpDownCounterF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*UpDownCounter(f64) {
        return switch (self.*) {
            .noop => |*meter| meter.createUpDownCounterF64(name, description, unit),
            .sdk => |*bridge| bridge.vtable.createUpDownCounterF64(bridge.meter_ptr, name, description, unit),
        };
    }

    /// Create a Gauge instrument for i64 values
    pub inline fn createGaugeI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*Gauge(i64) {
        return switch (self.*) {
            .noop => |*meter| meter.createGaugeI64(name, description, unit),
            .sdk => |*bridge| bridge.vtable.createGaugeI64(bridge.meter_ptr, name, description, unit),
        };
    }

    /// Create a Gauge instrument for f64 values
    pub inline fn createGaugeF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*Gauge(f64) {
        return switch (self.*) {
            .noop => |*meter| meter.createGaugeF64(name, description, unit),
            .sdk => |*bridge| bridge.vtable.createGaugeF64(bridge.meter_ptr, name, description, unit),
        };
    }

    /// Clean up meter resources
    pub fn deinit(self: *Meter) void {
        switch (self.*) {
            .noop => |*meter| meter.deinit(),
            .sdk => |*bridge| bridge.vtable.deinit(bridge.meter_ptr),
        }
    }
};

/// No-operation meter implementation
pub const NoopMeter = struct {
    scope: InstrumentationScope,
    allocator: std.mem.Allocator,
    // Track created instruments separately by type for proper cleanup
    counters_i64: std.ArrayList(*Counter(i64)),
    counters_f64: std.ArrayList(*Counter(f64)),
    up_down_counters_i64: std.ArrayList(*UpDownCounter(i64)),
    up_down_counters_f64: std.ArrayList(*UpDownCounter(f64)),
    gauges_i64: std.ArrayList(*Gauge(i64)),
    gauges_f64: std.ArrayList(*Gauge(f64)),

    pub fn init(allocator: std.mem.Allocator, scope: InstrumentationScope) NoopMeter {
        return .{
            .scope = scope,
            .allocator = allocator,
            .counters_i64 = std.ArrayList(*Counter(i64)).init(allocator),
            .counters_f64 = std.ArrayList(*Counter(f64)).init(allocator),
            .up_down_counters_i64 = std.ArrayList(*UpDownCounter(i64)).init(allocator),
            .up_down_counters_f64 = std.ArrayList(*UpDownCounter(f64)).init(allocator),
            .gauges_i64 = std.ArrayList(*Gauge(i64)).init(allocator),
            .gauges_f64 = std.ArrayList(*Gauge(f64)).init(allocator),
        };
    }

    pub fn deinit(self: *NoopMeter) void {
        // Clean up all instruments
        for (self.counters_i64.items) |counter| {
            self.allocator.destroy(counter);
        }
        self.counters_i64.deinit();

        for (self.counters_f64.items) |counter| {
            self.allocator.destroy(counter);
        }
        self.counters_f64.deinit();

        for (self.up_down_counters_i64.items) |counter| {
            self.allocator.destroy(counter);
        }
        self.up_down_counters_i64.deinit();

        for (self.up_down_counters_f64.items) |counter| {
            self.allocator.destroy(counter);
        }
        self.up_down_counters_f64.deinit();

        for (self.gauges_i64.items) |gauge| {
            self.allocator.destroy(gauge);
        }
        self.gauges_i64.deinit();

        for (self.gauges_f64.items) |gauge| {
            self.allocator.destroy(gauge);
        }
        self.gauges_f64.deinit();
    }

    pub fn createCounterI64(
        self: *NoopMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*Counter(i64) {
        const counter = try self.allocator.create(Counter(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = @import("instrument.zig").createNoopCounter(i64, name, description, unit);
        try self.counters_i64.append(counter);

        return counter;
    }

    pub fn createCounterF64(
        self: *NoopMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*Counter(f64) {
        const counter = try self.allocator.create(Counter(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = @import("instrument.zig").createNoopCounter(f64, name, description, unit);
        try self.counters_f64.append(counter);

        return counter;
    }

    pub fn createUpDownCounterI64(
        self: *NoopMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*UpDownCounter(i64) {
        const counter = try self.allocator.create(UpDownCounter(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = @import("instrument.zig").createNoopUpDownCounter(i64, name, description, unit);
        try self.up_down_counters_i64.append(counter);

        return counter;
    }

    pub fn createUpDownCounterF64(
        self: *NoopMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*UpDownCounter(f64) {
        const counter = try self.allocator.create(UpDownCounter(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = @import("instrument.zig").createNoopUpDownCounter(f64, name, description, unit);
        try self.up_down_counters_f64.append(counter);

        return counter;
    }

    pub fn createGaugeI64(
        self: *NoopMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*Gauge(i64) {
        const gauge = try self.allocator.create(Gauge(i64));
        errdefer self.allocator.destroy(gauge);

        gauge.* = @import("instrument.zig").createNoopGauge(i64, name, description, unit);
        try self.gauges_i64.append(gauge);

        return gauge;
    }

    pub fn createGaugeF64(
        self: *NoopMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !*Gauge(f64) {
        const gauge = try self.allocator.create(Gauge(f64));
        errdefer self.allocator.destroy(gauge);

        gauge.* = @import("instrument.zig").createNoopGauge(f64, name, description, unit);
        try self.gauges_f64.append(gauge);

        return gauge;
    }
};

/// Create a no-operation meter
pub fn createNoopMeter(allocator: std.mem.Allocator, scope: InstrumentationScope) Meter {
    return .{ .noop = NoopMeter.init(allocator, scope) };
}

/// Virtual table for SDK meter implementations
pub const SdkMeterVTable = struct {
    getInstrumentationScope: *const fn (meter_ptr: *anyopaque) InstrumentationScope,
    createCounterI64: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*Counter(i64),
    createCounterF64: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*Counter(f64),
    createUpDownCounterI64: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*UpDownCounter(i64),
    createUpDownCounterF64: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*UpDownCounter(f64),
    createGaugeI64: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*Gauge(i64),
    createGaugeF64: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*Gauge(f64),
    deinit: *const fn (meter_ptr: *anyopaque) void,
};

/// Bridge structure that holds SDK meter pointer and vtable
pub const SdkMeterBridge = struct {
    meter_ptr: *anyopaque,
    vtable: SdkMeterVTable,
};

test "NoopMeter basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const scope = try InstrumentationScope.initWithName("test.meter");
    var meter = Meter{ .noop = NoopMeter.init(allocator, scope) };
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

test "Meter instrument creation with different types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const scope = try InstrumentationScope.initWithName("test.meter");
    var meter = Meter{ .noop = NoopMeter.init(allocator, scope) };
    defer meter.deinit();

    // Test with i64
    const i64_counter = try meter.createCounterI64("i64.counter", null, null);
    try testing.expectEqualStrings("i64.counter", i64_counter.getName());

    // Test with f64
    const f64_counter = try meter.createCounterF64("f64.counter", null, null);
    try testing.expectEqualStrings("f64.counter", f64_counter.getName());

    const f64_gauge = try meter.createGaugeF64("f64.gauge", null, null);
    try testing.expectEqualStrings("f64.gauge", f64_gauge.getName());
}