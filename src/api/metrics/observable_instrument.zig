//! OpenTelemetry Observable/Async Metric Instruments API
//!
//! This module defines the observable metric instrument types and callback mechanisms.
//! Observable instruments use callbacks to collect measurements at collection time,
//! rather than recording measurements synchronously.
//!
//! The API provides interfaces for:
//! - Observable instruments (ObservableCounter, ObservableGauge, ObservableUpDownCounter)
//! - Callback registration and management
//! - Measurement collection interfaces
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/api.md#asynchronous-instrument-api

const std = @import("std");

// Import from relative paths
const Context = @import("../context/root.zig").Context;
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;

/// Callback function type for observable instruments with state
/// StateType: The type of state passed to the callback
/// T: The value type (i64 or f64)
pub fn ObservableCallback(comptime T: type, comptime StateType: type) type {
    return *const fn (result: *ObservableResult(T), state: *StateType) void;
}

/// Callback function type for observable instruments without state
/// T: The value type (i64 or f64)
pub fn ObservableCallbackNoState(comptime T: type) type {
    return *const fn (result: *ObservableResult(T)) void;
}

/// Type-erased callback for internal storage
pub const TypeErasedCallback = struct {
    callback_fn: *const fn (result_ptr: *anyopaque, state: ?*anyopaque) void,
    state: ?*anyopaque,
    has_state: bool,
};

/// Observable result interface for recording measurements from callbacks
pub fn ObservableResult(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Single measurement with value, attributes, and timestamp
        pub const Measurement = struct {
            value: T,
            attributes: []const AttributeKeyValue,
            timestamp: ?i64, // nanoseconds since epoch, null for current time
        };

        measurements: std.ArrayList(Measurement),
        timestamp: ?i64, // default timestamp for measurements

        /// Initialize a new ObservableResult
        pub fn init(allocator: std.mem.Allocator, timestamp: ?i64) Self {
            return Self{
                .measurements = std.ArrayList(Measurement).init(allocator),
                .timestamp = timestamp,
            };
        }

        /// Record a measurement with attributes and optional timestamp
        pub fn observe(
            self: *Self,
            value: T,
            attributes: []const AttributeKeyValue,
            timestamp: ?i64,
        ) !void {
            try self.measurements.append(Measurement{
                .value = value,
                .attributes = attributes,
                .timestamp = timestamp orelse self.timestamp,
            });
        }

        /// Record a measurement with default timestamp
        pub fn observeSimple(self: *Self, value: T, attributes: []const AttributeKeyValue) !void {
            try self.observe(value, attributes, null);
        }

        /// Record a measurement without attributes
        pub fn observeValue(self: *Self, value: T) !void {
            try self.observe(value, &[_]AttributeKeyValue{}, null);
        }

        /// Deinitialize the result
        pub fn deinit(self: *Self) void {
            self.measurements.deinit();
        }
    };
}

/// Observable Counter instrument - monotonic, non-decreasing values
pub fn ObservableCounter(comptime T: type) type {
    comptime switch (T) {
        i64, f64 => {},
        else => @compileError("ObservableCounter must be of type i64 or f64"),
    };

    return union(enum) {
        noop: []const u8,
        bridge: AsyncInstrumentBridge,

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |name| name,
                .bridge => |bridge| bridge.getName(),
            };
        }

        /// Check if this instrument is enabled for recording measurements
        pub inline fn enabled(self: *const @This()) bool {
            return switch (self.*) {
                .noop => false,
                .bridge => |bridge| bridge.enabled(),
            };
        }

        /// Register a callback with state
        pub inline fn registerCallback(
            self: *const @This(),
            comptime StateType: type,
            callback: ObservableCallback(T, StateType),
            state: *StateType,
        ) !CallbackHandle {
            return switch (self.*) {
                .noop => CallbackHandle.noop(),
                .bridge => |bridge| {
                    const type_erased = createTypeErasedCallback(T, StateType, callback, state);
                    return bridge.registerCallback(type_erased);
                },
            };
        }

        /// Register a callback without state
        pub inline fn registerCallbackNoState(
            self: *const @This(),
            callback: ObservableCallbackNoState(T),
        ) !CallbackHandle {
            return switch (self.*) {
                .noop => CallbackHandle.noop(),
                .bridge => |bridge| {
                    const type_erased = createTypeErasedCallbackNoState(T, callback);
                    return bridge.registerCallback(type_erased);
                },
            };
        }
    };
}

