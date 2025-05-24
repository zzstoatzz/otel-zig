//! Meter Bridge for SDK/API Integration
//!
//! This module provides the bridge implementation that allows SDK meters
//! to be used through the API meter interface.

const std = @import("std");
const otel_api = @import("otel-api");

const Meter = otel_api.metrics.Meter;
const Counter = otel_api.metrics.Counter;
const UpDownCounter = otel_api.metrics.UpDownCounter;
const Gauge = otel_api.metrics.Gauge;
const SdkMeterBridge = otel_api.metrics.SdkMeterBridge;
const SdkMeterVTable = otel_api.metrics.SdkMeterVTable;
const SdkInstrumentBridge = otel_api.metrics.SdkInstrumentBridge;
const SdkInstrumentVTable = otel_api.metrics.SdkInstrumentVTable;
const InstrumentationScope = otel_api.InstrumentationScope;
const Context = otel_api.Context;
const KeyValue = otel_api.KeyValue;

const StandardMeter = @import("../metrics/meter.zig").StandardMeter;
const StandardCounter = @import("../metrics/instruments.zig").StandardCounter;
const StandardUpDownCounter = @import("../metrics/instruments.zig").StandardUpDownCounter;
const StandardGauge = @import("../metrics/instruments.zig").StandardGauge;

/// Wrap a StandardMeter for use with the API
pub fn wrapStandardMeter(allocator: std.mem.Allocator, meter: *StandardMeter) !*Meter {
    const api_meter = try allocator.create(Meter);
    api_meter.* = .{
        .sdk = SdkMeterBridge{
            .meter_ptr = meter,
            .vtable = standardMeterVTable,
        },
    };
    return api_meter;
}

/// VTable implementation for StandardMeter
const standardMeterVTable = SdkMeterVTable{
    .getInstrumentationScope = standardMeterGetInstrumentationScope,
    .createCounterI64 = standardMeterCreateCounterI64,
    .createCounterF64 = standardMeterCreateCounterF64,
    .createUpDownCounterI64 = standardMeterCreateUpDownCounterI64,
    .createUpDownCounterF64 = standardMeterCreateUpDownCounterF64,
    .createGaugeI64 = standardMeterCreateGaugeI64,
    .createGaugeF64 = standardMeterCreateGaugeF64,
    .deinit = standardMeterDeinit,
};

fn standardMeterGetInstrumentationScope(meter_ptr: *anyopaque) InstrumentationScope {
    const meter = @as(*StandardMeter, @ptrCast(@alignCast(meter_ptr)));
    return meter.getInstrumentationScope();
}

