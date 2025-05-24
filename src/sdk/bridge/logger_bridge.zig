//! SDK Logger Bridge
//!
//! This module provides bridge adapters that wrap SDK logger implementations
//! to work seamlessly with the API Logger interface using virtual tables.

const std = @import("std");
const otel_api = @import("otel-api");
const sdk_logs = @import("../logs/root.zig");

const Context = otel_api.Context;
const LogRecord = otel_api.logs.LogRecord;
const Severity = otel_api.logs.Severity;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const Logger = otel_api.logs.Logger;
const SdkLoggerVTable = otel_api.logs.SdkLoggerVTable;
const Resource = @import("../resource/resource.zig").Resource;

const StandardLogger = sdk_logs.StandardLogger;
const CustomLogger = sdk_logs.CustomLogger;
const setBridgeAllocator = @import("provider_bridge.zig").setBridgeAllocator;

/// Wrap a StandardLogger for use with the API
pub fn wrapStandardLogger(allocator: std.mem.Allocator, sdk_logger: *StandardLogger) !*Logger {
    const api_logger = try allocator.create(Logger);
    errdefer allocator.destroy(api_logger);

    // Create the vtable for StandardLogger
    const vtable = SdkLoggerVTable{
        .emitLogRecord = standardLoggerEmitLogRecord,
        .enabled = standardLoggerEnabled,
        .enabledWithEvent = standardLoggerEnabledWithEvent,
        .getInstrumentationScope = standardLoggerGetInstrumentationScope,
        .deinit = standardLoggerDeinit,
    };

    // Create bridge structure
    const bridge = otel_api.logs.SdkLoggerBridge{
        .logger_ptr = @as(*anyopaque, @ptrCast(sdk_logger)),
        .vtable = vtable,
    };

    // Create API logger with SDK variant
    api_logger.* = .{ .sdk = bridge };

    return api_logger;
}

/// Wrap a CustomLogger for use with the API
pub fn wrapCustomLogger(allocator: std.mem.Allocator, sdk_logger: *CustomLogger) !*Logger {
    const api_logger = try allocator.create(Logger);
    errdefer allocator.destroy(api_logger);

    // Create the vtable for CustomLogger
    const vtable = SdkLoggerVTable{
        .emitLogRecord = customLoggerEmitLogRecord,
        .enabled = customLoggerEnabled,
        .enabledWithEvent = customLoggerEnabledWithEvent,
        .getInstrumentationScope = customLoggerGetInstrumentationScope,
        .deinit = customLoggerDeinit,
    };

    // Create bridge structure
    const bridge = otel_api.logs.SdkLoggerBridge{
        .logger_ptr = @as(*anyopaque, @ptrCast(sdk_logger)),
        .vtable = vtable,
    };

    // Create API logger with SDK variant
    api_logger.* = .{ .sdk = bridge };

    return api_logger;
}

// StandardLogger vtable implementations

fn standardLoggerEmitLogRecord(logger_ptr: *anyopaque, ctx: Context, record: LogRecord) void {
    const logger = @as(*StandardLogger, @ptrCast(@alignCast(logger_ptr)));
    logger.emitLogRecord(ctx, record);
}

fn standardLoggerEnabled(logger_ptr: *anyopaque, ctx: Context, severity: Severity) bool {
    const logger = @as(*const StandardLogger, @ptrCast(@alignCast(logger_ptr)));
    return logger.enabled(ctx, severity);
}

fn standardLoggerEnabledWithEvent(logger_ptr: *anyopaque, ctx: Context, severity: Severity, event_name: []const u8) bool {
    const logger = @as(*const StandardLogger, @ptrCast(@alignCast(logger_ptr)));
    return logger.enabledWithEvent(ctx, severity, event_name);
}

fn standardLoggerGetInstrumentationScope(logger_ptr: *anyopaque) InstrumentationScope {
    const logger = @as(*const StandardLogger, @ptrCast(@alignCast(logger_ptr)));
    return logger.scope;
}

fn standardLoggerDeinit(logger_ptr: *anyopaque) void {
    const logger = @as(*StandardLogger, @ptrCast(@alignCast(logger_ptr)));
    logger.deinit();
}

