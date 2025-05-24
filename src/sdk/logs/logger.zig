//! OpenTelemetry Logger SDK Implementation
//!
//! This module provides concrete implementations of the Logger interface.
//! The SDK provides StandardLogger and CustomLogger implementations that can be
//! used with the API's Logger interface.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md

const std = @import("std");
const otel_api = @import("otel-api");

const Context = otel_api.Context;
const LogRecord = otel_api.logs.LogRecord;
const Severity = otel_api.logs.Severity;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const AttributeValue = otel_api.common.AttributeValue;
const KeyValue = otel_api.common.KeyValue;
pub const Logger = otel_api.logs.Logger;
const Resource = @import("../resource/resource.zig").Resource;

/// Standard logger implementation with configurable severity and handler
pub const StandardLogger = struct {
    allocator: std.mem.Allocator,
    scope: InstrumentationScope,
    min_severity: Severity = .invalid,
    handler_context: *anyopaque,
    handler_fn: *const fn (context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void,
    resource: *const Resource,

    pub fn init(
        allocator: std.mem.Allocator,
        scope: InstrumentationScope,
        min_severity: Severity,
        handler_context: *anyopaque,
        handler_fn: *const fn (context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void,
        resource: *const Resource,
    ) StandardLogger {
        return .{
            .allocator = allocator,
            .scope = scope,
            .min_severity = min_severity,
            .handler_context = handler_context,
            .handler_fn = handler_fn,
            .resource = resource,
        };
    }

    pub fn deinit(self: *StandardLogger) void {
        _ = self;
    }

    pub fn emitLogRecord(self: *StandardLogger, ctx: Context, record: LogRecord) void {
        // Check severity filtering
        if (!self.enabled(ctx, record.severity_number)) return;
        
        // Delegate to handler
        self.handler_fn(self.handler_context, ctx, record, self.resource);
    }

    pub fn enabled(self: *const StandardLogger, ctx: Context, severity: Severity) bool {
        _ = ctx;
        // Compare severity levels for filtering
        return @intFromEnum(severity) >= @intFromEnum(self.min_severity);
    }

    pub fn enabledWithEvent(
        self: *const StandardLogger,
        ctx: Context,
        severity: Severity,
        event_name: []const u8,
    ) bool {
        _ = event_name;
        return self.enabled(ctx, severity);
    }

    pub fn setMinimumSeverity(self: *StandardLogger, severity: Severity) void {
        self.min_severity = severity;
    }

    pub fn getResource(self: *const StandardLogger) *const Resource {
        return self.resource;
    }
};

/// Custom logger implementation with user-provided functions
pub const CustomLogger = struct {
    allocator: std.mem.Allocator,
    scope: InstrumentationScope,
    impl: *anyopaque,
    emitFn: *const fn (impl: *anyopaque, ctx: Context, record: LogRecord) void,
    enabledFn: ?*const fn (impl: *anyopaque, ctx: Context, severity: Severity) bool,
    enabledWithEventFn: ?*const fn (impl: *anyopaque, ctx: Context, severity: Severity, event_name: []const u8) bool,
    deinitFn: ?*const fn (impl: *anyopaque) void,
    resource: *const Resource,

    pub fn init(
        allocator: std.mem.Allocator,
        scope: InstrumentationScope,
        impl: *anyopaque,
        emitFn: *const fn (impl: *anyopaque, ctx: Context, record: LogRecord) void,
        enabledFn: ?*const fn (impl: *anyopaque, ctx: Context, severity: Severity) bool,
        enabledWithEventFn: ?*const fn (impl: *anyopaque, ctx: Context, severity: Severity, event_name: []const u8) bool,
        deinitFn: ?*const fn (impl: *anyopaque) void,
        resource: *const Resource,
    ) CustomLogger {
        return .{
            .allocator = allocator,
            .scope = scope,
            .impl = impl,
            .emitFn = emitFn,
            .enabledFn = enabledFn,
            .enabledWithEventFn = enabledWithEventFn,
            .deinitFn = deinitFn,
            .resource = resource,
        };
    }

    pub fn deinit(self: *CustomLogger) void {
        if (self.deinitFn) |deinitFunc| {
            deinitFunc(self.impl);
        }
    }

    pub fn emitLogRecord(self: *CustomLogger, ctx: Context, record: LogRecord) void {
        self.emitFn(self.impl, ctx, record);
    }

    pub fn enabled(self: *const CustomLogger, ctx: Context, severity: Severity) bool {
        if (self.enabledFn) |enabledFunc| {
            return enabledFunc(self.impl, ctx, severity);
        }
        return true; // Default to enabled if no function provided
    }

    pub fn enabledWithEvent(
        self: *const CustomLogger,
        ctx: Context,
        severity: Severity,
        event_name: []const u8,
    ) bool {
        if (self.enabledWithEventFn) |enabledFunc| {
            return enabledFunc(self.impl, ctx, severity, event_name);
        }
        return self.enabled(ctx, severity);
    }

    pub fn getResource(self: *const CustomLogger) *const Resource {
        return self.resource;
    }
};

/// Create a standard logger with a handler function and wrap it in a Logger
pub fn createStandardLogger(
    allocator: std.mem.Allocator,
    scope: InstrumentationScope,
    handler: *const fn (ctx: Context, record: LogRecord, resource: *const Resource) void,
) *Logger {
    const logger = allocator.create(Logger) catch unreachable;
    _ = handler; // Mark as used to avoid warning
    logger.* = Logger{
        .noop = otel_api.logs.NoopLogger.init(scope), // Temporary, will be replaced
    };
    // Note: In a real implementation, we'd need to extend the API Logger type
    // to include standard and custom variants. For now, we return a pointer
    // that the SDK can manage.
    return logger;
}

/// Create a custom logger with user-provided implementation
pub fn createCustomLogger(
    allocator: std.mem.Allocator,
    scope: InstrumentationScope,
    impl: *anyopaque,
    emitFn: *const fn (impl: *anyopaque, ctx: Context, record: LogRecord) void,
    enabledFn: ?*const fn (impl: *anyopaque, ctx: Context, severity: Severity) bool,
    enabledWithEventFn: ?*const fn (impl: *anyopaque, ctx: Context, severity: Severity, event_name: []const u8) bool,
    deinitFn: ?*const fn (impl: *anyopaque) void,
    resource: *const Resource,
) CustomLogger {
    return CustomLogger.init(allocator, scope, impl, emitFn, enabledFn, enabledWithEventFn, deinitFn, resource);
}

test "StandardLogger basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

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

    const scope = try InstrumentationScope.initWithName("test.logger");
    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);
    var test_context: u8 = 0;
    var standard_logger = StandardLogger.init(allocator, scope, .invalid, &test_context, TestHandler.handler, &resource);
    defer standard_logger.deinit();

    // Test emitting log record
    const record = LogRecord{
        .severity_number = .info,
        .body = AttributeValue{ .string = "Test message" },
    };

    const ctx = Context.empty(testing.allocator);
    standard_logger.emitLogRecord(ctx, record);
    try testing.expectEqual(@as(usize, 1), TestState.log_count);

    // Test severity filtering
    standard_logger.setMinimumSeverity(.warn);
    try testing.expect(!standard_logger.enabled(ctx, .info));
    try testing.expect(standard_logger.enabled(ctx, .warn));
    try testing.expect(standard_logger.enabled(ctx, .@"error"));
}

