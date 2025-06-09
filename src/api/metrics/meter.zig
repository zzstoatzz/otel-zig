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
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
const Context = @import("../context/root.zig").Context;

// Forward declarations for instruments
const Counter = @import("instrument.zig").Counter;
const UpDownCounter = @import("instrument.zig").UpDownCounter;
const Gauge = @import("instrument.zig").Gauge;

/// Meter interface using tagged union for polymorphism
pub const Meter = union(enum) {
    noop: InstrumentationScope,
    bridge: MeterBridge,

    /// Create a Counter instrument for i64 values
    pub inline fn createCounter(
        self: *Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !Counter(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("Counters must be of type i64 or f64"),
        };
        return switch (self.*) {
            .noop => |_| Counter(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createCounterI64Fn(bridge.meter_ptr, name, description, unit),
                f64 => bridge.createCounterF64Fn(bridge.meter_ptr, name, description, unit),
                else => unreachable,
            },
        };
    }

    /// Create an UpDownCounter instrument for i64 values
    pub inline fn createUpDownCounter(
        self: *Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !UpDownCounter(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("UpDownCounters must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => |_| UpDownCounter(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createUpDownCounterI64Fn(bridge.meter_ptr, name, description, unit),
                f64 => bridge.createUpDownCounterF64Fn(bridge.meter_ptr, name, description, unit),
                else => unreachable,
            },
        };
    }

    /// Create a Gauge instrument for i64 values
    pub inline fn createGauge(
        self: *Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !Gauge(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("Gauges must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => |_| Gauge(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createGaugeI64Fn(bridge.meter_ptr, name, description, unit),
                f64 => bridge.createGaugeF64Fn(bridge.meter_ptr, name, description, unit),
                else => unreachable,
            },
        };
    }

    /// Clean up meter resources
    pub fn deinit(self: *Meter) void {
        switch (self.*) {
            .noop => |_| {},
            .sdk => |*bridge| bridge.deinitFn(bridge.meter_ptr),
        }
    }
};

/// Bridge structure that holds SDK meter pointer and vtable
pub const MeterBridge = struct {
    meter_ptr: *anyopaque,
    createCounterI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!Counter(i64),
    createCounterF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!Counter(f64),
    createUpDownCounterI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!UpDownCounter(i64),
    createUpDownCounterF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!UpDownCounter(f64),
    createGaugeI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!Gauge(i64),
    createGaugeF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!Gauge(f64),
    deinitFn: *const fn (meter_ptr: *anyopaque) void,

    pub fn init(ptr: anytype) MeterBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn createCounterF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!Counter(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createCounterF64(self, name, description, unit);
            }
            pub fn createCounterI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!Counter(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createCounterI64(self, name, description, unit);
            }
            pub fn createUpDownCounterF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!UpDownCounter(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createUpDownCounterF64(self, name, description, unit);
            }
            pub fn createUpDownCounterI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!UpDownCounter(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createUpDownCounterI64(self, name, description, unit);
            }
            pub fn createGaugeF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!Gauge(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createGaugeF64(self, name, description, unit);
            }
            pub fn createGaugeI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!Gauge(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createGaugeI64(self, name, description, unit);
            }
            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.deinit(self);
            }
        };

        return .{
            .meter_ptr = ptr,
            .createCounterI64Fn = VTable.createCounterI64,
            .createCounterF64Fn = VTable.createCounterF64,
            .createUpDownCounterI64Fn = VTable.createUpDownCounterI64,
            .createUpDownCounterF64Fn = VTable.createUpDownCounterF64,
            .createGaugeI64Fn = VTable.createGaugeI64,
            .createGaugeF64Fn = VTable.createGaugeF64,
            .deinitFn = VTable.deinit,
        };
    }
};