// CustomLogger vtable implementations

fn customLoggerEmitLogRecord(logger_ptr: *anyopaque, ctx: Context, record: LogRecord) void {
    const logger = @as(*CustomLogger, @ptrCast(@alignCast(logger_ptr)));
    logger.emitLogRecord(ctx, record);
}

fn customLoggerEnabled(logger_ptr: *anyopaque, ctx: Context, severity: Severity) bool {
    const logger = @as(*const CustomLogger, @ptrCast(@alignCast(logger_ptr)));
    return logger.enabled(ctx, severity);
}

fn customLoggerEnabledWithEvent(logger_ptr: *anyopaque, ctx: Context, severity: Severity, event_name: []const u8) bool {
    const logger = @as(*const CustomLogger, @ptrCast(@alignCast(logger_ptr)));
    return logger.enabledWithEvent(ctx, severity, event_name);
}

fn customLoggerGetInstrumentationScope(logger_ptr: *anyopaque) InstrumentationScope {
    const logger = @as(*const CustomLogger, @ptrCast(@alignCast(logger_ptr)));
    return logger.scope;
}

fn customLoggerDeinit(logger_ptr: *anyopaque) void {
    const logger = @as(*CustomLogger, @ptrCast(@alignCast(logger_ptr)));
    logger.deinit();
}

test "StandardLogger bridge" {
    const testing = std.testing;
    const allocator = testing.allocator;

    setBridgeAllocator(allocator);

    const TestState = struct {
        var log_count: usize = 0;
    };
    TestState.log_count = 0;

    const TestHandler = struct {
        fn handler(context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void {
            _ = context;
            _ = ctx;
            _ = record;
            _ = resource;
            TestState.log_count += 1;
        }
    };

    const scope = try InstrumentationScope.initWithName("test.bridge");
    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);
    var test_context: u8 = 0;
    var sdk_logger = StandardLogger.init(allocator, scope, .info, &test_context, TestHandler.handler, &resource);
    defer sdk_logger.deinit();

    // Wrap SDK logger for API use
    const api_logger = try wrapStandardLogger(allocator, &sdk_logger);
    defer allocator.destroy(api_logger);

    // Test that API logger works
    const ctx = Context.empty(allocator);

    api_logger.info(ctx, "Test message", .{});
    try testing.expectEqual(@as(usize, 1), TestState.log_count);

    // Test severity filtering
    try testing.expect(api_logger.enabled(ctx, .info));
    try testing.expect(api_logger.enabled(ctx, .@"error"));
    try testing.expect(!api_logger.enabled(ctx, .debug));

    // Test instrumentation scope
    const retrieved_scope = api_logger.getInstrumentationScope();
    try testing.expectEqualStrings("test.bridge", retrieved_scope.name);
}

test "CustomLogger bridge" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const CustomImpl = struct {
        count: usize = 0,

        fn emit(impl: *anyopaque, ctx: Context, record: LogRecord) void {
            _ = ctx;
            _ = record;
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            self.count += 1;
        }

        fn enabled(impl: *anyopaque, ctx: Context, severity: Severity) bool {
            _ = ctx;
            _ = severity;
            _ = impl;
            return true;
        }
    };

    var impl = CustomImpl{};
    const scope = try InstrumentationScope.initWithName("test.custom.bridge");
    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);
    var sdk_logger = CustomLogger.init(
        allocator,
        scope,
        &impl,
        CustomImpl.emit,
        CustomImpl.enabled,
        null,
        null,
        &resource,
    );
    defer sdk_logger.deinit();

    // Wrap SDK logger for API use
    const api_logger = try wrapCustomLogger(allocator, &sdk_logger);
    defer allocator.destroy(api_logger);

    // Test that API logger works
    const ctx = Context.empty(allocator);

    api_logger.info(ctx, "Test custom message", .{});
    try testing.expectEqual(@as(usize, 1), impl.count);

    // Test enabled check
    try testing.expect(api_logger.enabled(ctx, .debug));

    // Test instrumentation scope
    const retrieved_scope = api_logger.getInstrumentationScope();
    try testing.expectEqualStrings("test.custom.bridge", retrieved_scope.name);
}
