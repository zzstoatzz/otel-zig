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
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;

/// Counter is a monotonic sum instrument
/// T must be a numeric type (i64, f64)
pub fn Counter(comptime T: type) type {
    return union(enum) {
        noop: []const u8,
        bridge: InstrumentBridge,

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |name| name,
                .bridge => |bridge| bridge.getNameFn(bridge.instrument_ptr),
            };
        }

        /// Add a value to the counter
        pub inline fn add(self: *const @This(), ctx: Context, value: T, attributes: []const AttributeKeyValue) void {
            switch (self.*) {
                .noop => {}, // No-op implementation does nothing
                .bridge => |bridge| {
                    switch (T) {
                        i64 => bridge.addI64Fn(bridge.instrument_ptr, ctx, value, attributes),
                        f64 => bridge.addF64Fn(bridge.instrument_ptr, ctx, value, attributes),
                        else => unreachable,
                    }
                },
            }
        }

        /// Convenience method to add without attributes
        pub inline fn addSimple(self: *@This(), ctx: Context, value: T) void {
            self.add(ctx, value, &[_]AttributeKeyValue{});
        }

        /// Check if this instrument is enabled for recording measurements
        pub inline fn enabled(self: *const @This()) bool {
            return switch (self.*) {
                .noop => false,
                .bridge => |bridge| bridge.enabledFn(bridge.instrument_ptr),
            };
        }
    };
}

/// UpDownCounter is a non-monotonic sum instrument
/// T must be a numeric type (i64, f64)
pub fn UpDownCounter(comptime T: type) type {
    return union(enum) {
        noop: []const u8,
        bridge: InstrumentBridge,

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |name| name,
                .bridge => |bridge| bridge.getNameFn(bridge.instrument_ptr),
            };
        }

        /// Add a value to the counter (can be negative)
        pub inline fn add(self: *const @This(), ctx: Context, value: T, attributes: []const AttributeKeyValue) void {
            switch (self.*) {
                .noop => {}, // No-op implementation does nothing
                .bridge => |bridge| {
                    switch (T) {
                        i64 => bridge.addI64Fn(bridge.instrument_ptr, ctx, value, attributes),
                        f64 => bridge.addF64Fn(bridge.instrument_ptr, ctx, value, attributes),
                        else => unreachable,
                    }
                },
            }
        }

        /// Convenience method to add without attributes
        pub inline fn addSimple(self: *@This(), ctx: Context, value: T) void {
            self.add(ctx, value, &[_]AttributeKeyValue{});
        }

        /// Check if this instrument is enabled for recording measurements
        pub inline fn enabled(self: *const @This()) bool {
            return switch (self.*) {
                .noop => false,
                .bridge => |bridge| bridge.enabledFn(bridge.instrument_ptr),
            };
        }
    };
}

/// Gauge records non-additive values (last value wins)
/// T must be a numeric type (i64, f64)
pub fn Gauge(comptime T: type) type {
    return union(enum) {
        noop: []const u8,
        bridge: InstrumentBridge,

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |name| name,
                .bridge => |bridge| bridge.getNameFn(bridge.instrument_ptr),
            };
        }

        /// Record a value
        pub inline fn record(self: *const @This(), ctx: Context, value: T, attributes: []const AttributeKeyValue) void {
            switch (self.*) {
                .noop => {}, // No-op implementation does nothing
                .bridge => |bridge| {
                    switch (T) {
                        i64 => bridge.recordI64Fn(bridge.instrument_ptr, ctx, value, attributes),
                        f64 => bridge.recordF64Fn(bridge.instrument_ptr, ctx, value, attributes),
                        else => unreachable,
                    }
                },
            }
        }

        /// Convenience method to record without attributes
        pub inline fn recordSimple(self: *@This(), ctx: Context, value: T) void {
            self.record(ctx, value, &[_]AttributeKeyValue{});
        }

        /// Check if this instrument is enabled for recording measurements
        pub inline fn enabled(self: *const @This()) bool {
            return switch (self.*) {
                .noop => false,
                .bridge => |bridge| bridge.enabledFn(bridge.instrument_ptr),
            };
        }
    };
}