/// Observable Gauge instrument - records current values
pub fn ObservableGauge(comptime T: type) type {
    comptime switch (T) {
        i64, f64 => {},
        else => @compileError("ObservableGauge must be of type i64 or f64"),
    };

    return union(enum) {
        noop: []const u8,
        bridge: AsyncInstrumentBridge,

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |name| name,
                .bridge => |bridge| bridge.getName(),
            };
        }

        /// Check if this instrument is enabled for recording measurements
        pub inline fn enabled(self: *const @This()) bool {
            return switch (self.*) {
                .noop => false,
                .bridge => |bridge| bridge.enabled(),
            };
        }

        /// Register a callback with state
        pub inline fn registerCallback(
            self: *const @This(),
            comptime StateType: type,
            callback: ObservableCallback(T, StateType),
            state: *StateType,
        ) !CallbackHandle {
            return switch (self.*) {
                .noop => CallbackHandle.noop(),
                .bridge => |bridge| {
                    const type_erased = createTypeErasedCallback(T, StateType, callback, state);
                    return bridge.registerCallback(type_erased);
                },
            };
        }

        /// Register a callback without state
        pub inline fn registerCallbackNoState(
            self: *const @This(),
            callback: ObservableCallbackNoState(T),
        ) !CallbackHandle {
            return switch (self.*) {
                .noop => CallbackHandle.noop(),
                .bridge => |bridge| {
                    const type_erased = createTypeErasedCallbackNoState(T, callback);
                    return bridge.registerCallback(type_erased);
                },
            };
        }
    };
}

/// Observable UpDownCounter instrument - can increase and decrease
pub fn ObservableUpDownCounter(comptime T: type) type {
    comptime switch (T) {
        i64, f64 => {},
        else => @compileError("ObservableUpDownCounter must be of type i64 or f64"),
    };

    return union(enum) {
        noop: []const u8,
        bridge: AsyncInstrumentBridge,

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |name| name,
                .bridge => |bridge| bridge.getName(),
            };
        }

        /// Check if this instrument is enabled for recording measurements
        pub inline fn enabled(self: *const @This()) bool {
            return switch (self.*) {
                .noop => false,
                .bridge => |bridge| bridge.enabled(),
            };
        }

        /// Register a callback with state
        pub inline fn registerCallback(
            self: *const @This(),
            comptime StateType: type,
            callback: ObservableCallback(T, StateType),
            state: *StateType,
        ) !CallbackHandle {
            return switch (self.*) {
                .noop => CallbackHandle.noop(),
                .bridge => |bridge| {
                    const type_erased = createTypeErasedCallback(T, StateType, callback, state);
                    return bridge.registerCallback(type_erased);
                },
            };
        }

        /// Register a callback without state
        pub inline fn registerCallbackNoState(
            self: *const @This(),
            callback: ObservableCallbackNoState(T),
        ) !CallbackHandle {
            return switch (self.*) {
                .noop => CallbackHandle.noop(),
                .bridge => |bridge| {
                    const type_erased = createTypeErasedCallbackNoState(T, callback);
                    return bridge.registerCallback(type_erased);
                },
            };
        }
    };
}

/// Handle for managing callback registration and unregistration
pub const CallbackHandle = struct {
    const Self = @This();

    instrument_ptr: ?*anyopaque,
    unregister_fn: ?*const fn (instrument_ptr: *anyopaque, callback_id: u64) void,
    callback_id: u64,

    /// Create a no-op callback handle
    pub fn noop() Self {
        return Self{
            .instrument_ptr = null,
            .unregister_fn = null,
            .callback_id = 0,
        };
    }

    /// Initialize a callback handle
    pub fn init(
        instrument_ptr: *anyopaque,
        unregister_fn: *const fn (instrument_ptr: *anyopaque, callback_id: u64) void,
        callback_id: u64,
    ) Self {
        return Self{
            .instrument_ptr = instrument_ptr,
            .unregister_fn = unregister_fn,
            .callback_id = callback_id,
        };
    }

    /// Unregister the callback
    pub fn unregister(self: *const Self) void {
        if (self.instrument_ptr != null and self.unregister_fn != null) {
            self.unregister_fn.?(self.instrument_ptr.?, self.callback_id);
        }
    }
};