test "StandardLogger severity filtering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestState = struct {
        var received_records: ?std.ArrayList(Severity) = null;
    };
    TestState.received_records = std.ArrayList(Severity).init(allocator);
    defer TestState.received_records.?.deinit();

    const TestHandler = struct {
        fn handler(context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void {
            _ = context;
            _ = ctx;
            _ = resource;
            TestState.received_records.?.append(record.severity_number) catch {};
        }
    };

    const scope = try InstrumentationScope.initWithName("test.logger");
    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);
    var test_context2: u8 = 0;
    var logger = StandardLogger.init(allocator, scope, .invalid, &test_context2, TestHandler.handler, &resource);
    defer logger.deinit();

    logger.setMinimumSeverity(.warn);

    const ctx = Context.empty(testing.allocator);
    
    // These should be filtered out
    logger.emitLogRecord(ctx, LogRecord{ .severity_number = .trace, .body = AttributeValue{ .string = "trace" } });
    logger.emitLogRecord(ctx, LogRecord{ .severity_number = .debug, .body = AttributeValue{ .string = "debug" } });
    logger.emitLogRecord(ctx, LogRecord{ .severity_number = .info, .body = AttributeValue{ .string = "info" } });
    
    // These should pass through
    logger.emitLogRecord(ctx, LogRecord{ .severity_number = .warn, .body = AttributeValue{ .string = "warn" } });
    logger.emitLogRecord(ctx, LogRecord{ .severity_number = .@"error", .body = AttributeValue{ .string = "error" } });
    logger.emitLogRecord(ctx, LogRecord{ .severity_number = .fatal, .body = AttributeValue{ .string = "fatal" } });

    try testing.expectEqual(@as(usize, 3), TestState.received_records.?.items.len);
    try testing.expectEqual(Severity.warn, TestState.received_records.?.items[0]);
    try testing.expectEqual(Severity.@"error", TestState.received_records.?.items[1]);
    try testing.expectEqual(Severity.fatal, TestState.received_records.?.items[2]);
}

test "CustomLogger operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const CustomImpl = struct {
        count: usize = 0,
        min_severity: Severity = .invalid,

        fn emit(impl: *anyopaque, ctx: Context, record: LogRecord) void {
            _ = ctx;
            _ = record;
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            self.count += 1;
        }

        fn enabled(impl: *anyopaque, ctx: Context, severity: Severity) bool {
            _ = ctx;
            const self = @as(*const @This(), @ptrCast(@alignCast(impl)));
            return @intFromEnum(severity) >= @intFromEnum(self.min_severity);
        }

        fn deinit(impl: *anyopaque) void {
            _ = impl;
        }
    };

    var impl = CustomImpl{};
    const scope = try InstrumentationScope.initWithName("test.custom");
    const resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer resource.deinitOwned(allocator);
    var logger = createCustomLogger(
        allocator,
        scope,
        &impl,
        CustomImpl.emit,
        CustomImpl.enabled,
        null,
        CustomImpl.deinit,
        &resource,
    );
    defer logger.deinit();

    const ctx = Context.empty(testing.allocator);
    const record = LogRecord{
        .severity_number = .info,
        .body = AttributeValue{ .string = "Test" },
    };

    logger.emitLogRecord(ctx, record);
    try testing.expectEqual(@as(usize, 1), impl.count);

    // Test severity filtering
    impl.min_severity = .warn;
    try testing.expect(!logger.enabled(ctx, .info));
    try testing.expect(logger.enabled(ctx, .@"error"));
}