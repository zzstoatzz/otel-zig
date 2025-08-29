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
const api = struct {
    const ContextKeyValue = @import("../context/context.zig").ContextKeyValue;
    const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
};

/// Advisory parameters for instrument creation
/// These are optional recommendations that implementations MAY use or ignore
pub const AdvisoryParams = struct {
    /// Recommended bucket boundaries for Histogram instruments (Stable)
    explicit_bucket_boundaries: ?[]const f64 = null,

    /// Recommended attribute keys to be used for the resulting metrics (Development)
    attributes: ?[]const []const u8 = null,
};

/// Instrument type enumeration
pub const InstrumentType = enum {
    Counter,
    UpDownCounter,
    Histogram,
    Gauge,
    ObservableCounter,
    ObservableUpDownCounter,
    ObservableGauge,
};

const BaseType = enum {
    float,
    int,
};

fn Instrument(comptime inst_type: InstrumentType, comptime base_type: BaseType) type {
    switch (inst_type) {
        .ObservableCounter, .ObservableGauge, .ObservableUpDownCounter => @compileError("Attempt to create a Non-Observable Instrument of Obsevable type."),
        else => {},
    }
    const ValueType = switch (base_type) {
        .float => f64,
        .int => i64,
    };

    return switch (inst_type) {
        .Counter, .UpDownCounter => blk: {
            const BridgeType = struct {
                const Self = @This();
                instrument_ptr: *anyopaque,
                getNameFn: *const fn (instrument_ptr: *anyopaque) []const u8,
                addFn: *const fn (instrument_ptr: *anyopaque, ctx: []const api.ContextKeyValue, value: ValueType, attributes: []const api.AttributeKeyValue) void,
                enabledFn: *const fn (instrument_ptr: *anyopaque) bool,

                pub fn init(ptr: anytype) Self {
                    const T = @TypeOf(ptr);
                    const ptr_info = @typeInfo(T);

                    const VTable = struct {
                        pub fn getName(pointer: *anyopaque) []const u8 {
                            const self: T = @ptrCast(@alignCast(pointer));
                            return ptr_info.pointer.child.getName(self);
                        }
                        pub fn add(pointer: *anyopaque, ctx: []const api.ContextKeyValue, value: ValueType, attributes: []const api.AttributeKeyValue) void {
                            const self: T = @ptrCast(@alignCast(pointer));
                            return ptr_info.pointer.child.add(self, ctx, value, attributes);
                        }
                        pub fn enabled(pointer: *anyopaque) bool {
                            const self: T = @ptrCast(@alignCast(pointer));
                            return ptr_info.pointer.child.enabled(self);
                        }
                    };

                    return .{
                        .instrument_ptr = ptr,
                        .getNameFn = VTable.getName,
                        .addFn = VTable.add,
                        .enabledFn = VTable.enabled,
                    };
                }
            };

            break :blk union(enum) {
                const Self = @This();
                pub const Bridge = BridgeType;
                noop: []const u8,
                bridge: Bridge,
                pub inline fn getName(self: Self) []const u8 {
                    return switch (self) {
                        .noop => |name| name,
                        .bridge => |bridge| bridge.getNameFn(bridge.instrument_ptr),
                    };
                }

                pub inline fn add(self: Self, ctx: []const api.ContextKeyValue, value: ValueType, attributes: []const api.AttributeKeyValue) void {
                    switch (self) {
                        .noop => {},
                        .bridge => |bridge| bridge.addFn(bridge.instrument_ptr, ctx, value, attributes),
                    }
                }

                pub inline fn addSimple(self: Self, value: ValueType) void {
                    self.add(&.{}, value, &.{});
                }

                pub inline fn enabled(self: Self) bool {
                    return switch (self) {
                        .noop => false,
                        .bridge => |bridge| bridge.enabledFn(bridge.instrument_ptr),
                    };
                }
            };
        },
        .Gauge, .Histogram => blk: {
            const BridgeType = struct {
                const Self = @This();
                instrument_ptr: *anyopaque,
                getNameFn: *const fn (instrument_ptr: *anyopaque) []const u8,
                // Separate functions for each type to avoid comptime parameters in function pointers
                recordFn: *const fn (instrument_ptr: *anyopaque, ctx: []const api.ContextKeyValue, value: ValueType, attributes: []const api.AttributeKeyValue) void,
                enabledFn: *const fn (instrument_ptr: *anyopaque) bool,

                pub fn init(ptr: anytype) Self {
                    const T = @TypeOf(ptr);
                    const ptr_info = @typeInfo(T);

                    const VTable = struct {
                        pub fn getName(pointer: *anyopaque) []const u8 {
                            const self: T = @ptrCast(@alignCast(pointer));
                            return ptr_info.pointer.child.getName(self);
                        }
                        pub fn record(pointer: *anyopaque, ctx: []const api.ContextKeyValue, value: ValueType, attributes: []const api.AttributeKeyValue) void {
                            const self: T = @ptrCast(@alignCast(pointer));
                            return ptr_info.pointer.child.record(self, ctx, value, attributes);
                        }
                        pub fn enabled(pointer: *anyopaque) bool {
                            const self: T = @ptrCast(@alignCast(pointer));
                            return ptr_info.pointer.child.enabled(self);
                        }
                    };

                    return .{
                        .instrument_ptr = ptr,
                        .getNameFn = VTable.getName,
                        .recordFn = VTable.record,
                        .enabledFn = VTable.enabled,
                    };
                }
            };
            break :blk union(enum) {
                const Self = @This();
                pub const Bridge = BridgeType;
                noop: []const u8,
                bridge: Bridge,
                pub inline fn getName(self: Self) []const u8 {
                    return switch (self) {
                        .noop => |name| name,
                        .bridge => |bridge| bridge.getNameFn(bridge.instrument_ptr),
                    };
                }

                pub inline fn record(self: Self, ctx: []const api.ContextKeyValue, value: ValueType, attributes: []const api.AttributeKeyValue) void {
                    switch (self) {
                        .noop => {},
                        .bridge => |bridge| bridge.recordFn(bridge.instrument_ptr, ctx, value, attributes),
                    }
                }

                pub inline fn recordSimple(self: Self, value: ValueType) void {
                    self.record(&.{}, value, &.{});
                }

                pub inline fn enabled(self: Self) bool {
                    return switch (self) {
                        .noop => false,
                        .bridge => |bridge| bridge.enabledFn(bridge.instrument_ptr),
                    };
                }
            };
        },
        else => unreachable,
    };
}

