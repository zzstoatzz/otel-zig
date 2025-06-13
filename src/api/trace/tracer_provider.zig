//! OpenTelemetry Tracer Provider API
//!
//! This module defines the TracerProvider interface for creating Tracer instances.
//! TracerProvider manages the lifecycle of tracers and ensures consistent
//! tracer instances for the same instrumentation scope.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#tracerprovider

const std = @import("std");
const Tracer = @import("tracer.zig").Tracer;
const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const FlushResult = @import("../common/results.zig").FlushResult;

/// TracerProvider interface using tagged union for polymorphism
pub const TracerProvider = union(enum) {
    noop: void,
    bridge: TracerProviderBridge, // SDK provider bridge

    /// Get or create a tracer with instrumentation scope (OpenTelemetry API specification compliant)
    pub inline fn getTracerWithScope(self: *TracerProvider, scope: InstrumentationScope) !Tracer {
        return switch (self.*) {
            .noop => |_| Tracer{ .noop = scope },
            .bridge => |*bridge| bridge.getTracerWithScopeFn(bridge.provider_ptr, scope),
        };
    }

    /// Force flush all meters managed by this provider
    pub fn forceFlush(self: *TracerProvider, timeout_ms: ?u64) FlushResult {
        return switch (self.*) {
            .noop => FlushResult.success,
            .bridge => |*bridge| bridge.forceFlushFn(bridge.provider_ptr, timeout_ms),
        };
    }

    /// Clean up provider resources
    pub fn deinit(self: *TracerProvider) void {
        switch (self.*) {
            .noop => |_| {},
            .bridge => |*bridge| bridge.deinitFn(bridge.provider_ptr),
        }
    }
};

/// Bridge structure that holds SDK provider pointer and vtable
pub const TracerProviderBridge = struct {
    provider_ptr: *anyopaque,
    getTracerWithScopeFn: *const fn (provider_ptr: *anyopaque, scope: InstrumentationScope) anyerror!Tracer,
    forceFlushFn: *const fn (provider_ptr: *anyopaque, timeout_ns: ?u64) FlushResult,
    deinitFn: *const fn (provider_ptr: *anyopaque) void,

    pub fn init(ptr: anytype) TracerProviderBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn getTracerWithScope(pointer: *anyopaque, scope: InstrumentationScope) anyerror!Tracer {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getTracerWithScope(self, scope);
            }
            pub fn forceFlush(pointer: *anyopaque, timeout_ms: ?u64) FlushResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.forceFlush(self, timeout_ms);
            }
            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.deinit(self);
            }
        };

        return .{
            .provider_ptr = ptr,
            .getTracerWithScopeFn = VTable.getTracerWithScope,
            .forceFlushFn = VTable.forceFlush,
            .deinitFn = VTable.deinit,
        };
    }
};
