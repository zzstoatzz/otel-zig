//! OpenTelemetry Tracer API
//!
//! This module defines the Tracer interface according to the OpenTelemetry specification.
//! A Tracer creates spans and manages trace instrumentation within a specific scope.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#tracer

const std = @import("std");

const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const Context = @import("../context/root.zig").Context;
const Span = @import("span.zig").Span;
const SpanContext = @import("span_context.zig").SpanContext;
const SpanStartOptions = @import("span.zig").SpanStartOptions;

/// Result type for span creation operations
pub const SpanResult = struct {
    span: Span,
    context: Context,
};

/// Tracer interface using tagged union for compile-time polymorphism.
/// In the API layer, only the noop implementation is provided.
/// SDK implementations will extend this with concrete tracers.
pub const Tracer = union(enum) {
    noop: InstrumentationScope,
    bridge: TracerBridge, // SDK tracer bridge

    /// Start a new span with the given name and options
    /// Returns a tuple of (span, updated_context) following immutable context pattern
    pub fn startSpan(
        self: *Tracer,
        name: []const u8,
        options: SpanStartOptions,
        ctx: Context,
    ) !Span {
        switch (self.*) {
            .noop => return Span{ .noop = SpanContext.invalid },
            .bridge => |bridge| return bridge.startSpanFn(bridge.tracer_ptr, name, options, ctx),
        }
    }

    /// Get the instrumentation scope for this tracer
    pub inline fn getInstrumentationScope(self: *const Tracer) InstrumentationScope {
        return switch (self.*) {
            .noop => |scope| scope,
            .bridge => |bridge| bridge.getInstrumentationScopeFn(bridge.tracer_ptr),
        };
    }

    /// Clean up tracer resources
    pub inline fn deinit(self: *Tracer) void {
        switch (self.*) {
            .noop => |_| {},
            .bridge => |bridge| bridge.deinitFn(bridge.tracer_ptr),
        }
    }
};

/// Bridge structure that holds SDK tracer pointer and vtable
pub const TracerBridge = struct {
    tracer_ptr: *anyopaque,
    startSpanFn: *const fn (
        tracer_ptr: *anyopaque,
        name: []const u8,
        options: SpanStartOptions,
        ctx: Context,
    ) anyerror!Span,
    getInstrumentationScopeFn: *const fn (tracer_ptr: *anyopaque) InstrumentationScope,
    deinitFn: *const fn (tracer_ptr: *anyopaque) void,

    pub fn init(ptr: anytype) TracerBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn startSpan(
                pointer: *anyopaque,
                name: []const u8,
                options: SpanStartOptions,
                ctx: Context,
            ) anyerror!Span {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.startSpan(self, name, options, ctx);
            }
            pub fn getInstrumentationScope(pointer: *anyopaque) InstrumentationScope {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getInstrumentationScope(self);
            }
            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.deinit(self);
            }
        };

        return .{
            .tracer_ptr = ptr,
            .startSpanFn = VTable.startSpan,
            .getInstrumentationScopeFn = VTable.getInstrumentationScope,
            .deinitFn = VTable.deinit,
        };
    }
};