fn standardMeterCreateCounterI64(meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*Counter(i64) {
    const meter = @as(*StandardMeter, @ptrCast(@alignCast(meter_ptr)));
    return meter.createCounterI64(name, description, unit);
}

fn standardMeterCreateCounterF64(meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*Counter(f64) {
    const meter = @as(*StandardMeter, @ptrCast(@alignCast(meter_ptr)));
    return meter.createCounterF64(name, description, unit);
}

fn standardMeterCreateUpDownCounterI64(meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*UpDownCounter(i64) {
    const meter = @as(*StandardMeter, @ptrCast(@alignCast(meter_ptr)));
    return meter.createUpDownCounterI64(name, description, unit);
}

fn standardMeterCreateUpDownCounterF64(meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*UpDownCounter(f64) {
    const meter = @as(*StandardMeter, @ptrCast(@alignCast(meter_ptr)));
    return meter.createUpDownCounterF64(name, description, unit);
}

fn standardMeterCreateGaugeI64(meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*Gauge(i64) {
    const meter = @as(*StandardMeter, @ptrCast(@alignCast(meter_ptr)));
    return meter.createGaugeI64(name, description, unit);
}

fn standardMeterCreateGaugeF64(meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!*Gauge(f64) {
    const meter = @as(*StandardMeter, @ptrCast(@alignCast(meter_ptr)));
    return meter.createGaugeF64(name, description, unit);
}

fn standardMeterDeinit(meter_ptr: *anyopaque) void {
    // No-op: SDK meter will be cleaned up by the provider
    _ = meter_ptr;
}

// Counter wrappers

/// Wrap a StandardCounter for use with the API
pub fn wrapStandardCounter(comptime T: type, allocator: std.mem.Allocator, counter: *StandardCounter(T)) !*Counter(T) {
    const api_counter = try allocator.create(Counter(T));
    api_counter.* = .{
        .sdk = SdkInstrumentBridge{
            .instrument_ptr = counter,
            .vtable = standardCounterVTable,
        },
    };
    return api_counter;
}

/// VTable implementation for StandardCounter
const standardCounterVTable = SdkInstrumentVTable{
    .getName = standardInstrumentGetName,
    .addI64 = standardCounterAddI64,
    .addF64 = standardCounterAddF64,
    .addU64 = standardCounterAddU64,
    .recordI64 = notImplementedI64,
    .recordF64 = notImplementedF64,
    .recordU64 = notImplementedU64,
};

fn standardCounterAddI64(instrument_ptr: *anyopaque, ctx: Context, value: i64, attributes: []const KeyValue) void {
    const counter = @as(*StandardCounter(i64), @ptrCast(@alignCast(instrument_ptr)));
    counter.add(ctx, value, attributes);
}

fn standardCounterAddF64(instrument_ptr: *anyopaque, ctx: Context, value: f64, attributes: []const KeyValue) void {
    const counter = @as(*StandardCounter(f64), @ptrCast(@alignCast(instrument_ptr)));
    counter.add(ctx, value, attributes);
}

fn standardCounterAddU64(instrument_ptr: *anyopaque, ctx: Context, value: u64, attributes: []const KeyValue) void {
    const counter = @as(*StandardCounter(u64), @ptrCast(@alignCast(instrument_ptr)));
    counter.add(ctx, @intCast(counter.aggregation.value + value), attributes);
}

// UpDownCounter wrappers

/// Wrap a StandardUpDownCounter for use with the API
pub fn wrapStandardUpDownCounter(comptime T: type, allocator: std.mem.Allocator, counter: *StandardUpDownCounter(T)) !*UpDownCounter(T) {
    const api_counter = try allocator.create(UpDownCounter(T));
    api_counter.* = .{
        .sdk = SdkInstrumentBridge{
            .instrument_ptr = counter,
            .vtable = standardUpDownCounterVTable,
        },
    };
    return api_counter;
}

/// VTable implementation for StandardUpDownCounter
const standardUpDownCounterVTable = SdkInstrumentVTable{
    .getName = standardInstrumentGetName,
    .addI64 = standardUpDownCounterAddI64,
    .addF64 = standardUpDownCounterAddF64,
    .addU64 = notImplementedU64,
    .recordI64 = notImplementedI64,
    .recordF64 = notImplementedF64,
    .recordU64 = notImplementedU64,
};

fn standardUpDownCounterAddI64(instrument_ptr: *anyopaque, ctx: Context, value: i64, attributes: []const KeyValue) void {
    const counter = @as(*StandardUpDownCounter(i64), @ptrCast(@alignCast(instrument_ptr)));
    counter.add(ctx, value, attributes);
}

fn standardUpDownCounterAddF64(instrument_ptr: *anyopaque, ctx: Context, value: f64, attributes: []const KeyValue) void {
    const counter = @as(*StandardUpDownCounter(f64), @ptrCast(@alignCast(instrument_ptr)));
    counter.add(ctx, value, attributes);
}

// Gauge wrappers

/// Wrap a StandardGauge for use with the API
pub fn wrapStandardGauge(comptime T: type, allocator: std.mem.Allocator, gauge: *StandardGauge(T)) !*Gauge(T) {
    const api_gauge = try allocator.create(Gauge(T));
    api_gauge.* = .{
        .sdk = SdkInstrumentBridge{
            .instrument_ptr = gauge,
            .vtable = standardGaugeVTable,
        },
    };
    return api_gauge;
}

/// VTable implementation for StandardGauge
const standardGaugeVTable = SdkInstrumentVTable{
    .getName = standardInstrumentGetName,
    .addI64 = notImplementedI64,
    .addF64 = notImplementedF64,
    .addU64 = notImplementedU64,
    .recordI64 = standardGaugeRecordI64,
    .recordF64 = standardGaugeRecordF64,
    .recordU64 = standardGaugeRecordU64,
};

fn standardGaugeRecordI64(instrument_ptr: *anyopaque, ctx: Context, value: i64, attributes: []const KeyValue) void {
    const gauge = @as(*StandardGauge(i64), @ptrCast(@alignCast(instrument_ptr)));
    gauge.record(ctx, value, attributes);
}

fn standardGaugeRecordF64(instrument_ptr: *anyopaque, ctx: Context, value: f64, attributes: []const KeyValue) void {
    const gauge = @as(*StandardGauge(f64), @ptrCast(@alignCast(instrument_ptr)));
    gauge.record(ctx, value, attributes);
}

fn standardGaugeRecordU64(instrument_ptr: *anyopaque, ctx: Context, value: u64, attributes: []const KeyValue) void {
    const gauge = @as(*StandardGauge(u64), @ptrCast(@alignCast(instrument_ptr)));
    gauge.record(ctx, value, attributes);
}

// Common helpers

fn standardInstrumentGetName(instrument_ptr: *anyopaque) []const u8 {
    // This works because all instruments have getName() at the same offset
    const instrument = @as(*const struct { 
        allocator: std.mem.Allocator,
        name: []const u8,
    }, @ptrCast(@alignCast(instrument_ptr)));
    return instrument.name;
}

fn notImplementedI64(instrument_ptr: *anyopaque, ctx: Context, value: i64, attributes: []const KeyValue) void {
    _ = instrument_ptr;
    _ = ctx;
    _ = value;
    _ = attributes;
    unreachable; // This should never be called
}

fn notImplementedF64(instrument_ptr: *anyopaque, ctx: Context, value: f64, attributes: []const KeyValue) void {
    _ = instrument_ptr;
    _ = ctx;
    _ = value;
    _ = attributes;
    unreachable; // This should never be called
}

fn notImplementedU64(instrument_ptr: *anyopaque, ctx: Context, value: u64, attributes: []const KeyValue) void {
    _ = instrument_ptr;
    _ = ctx;
    _ = value;
    _ = attributes;
    unreachable; // This should never be called
}

// Tests

test "wrapStandardMeter" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);
    
    const scope = try InstrumentationScope.initWithName("test.meter");
    var sdk_meter = try StandardMeter.init(allocator, scope, &resource);
    defer sdk_meter.deinit();
    
    const api_meter = try wrapStandardMeter(allocator, &sdk_meter);
    defer allocator.destroy(api_meter);
    
    // Verify it's an SDK meter
    try testing.expect(api_meter.* == .sdk);
    
    // Test getting instrumentation scope
    const meter_scope = api_meter.getInstrumentationScope();
    try testing.expectEqualStrings("test.meter", meter_scope.name);
}

test "wrapped counter operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);
    
    const scope = try InstrumentationScope.initWithName("test");
    var counter = try StandardCounter(i64).init(
        allocator,
        "test.counter",
        "Test counter",
        "1",
        scope,
        &resource,
    );
    defer counter.deinit();
    
    const api_counter = try wrapStandardCounter(i64, allocator, &counter);
    defer allocator.destroy(api_counter);
    
    // Verify it's an SDK counter
    try testing.expect(api_counter.* == .sdk);
    
    // Test operations
    const ctx = Context.empty(allocator);
    const attrs = [_]KeyValue{};
    
    api_counter.add(ctx, 10, &attrs);
    api_counter.addSimple(ctx, 5);
    
    try testing.expectEqual(@as(i64, 15), counter.getValue());
}