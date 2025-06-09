//! OpenTelemetry Logger API
//!
//! This module defines the Logger interface according to the OpenTelemetry specification.
//! A Logger is the primary interface for emitting log records.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/api.md#logger

const std = @import("std");

const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const AttributeValue = @import("../common/root.zig").AttributeValue;
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
const Context = @import("../context/root.zig").Context;
const Severity = @import("severity.zig").Severity;

/// Logger interface using tagged union for compile-time polymorphism.
/// In the API layer, only the noop implementation is provided.
/// SDK implementations will extend this with concrete loggers.
pub const Logger = union(enum) {
    noop: InstrumentationScope,
    bridge: LoggerBridge, // SDK logger bridge

    /// Emit a log record with individual parameters
    pub fn emitLogRecord(
        self: *Logger,
        ctx: Context,
        severity: ?Severity,
        body: ?AttributeValue,
        attributes: ?[]const AttributeKeyValue,
        timestamp_ns: ?i64,
        observed_timestamp_ns: ?i64,
        event_name: ?[]const u8,
        severity_text: ?[]const u8,
        trace_id: ?[16]u8,
        span_id: ?[8]u8,
        flags: ?u8,
    ) void {
        switch (self.*) {
            .noop => |_| {},
            .bridge => |bridge| bridge.emitLogRecordFn(
                bridge.logger_ptr,
                ctx,
                severity,
                body,
                attributes,
                timestamp_ns,
                observed_timestamp_ns,
                event_name,
                severity_text,
                trace_id,
                span_id,
                flags,
            ),
        }
    }

    /// Check if logging is enabled for a given severity
    pub inline fn enabled(self: *const Logger, ctx: Context, severity: Severity) bool {
        return switch (self.*) {
            .noop => |_| return false,
            .bridge => |bridge| bridge.enabledFn(bridge.logger_ptr, ctx, severity),
        };
    }

    /// Check if logging is enabled for a given severity and event name
    pub inline fn enabledWithEvent(
        self: *const Logger,
        ctx: Context,
        severity: Severity,
        event_name: []const u8,
    ) bool {
        return switch (self.*) {
            .noop => |_| return false,
            .bridge => |bridge| bridge.enabledWithEventFn(bridge.logger_ptr, ctx, severity, event_name),
        };
    }

    /// Get the instrumentation scope for this logger
    pub inline fn getInstrumentationScope(self: *const Logger) InstrumentationScope {
        return switch (self.*) {
            .noop => |scope| scope,
            .bridge => |bridge| bridge.getInstrumentationScopeFn(bridge.logger_ptr),
        };
    }

    /// Clean up logger resources
    pub inline fn deinit(self: *Logger) void {
        switch (self.*) {
            .noop => |_| {},
            .bridge => |bridge| bridge.deinitFn(bridge.logger_ptr),
        }
    }

    // Convenience methods for different severity levels

    /// Log a trace message
    pub inline fn trace(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .trace, fmt, args);
    }

    /// Log a debug message
    pub inline fn debug(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .debug, fmt, args);
    }

    /// Log an info message
    pub inline fn info(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .info, fmt, args);
    }

    /// Log a warning message
    pub inline fn warn(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .warn, fmt, args);
    }

    /// Log an error message
    pub inline fn @"error"(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .@"error", fmt, args);
    }

    /// Log a fatal message
    pub inline fn fatal(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .fatal, fmt, args);
    }

    /// Generic log method with severity
    pub fn log(
        self: *Logger,
        ctx: Context,
        severity: Severity,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (!self.enabled(ctx, severity)) return;

        var buf: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, fmt, args) catch |err| blk: {
            const truncated = switch (err) {
                error.NoSpaceLeft => " [truncated]",
            };
            break :blk buf[0 .. buf.len - truncated.len] ++ truncated;
        };

        self.emitLogRecord(
            ctx,
            severity,
            AttributeValue{ .string = message },
            null, // attributes
            @as(i64, @intCast(std.time.nanoTimestamp())), // timestamp_ns
            null, // observed_timestamp_ns
            null, // event_name
            null, // severity_text
            null, // trace_id
            null, // span_id
            null, // flags
        );
    }
};

/// Bridge structure that holds SDK logger pointer and vtable
pub const LoggerBridge = struct {
    logger_ptr: *anyopaque,
    emitLogRecordFn: *const fn (
        logger_ptr: *anyopaque,
        ctx: Context,
        severity: ?Severity,
        body: ?AttributeValue,
        attributes: ?[]const AttributeKeyValue,
        timestamp_ns: ?i64,
        observed_timestamp_ns: ?i64,
        event_name: ?[]const u8,
        severity_text: ?[]const u8,
        trace_id: ?[16]u8,
        span_id: ?[8]u8,
        flags: ?u8,
    ) void,
    enabledFn: *const fn (logger_ptr: *anyopaque, ctx: Context, severity: Severity) bool,
    enabledWithEventFn: *const fn (logger_ptr: *anyopaque, ctx: Context, severity: Severity, event_name: []const u8) bool,
    getInstrumentationScopeFn: *const fn (logger_ptr: *anyopaque) InstrumentationScope,
    deinitFn: *const fn (logger_ptr: *anyopaque) void,

    pub fn init(ptr: anytype) LoggerBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn emitLogRecord(
                pointer: *anyopaque,
                ctx: Context,
                severity: ?Severity,
                body: ?AttributeValue,
                attributes: ?[]const AttributeKeyValue,
                timestamp_ns: ?i64,
                observed_timestamp_ns: ?i64,
                event_name: ?[]const u8,
                severity_text: ?[]const u8,
                trace_id: ?[16]u8,
                span_id: ?[8]u8,
                flags: ?u8,
            ) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.emitLogRecord(
                    self,
                    ctx,
                    severity,
                    body,
                    attributes,
                    timestamp_ns,
                    observed_timestamp_ns,
                    event_name,
                    severity_text,
                    trace_id,
                    span_id,
                    flags,
                );
            }
            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.deinit(self);
            }
            pub fn enabled(pointer: *anyopaque, ctx: Context, severity: Severity) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.enabled(self, ctx, severity);
            }
            pub fn enabledWithEvent(pointer: *anyopaque, ctx: Context, severity: Severity, event_name: []const u8) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.enabledWithEvent(self, ctx, severity, event_name);
            }
            pub fn getInstrumentationScope(pointer: *anyopaque) InstrumentationScope {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getInstrumentationScope(self);
            }
        };

        return .{
            .logger_ptr = ptr,
            .emitLogRecordFn = VTable.emitLogRecord,
            .enabledFn = VTable.enabled,
            .enabledWithEventFn = VTable.enabledWithEvent,
            .getInstrumentationScopeFn = VTable.getInstrumentationScope,
            .deinitFn = VTable.deinit,
        };
    }
};
