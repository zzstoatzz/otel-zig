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
const Context = @import("../context/root.zig").Context;
const LogRecord = @import("log_record.zig").LogRecord;
const Severity = @import("severity.zig").Severity;
const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const AttributeValue = @import("../common/root.zig").AttributeValue;
const KeyValue = @import("../common/root.zig").KeyValue;

/// Logger interface using tagged union for compile-time polymorphism.
/// In the API layer, only the noop implementation is provided.
/// SDK implementations will extend this with concrete loggers.
pub const Logger = union(enum) {
    noop: NoopLogger,
    sdk: SdkLoggerBridge,  // SDK logger bridge

    /// Emit a log record
    pub fn emitLogRecord(self: *Logger, ctx: Context, record: LogRecord) void {
        switch (self.*) {
            .noop => |*logger| logger.emitLogRecord(ctx, record),
            .sdk => |*bridge| bridge.vtable.emitLogRecord(bridge.logger_ptr, ctx, record),
        }
    }

    /// Check if logging is enabled for a given severity
    pub fn enabled(self: *const Logger, ctx: Context, severity: Severity) bool {
        return switch (self.*) {
            .noop => |*logger| logger.enabled(ctx, severity),
            .sdk => |*bridge| bridge.vtable.enabled(bridge.logger_ptr, ctx, severity),
        };
    }

    /// Check if logging is enabled for a given severity and event name
    pub fn enabledWithEvent(
        self: *const Logger,
        ctx: Context,
        severity: Severity,
        event_name: []const u8,
    ) bool {
        return switch (self.*) {
            .noop => |*logger| logger.enabledWithEvent(ctx, severity, event_name),
            .sdk => |*bridge| bridge.vtable.enabledWithEvent(bridge.logger_ptr, ctx, severity, event_name),
        };
    }

    /// Get the instrumentation scope for this logger
    pub fn getInstrumentationScope(self: *const Logger) InstrumentationScope {
        return switch (self.*) {
            .noop => |logger| logger.scope,
            .sdk => |*bridge| bridge.vtable.getInstrumentationScope(bridge.logger_ptr),
        };
    }

    /// Clean up logger resources
    pub fn deinit(self: *Logger) void {
        switch (self.*) {
            .noop => |*logger| logger.deinit(),
            .sdk => |*bridge| bridge.vtable.deinit(bridge.logger_ptr),
        }
    }

    // Convenience methods for different severity levels

    /// Log a trace message
    pub fn trace(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .trace, fmt, args);
    }

    /// Log a debug message
    pub fn debug(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .debug, fmt, args);
    }

    /// Log an info message
    pub fn info(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .info, fmt, args);
    }

    /// Log a warning message
    pub fn warn(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .warn, fmt, args);
    }

    /// Log an error message
    pub fn @"error"(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .@"error", fmt, args);
    }

    /// Log a fatal message
    pub fn fatal(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
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

        const record = LogRecord{
            .severity_number = severity,
            .body = AttributeValue{ .string = message },
        };

        self.emitLogRecord(ctx, record);
    }
};

/// No-operation logger implementation
pub const NoopLogger = struct {
    scope: InstrumentationScope,

    pub fn init(scope: InstrumentationScope) NoopLogger {
        return .{ .scope = scope };
    }

    pub fn deinit(self: *NoopLogger) void {
        _ = self;
    }

    pub fn emitLogRecord(self: *NoopLogger, ctx: Context, record: LogRecord) void {
        _ = self;
        _ = ctx;
        _ = record;
    }

    pub fn enabled(self: *const NoopLogger, ctx: Context, severity: Severity) bool {
        _ = self;
        _ = ctx;
        _ = severity;
        return false;
    }

    pub fn enabledWithEvent(
        self: *const NoopLogger,
        ctx: Context,
        severity: Severity,
        event_name: []const u8,
    ) bool {
        _ = self;
        _ = ctx;
        _ = severity;
        _ = event_name;
        return false;
    }
};

/// Create a no-operation logger
pub fn createNoopLogger(scope: InstrumentationScope) Logger {
    return .{ .noop = NoopLogger.init(scope) };
}

test "NoopLogger operations" {
    const testing = std.testing;

    const scope = try InstrumentationScope.initWithName("test.logger");
    var logger = createNoopLogger(scope);
    defer logger.deinit();

    // Create a test context
    var ctx = Context.empty(std.testing.allocator);
    defer ctx.deinit();

    // Test that noop logger is always disabled
    try testing.expect(!logger.enabled(ctx, .info));
    try testing.expect(!logger.enabled(ctx, .fatal));
    try testing.expect(!logger.enabledWithEvent(ctx, .@"error", "test.event"));

    // Test that emitting logs doesn't crash
    const record = LogRecord{
        .severity_number = .info,
        .body = AttributeValue{ .string = "Test message" },
    };
    logger.emitLogRecord(ctx, record);

    // Test convenience methods
    logger.info(ctx, "Test info: {}", .{123});
    logger.@"error"(ctx, "Test error: {s}", .{"error"});

    // Verify instrumentation scope
    try testing.expectEqualStrings("test.logger", logger.getInstrumentationScope().name);
}

/// Virtual table for SDK logger implementations
pub const SdkLoggerVTable = struct {
    emitLogRecord: *const fn (logger_ptr: *anyopaque, ctx: Context, record: LogRecord) void,
    enabled: *const fn (logger_ptr: *anyopaque, ctx: Context, severity: Severity) bool,
    enabledWithEvent: *const fn (logger_ptr: *anyopaque, ctx: Context, severity: Severity, event_name: []const u8) bool,
    getInstrumentationScope: *const fn (logger_ptr: *anyopaque) InstrumentationScope,
    deinit: *const fn (logger_ptr: *anyopaque) void,
};

/// Bridge structure that holds SDK logger pointer and vtable
pub const SdkLoggerBridge = struct {
    logger_ptr: *anyopaque,
    vtable: SdkLoggerVTable,
};

test "Logger convenience methods" {
    const scope = try InstrumentationScope.initWithName("test.logger");
    var logger = createNoopLogger(scope);
    defer logger.deinit();

    var ctx = Context.empty(std.testing.allocator);
    defer ctx.deinit();

    // Test all severity levels
    logger.trace(ctx, "Trace message", .{});
    logger.debug(ctx, "Debug message", .{});
    logger.info(ctx, "Info message", .{});
    logger.warn(ctx, "Warn message", .{});
    logger.@"error"(ctx, "Error message", .{});
    logger.fatal(ctx, "Fatal message", .{});

    // Test with formatting
    logger.info(ctx, "User {} logged in", .{42});
    logger.@"error"(ctx, "Failed to process: {s}", .{"timeout"});
}