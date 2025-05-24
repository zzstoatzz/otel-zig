//! OpenTelemetry Metric Instruments API
//!
//! This module defines the metric instrument types: Counter, UpDownCounter, and Gauge.
//! These instruments are used to record measurements that are aggregated by the SDK.
//!
//! The API provides only the interface and no-op implementations. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/api.md#instrument

const std = @import("std");

// Import from relative paths
const Context = @import("../context/root.zig").Context;
const KeyValue = @import("../common/root.zig").KeyValue;

/// Counter is a monotonic sum instrument
/// T must be a numeric type (i64, u64, f64)
pub fn Counter(comptime T: type) type {
    return union(enum) {
        noop: NoopCounter(T),
        sdk: SdkInstrumentBridge,

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |counter| counter.name,
                .sdk => |bridge| bridge.vtable.getName(bridge.instrument_ptr),
            };
        }

        /// Add a value to the counter
        pub inline fn add(self: *@This(), ctx: Context, value: T, attributes: []const KeyValue) void {
            switch (self.*) {
                .noop => {},  // No-op implementation does nothing
                .sdk => |bridge| {
                    if (T == i64) {
                        bridge.vtable.addI64(bridge.instrument_ptr, ctx, value, attributes);
                    } else if (T == f64) {
                        bridge.vtable.addF64(bridge.instrument_ptr, ctx, value, attributes);
                    } else if (T == u64) {
                        bridge.vtable.addU64(bridge.instrument_ptr, ctx, value, attributes);
                    }
                },
            }
        }

        /// Convenience method to add without attributes
        pub inline fn addSimple(self: *@This(), ctx: Context, value: T) void {
            self.add(ctx, value, &[_]KeyValue{});
        }
    };
}

/// UpDownCounter is a non-monotonic sum instrument
/// T must be a numeric type (i64, f64)
pub fn UpDownCounter(comptime T: type) type {
    return union(enum) {
        noop: NoopUpDownCounter(T),
        sdk: SdkInstrumentBridge,

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |counter| counter.name,
                .sdk => |bridge| bridge.vtable.getName(bridge.instrument_ptr),
            };
        }

        /// Add a value to the counter (can be negative)
        pub inline fn add(self: *@This(), ctx: Context, value: T, attributes: []const KeyValue) void {
            switch (self.*) {
                .noop => {},  // No-op implementation does nothing
                .sdk => |bridge| {
                    if (T == i64) {
                        bridge.vtable.addI64(bridge.instrument_ptr, ctx, value, attributes);
                    } else if (T == f64) {
                        bridge.vtable.addF64(bridge.instrument_ptr, ctx, value, attributes);
                    }
                },
            }
        }

        /// Convenience method to add without attributes
        pub inline fn addSimple(self: *@This(), ctx: Context, value: T) void {
            self.add(ctx, value, &[_]KeyValue{});
        }
    };
}

/// Gauge records non-additive values (last value wins)
/// T must be a numeric type (i64, u64, f64)
pub fn Gauge(comptime T: type) type {
    return union(enum) {
        noop: NoopGauge(T),
        sdk: SdkInstrumentBridge,

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |gauge| gauge.name,
                .sdk => |bridge| bridge.vtable.getName(bridge.instrument_ptr),
            };
        }

        /// Record a value
        pub inline fn record(self: *@This(), ctx: Context, value: T, attributes: []const KeyValue) void {
            switch (self.*) {
                .noop => {},  // No-op implementation does nothing
                .sdk => |bridge| {
                    if (T == i64) {
                        bridge.vtable.recordI64(bridge.instrument_ptr, ctx, value, attributes);
                    } else if (T == f64) {
                        bridge.vtable.recordF64(bridge.instrument_ptr, ctx, value, attributes);
                    } else if (T == u64) {
                        bridge.vtable.recordU64(bridge.instrument_ptr, ctx, value, attributes);
                    }
                },
            }
        }

        /// Convenience method to record without attributes
        pub inline fn recordSimple(self: *@This(), ctx: Context, value: T) void {
            self.record(ctx, value, &[_]KeyValue{});
        }
    };
}

/// No-op Counter implementation
fn NoopCounter(comptime T: type) type {
    _ = T; // Mark as used
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    };
}

/// No-op UpDownCounter implementation
fn NoopUpDownCounter(comptime T: type) type {
    _ = T; // Mark as used
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    };
}

/// No-op Gauge implementation
fn NoopGauge(comptime T: type) type {
    _ = T; // Mark as used
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    };
}