/// Histogram is a metric instrument that aggregates values into buckets
/// T must be a numeric type (i64, f64)
pub fn Histogram(comptime T: type) type {
    return union(enum) {
        noop: []const u8,
        bridge: InstrumentBridge,

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |name| name,
                .bridge => |bridge| bridge.getNameFn(bridge.instrument_ptr),
            };
        }

        /// Record a value in the histogram
        pub inline fn record(self: *const @This(), ctx: Context, value: T, attributes: []const AttributeKeyValue) void {
            switch (self.*) {
                .noop => {}, // No-op implementation does nothing
                .bridge => |bridge| {
                    switch (T) {
                        i64 => bridge.recordI64Fn(bridge.instrument_ptr, ctx, value, attributes),
                        f64 => bridge.recordF64Fn(bridge.instrument_ptr, ctx, value, attributes),
                        else => unreachable,
                    }
                },
            }
        }

        /// Convenience method to record without attributes
        pub inline fn recordSimple(self: *@This(), ctx: Context, value: T) void {
            self.record(ctx, value, &[_]AttributeKeyValue{});
        }

        /// Check if this instrument is enabled for recording measurements
        pub inline fn enabled(self: *const @This()) bool {
            return switch (self.*) {
                .noop => false,
                .bridge => |bridge| bridge.enabledFn(bridge.instrument_ptr),
            };
        }
    };
}

/// Bridge structure that holds SDK instrument pointer and vtable
pub const InstrumentBridge = struct {
    instrument_ptr: *anyopaque,
    getNameFn: *const fn (instrument_ptr: *anyopaque) []const u8,
    // Separate functions for each type to avoid comptime parameters in function pointers
    addI64Fn: *const fn (instrument_ptr: *anyopaque, ctx: Context, value: i64, attributes: []const AttributeKeyValue) void,
    addF64Fn: *const fn (instrument_ptr: *anyopaque, ctx: Context, value: f64, attributes: []const AttributeKeyValue) void,
    recordI64Fn: *const fn (instrument_ptr: *anyopaque, ctx: Context, value: i64, attributes: []const AttributeKeyValue) void,
    recordF64Fn: *const fn (instrument_ptr: *anyopaque, ctx: Context, value: f64, attributes: []const AttributeKeyValue) void,
    enabledFn: *const fn (instrument_ptr: *anyopaque) bool,

    pub fn init(ptr: anytype) InstrumentBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn getName(pointer: *anyopaque) []const u8 {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getName(self);
            }
            pub fn addI64(pointer: *anyopaque, ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.addI64(self, ctx, value, attributes);
            }
            pub fn addF64(pointer: *anyopaque, ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.addF64(self, ctx, value, attributes);
            }
            pub fn recordI64(pointer: *anyopaque, ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.recordI64(self, ctx, value, attributes);
            }
            pub fn recordF64(pointer: *anyopaque, ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.recordF64(self, ctx, value, attributes);
            }
            pub fn enabled(pointer: *anyopaque) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.enabled(self);
            }
        };

        return .{
            .instrument_ptr = ptr,
            .getNameFn = VTable.getName,
            .addI64Fn = VTable.addI64,
            .addF64Fn = VTable.addF64,
            .recordI64Fn = VTable.recordI64,
            .recordF64Fn = VTable.recordF64,
            .enabledFn = VTable.enabled,
        };
    }
};

test "instrument enabled method" {
    const testing = std.testing;

    // Test noop Counter returns false
    var noop_counter = Counter(i64){ .noop = "test" };
    try testing.expect(!noop_counter.enabled());

    // Test noop UpDownCounter returns false
    var noop_updown = UpDownCounter(i64){ .noop = "test" };
    try testing.expect(!noop_updown.enabled());

    // Test noop Gauge returns false
    var noop_gauge = Gauge(i64){ .noop = "test" };
    try testing.expect(!noop_gauge.enabled());

    // Test noop Histogram returns false
    var noop_histogram = Histogram(i64){ .noop = "test" };
    try testing.expect(!noop_histogram.enabled());
}

test "instrument enabled method can be called multiple times" {
    const testing = std.testing;

    // Test that method can be called multiple times (spec requirement)
    var noop_counter = Counter(i64){ .noop = "test" };
    try testing.expect(!noop_counter.enabled());
    try testing.expect(!noop_counter.enabled());
    try testing.expect(!noop_counter.enabled());
}