pub fn Counter(comptime value_type: type) type {
    const Base = switch (value_type) {
        i64 => BaseType.int,
        f64 => BaseType.float,
        else => unreachable,
    };
    return Instrument(.Counter, Base);
}

pub fn UpDownCounter(comptime value_type: type) type {
    const Base = switch (value_type) {
        i64 => BaseType.int,
        f64 => BaseType.float,
        else => unreachable,
    };
    return Instrument(.UpDownCounter, Base);
}

pub fn Gauge(comptime value_type: type) type {
    const Base = switch (value_type) {
        i64 => BaseType.int,
        f64 => BaseType.float,
        else => unreachable,
    };
    return Instrument(.Gauge, Base);
}

pub fn Histogram(comptime value_type: type) type {
    const Base = switch (value_type) {
        i64 => BaseType.int,
        f64 => BaseType.float,
        else => unreachable,
    };
    return Instrument(.Histogram, Base);
}

test "instrument enabled and int add types." {
    const testing = std.testing;

    // Test noop Counter returns false
    const noop_counter = Instrument(.Counter, .int){ .noop = "test" };
    noop_counter.addSimple(@as(i64, 1));
    try testing.expect(!noop_counter.enabled());

    // Test noop UpDownCounter returns false
    const noop_updown = Instrument(.UpDownCounter, .int){ .noop = "test" };
    noop_updown.addSimple(@as(i64, 1));
    try testing.expect(!noop_updown.enabled());

    // Test noop Gauge returns false
    const noop_gauge = Instrument(.Gauge, .int){ .noop = "test" };
    noop_gauge.recordSimple(@as(i64, 1));
    try testing.expect(!noop_gauge.enabled());

    // Test noop Histogram returns false
    const noop_histogram = Instrument(.Histogram, .int){ .noop = "test" };
    noop_gauge.recordSimple(@as(i64, 1));
    try testing.expect(!noop_histogram.enabled());
}

test "instrument enabled and float add types." {
    const testing = std.testing;

    // Test noop Counter returns false
    const noop_counter = Instrument(.Counter, .float){ .noop = "test" };
    noop_counter.addSimple(@as(i64, 1));
    try testing.expect(!noop_counter.enabled());

    // Test noop UpDownCounter returns false
    const noop_updown = Instrument(.UpDownCounter, .float){ .noop = "test" };
    noop_updown.addSimple(@as(i64, 1));
    try testing.expect(!noop_updown.enabled());

    // Test noop Gauge returns false
    const noop_gauge = Instrument(.Gauge, .float){ .noop = "test" };
    noop_gauge.recordSimple(@as(i64, 1));
    try testing.expect(!noop_gauge.enabled());

    // Test noop Histogram returns false
    const noop_histogram = Instrument(.Histogram, .float){ .noop = "test" };
    noop_gauge.recordSimple(@as(i64, 1));
    try testing.expect(!noop_histogram.enabled());
}