/// Create type-erased callback for stateful callbacks
pub fn createTypeErasedCallback(
    comptime T: type,
    comptime StateType: type,
    callback: ObservableCallback(T, StateType),
    state: *StateType,
) TypeErasedCallback {
    // For now, just store the callback pointer directly
    // The SDK will handle proper type casting and invocation
    return TypeErasedCallback{
        .callback_fn = @ptrCast(callback),
        .state = state,
        .has_state = true,
    };
}

/// Create type-erased callback for stateless callbacks
pub fn createTypeErasedCallbackNoState(
    comptime T: type,
    callback: ObservableCallbackNoState(T),
) TypeErasedCallback {
    return TypeErasedCallback{
        .callback_fn = @ptrCast(callback),
        .state = null,
        .has_state = false,
    };
}

/// Bridge structure for connecting API to SDK implementations
pub const AsyncInstrumentBridge = struct {
    instrument_ptr: *anyopaque,
    getNameFn: *const fn (instrument_ptr: *anyopaque) []const u8,
    enabledFn: *const fn (instrument_ptr: *anyopaque) bool,
    registerCallbackFn: *const fn (instrument_ptr: *anyopaque, callback: TypeErasedCallback) anyerror!CallbackHandle,

    /// Get the name of this instrument
    pub fn getName(self: *const AsyncInstrumentBridge) []const u8 {
        return self.getNameFn(self.instrument_ptr);
    }

    /// Check if this instrument is enabled
    pub fn enabled(self: *const AsyncInstrumentBridge) bool {
        return self.enabledFn(self.instrument_ptr);
    }

    /// Register a callback
    pub fn registerCallback(self: *const AsyncInstrumentBridge, callback: TypeErasedCallback) !CallbackHandle {
        return self.registerCallbackFn(self.instrument_ptr, callback);
    }

    /// Initialize bridge with SDK instrument
    pub fn init(ptr: anytype) AsyncInstrumentBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn getName(pointer: *anyopaque) []const u8 {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getName(self);
            }

            pub fn enabled(pointer: *anyopaque) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.enabled(self);
            }

            pub fn registerCallback(pointer: *anyopaque, callback: TypeErasedCallback) anyerror!CallbackHandle {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.registerCallback(self, callback);
            }
        };

        return .{
            .instrument_ptr = ptr,
            .getNameFn = VTable.getName,
            .enabledFn = VTable.enabled,
            .registerCallbackFn = VTable.registerCallback,
        };
    }
};

test "ObservableResult basic functionality" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ObservableResult(i64).init(allocator, null);
    defer result.deinit();

    try result.observeValue(42);
    try result.observeSimple(100, &[_]AttributeKeyValue{
        .{ .key = "test", .value = .{ .string = "value" } },
    });

    try testing.expectEqual(@as(usize, 2), result.measurements.items.len);
    try testing.expectEqual(@as(i64, 42), result.measurements.items[0].value);
    try testing.expectEqual(@as(i64, 100), result.measurements.items[1].value);
}

test "observable instruments enabled method" {
    const testing = std.testing;

    // Test noop instruments return false
    var noop_counter = ObservableCounter(i64){ .noop = "test" };
    try testing.expect(!noop_counter.enabled());

    var noop_gauge = ObservableGauge(i64){ .noop = "test" };
    try testing.expect(!noop_gauge.enabled());

    var noop_updown = ObservableUpDownCounter(i64){ .noop = "test" };
    try testing.expect(!noop_updown.enabled());
}

test "callback handle noop functionality" {
    const testing = std.testing;

    var handle = CallbackHandle.noop();
    try testing.expect(handle.instrument_ptr == null);
    try testing.expect(handle.unregister_fn == null);
    try testing.expectEqual(@as(u64, 0), handle.callback_id);

    // Should not crash
    handle.unregister();
}

test "type erased callback creation" {
    const testing = std.testing;

    // Test stateful callback
    var state: i32 = 123;
    const callback = struct {
        fn call(result: *ObservableResult(i64), s: *i32) void {
            _ = result;
            _ = s;
        }
    }.call;

    const erased = createTypeErasedCallback(i64, i32, callback, &state);
    try testing.expect(erased.state != null);
    try testing.expect(erased.has_state);

    // Test stateless callback
    const callback_no_state = struct {
        fn call(result: *ObservableResult(i64)) void {
            _ = result;
        }
    }.call;

    const erased_no_state = createTypeErasedCallbackNoState(i64, callback_no_state);
    try testing.expect(erased_no_state.state == null);
    try testing.expect(!erased_no_state.has_state);
}