/// Virtual table for SDK instrument implementations
pub const SdkInstrumentVTable = struct {
    getName: *const fn (instrument_ptr: *anyopaque) []const u8,
    // Separate functions for each type to avoid comptime parameters in function pointers
    addI64: *const fn (instrument_ptr: *anyopaque, ctx: Context, value: i64, attributes: []const KeyValue) void,
    addF64: *const fn (instrument_ptr: *anyopaque, ctx: Context, value: f64, attributes: []const KeyValue) void,
    addU64: *const fn (instrument_ptr: *anyopaque, ctx: Context, value: u64, attributes: []const KeyValue) void,
    recordI64: *const fn (instrument_ptr: *anyopaque, ctx: Context, value: i64, attributes: []const KeyValue) void,
    recordF64: *const fn (instrument_ptr: *anyopaque, ctx: Context, value: f64, attributes: []const KeyValue) void,
    recordU64: *const fn (instrument_ptr: *anyopaque, ctx: Context, value: u64, attributes: []const KeyValue) void,
};

/// Bridge structure that holds SDK instrument pointer and vtable
pub const SdkInstrumentBridge = struct {
    instrument_ptr: *anyopaque,
    vtable: SdkInstrumentVTable,
};

/// Create a no-op counter
pub fn createNoopCounter(comptime T: type, name: []const u8, description: ?[]const u8, unit: ?[]const u8) Counter(T) {
    return .{ .noop = .{
        .name = name,
        .description = description,
        .unit = unit,
    } };
}

/// Create a no-op up-down counter
pub fn createNoopUpDownCounter(comptime T: type, name: []const u8, description: ?[]const u8, unit: ?[]const u8) UpDownCounter(T) {
    return .{ .noop = .{
        .name = name,
        .description = description,
        .unit = unit,
    } };
}

/// Create a no-op gauge
pub fn createNoopGauge(comptime T: type, name: []const u8, description: ?[]const u8, unit: ?[]const u8) Gauge(T) {
    return .{ .noop = .{
        .name = name,
        .description = description,
        .unit = unit,
    } };
}

// Tests

test "Counter operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var counter = createNoopCounter(i64, "test.counter", "A test counter", "1");
    try testing.expectEqualStrings("test.counter", counter.getName());

    const ctx = Context.empty(allocator);
    const attrs = [_]KeyValue{
        KeyValue.init("key1", .{ .string = "value1" }),
    };

    // These should not crash (no-op)
    counter.add(ctx, 10, &attrs);
    counter.addSimple(ctx, 5);
}

test "UpDownCounter operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var counter = createNoopUpDownCounter(f64, "test.updown", "A test up-down counter", "ms");
    try testing.expectEqualStrings("test.updown", counter.getName());

    const ctx = Context.empty(allocator);
    const attrs = [_]KeyValue{
        KeyValue.init("key1", .{ .string = "value1" }),
    };

    // These should not crash (no-op)
    counter.add(ctx, 10.5, &attrs);
    counter.add(ctx, -5.2, &attrs);  // Can be negative
    counter.addSimple(ctx, 3.14);
}

test "Gauge operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var gauge = createNoopGauge(f64, "test.gauge", "A test gauge", "°C");
    try testing.expectEqualStrings("test.gauge", gauge.getName());

    const ctx = Context.empty(allocator);
    const attrs = [_]KeyValue{
        KeyValue.init("location", .{ .string = "room1" }),
    };

    // These should not crash (no-op)
    gauge.record(ctx, 23.5, &attrs);
    gauge.recordSimple(ctx, 24.1);
}

test "Instruments with different numeric types" {
    const testing = std.testing;

    // Test different numeric types compile correctly
    const i64_counter = createNoopCounter(i64, "i64.counter", null, null);
    const u64_counter = createNoopCounter(u64, "u64.counter", null, null);
    const f64_counter = createNoopCounter(f64, "f64.counter", null, null);

    const i64_updown = createNoopUpDownCounter(i64, "i64.updown", null, null);
    const f64_updown = createNoopUpDownCounter(f64, "f64.updown", null, null);

    const i64_gauge = createNoopGauge(i64, "i64.gauge", null, null);
    const u64_gauge = createNoopGauge(u64, "u64.gauge", null, null);
    const f64_gauge = createNoopGauge(f64, "f64.gauge", null, null);

    // Verify names
    try testing.expectEqualStrings("i64.counter", i64_counter.getName());
    try testing.expectEqualStrings("u64.counter", u64_counter.getName());
    try testing.expectEqualStrings("f64.counter", f64_counter.getName());
    try testing.expectEqualStrings("i64.updown", i64_updown.getName());
    try testing.expectEqualStrings("f64.updown", f64_updown.getName());
    try testing.expectEqualStrings("i64.gauge", i64_gauge.getName());
    try testing.expectEqualStrings("u64.gauge", u64_gauge.getName());
    try testing.expectEqualStrings("f64.gauge", f64_gauge.getName());
}