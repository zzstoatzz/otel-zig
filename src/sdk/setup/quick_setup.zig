//! Quick Setup for OpenTelemetry SDK
//!
//! This module provides simple one-line setup functions for common OpenTelemetry
//! configurations, using the bridge pattern to seamlessly integrate SDK implementations
//! with API interfaces.
//!
//! ## Usage
//! ```zig
//! const otel_sdk = @import("otel-sdk");
//!
//! // One-line console logging setup
//! try otel_sdk.setup.consoleLogging(allocator);
//!
//! // Get logger from global registry (now backed by SDK)
//! const logger = try otel.api.provider_registry.getGlobalLogger("my.app");
//! logger.info(ctx, "Hello, OpenTelemetry!", .{});
//! ```

const std = @import("std");
const otel_api = @import("otel-api");
const sdk_logs = @import("../logs/root.zig");
const bridge = @import("../bridge/root.zig");
const otel_exporters = @import("otel-exporters");
const Resource = @import("../resource/resource.zig").Resource;

/// Polymorphic log handler interface
pub const LogHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        handle: *const fn (ptr: *anyopaque, ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn handle(self: @This(), ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void {
        self.vtable.handle(self.ptr, ctx, record, resource);
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

/// Console handler implementation
const ConcreteConsoleHandler = struct {
    // No state needed for console handler

    const vtable = LogHandler.VTable{
        .handle = handleImpl,
        .deinit = deinitImpl,
    };

    fn handleImpl(ptr: *anyopaque, ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void {
        _ = ptr;
        _ = ctx;
        _ = resource;

        const stdout = std.io.getStdOut().writer();

        // Format timestamp
        const timestamp = record.timestamp_ns orelse @as(i64, @intCast(std.time.nanoTimestamp()));
        const seconds = @divFloor(timestamp, std.time.ns_per_s);
        const nanos = @mod(timestamp, std.time.ns_per_s);

        // Print structured log entry
        stdout.print("[{d}.{d:0>9}] ", .{ seconds, nanos }) catch return;

        // Print severity level
        const level_text = switch (record.severity_number) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .@"error" => "ERROR",
            .fatal => "FATAL",
            else => "UNKN ",
        };
        stdout.print("[{s}] ", .{level_text}) catch return;

        // Print message body
        if (record.body) |body| {
            switch (body) {
                .string => |s| stdout.print("{s}", .{s}) catch return,
                .int => |i| stdout.print("{}", .{i}) catch return,
                .float => |f| stdout.print("{d}", .{f}) catch return,
                .bool => |b| stdout.print("{}", .{b}) catch return,
                else => stdout.print("<unsupported type>", .{}) catch return,
            }
        }

        // Print attributes if present
        if (record.attributes.len > 0) {
            stdout.print(" | ", .{}) catch return;
            for (record.attributes, 0..) |kv, i| {
                if (i > 0) stdout.print(", ", .{}) catch return;
                stdout.print("{s}=", .{kv.key}) catch return;
                switch (kv.value) {
                    .string => |s| stdout.print("\"{s}\"", .{s}) catch return,
                    .int => |n| stdout.print("{}", .{n}) catch return,
                    .float => |f| stdout.print("{d}", .{f}) catch return,
                    .bool => |b| stdout.print("{}", .{b}) catch return,
                    else => stdout.print("\"<complex>\"", .{}) catch return,
                }
            }
        }

        stdout.print("\n", .{}) catch return;
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        _ = ptr;
        _ = allocator;
        // Console handler has no resources to clean up
    }

    pub fn create(allocator: std.mem.Allocator) !LogHandler {
        const handler = try allocator.create(ConcreteConsoleHandler);
        handler.* = ConcreteConsoleHandler{};
        return LogHandler{
            .ptr = handler,
            .vtable = &vtable,
        };
    }
};

/// OTLP handler implementation
const ConcreteOtlpHandler = struct {
    exporter: *otel_exporters.otlp.OtlpLogExporter,
    allocator: std.mem.Allocator,

    const vtable = LogHandler.VTable{
        .handle = handleImpl,
        .deinit = deinitImpl,
    };

    fn handleImpl(ptr: *anyopaque, ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void {
        _ = ctx;
        const self: *ConcreteOtlpHandler = @ptrCast(@alignCast(ptr));

        // Create a single-record slice for export
        const records = [_]otel_api.logs.LogRecord{record};

        // Export the record (ignore errors for now - in production, you'd want proper error handling)
        const result = self.exporter.@"export"(&records, resource);
        if (result != .success) {
            std.log.err("Failed to export log record to OTLP", .{});
        }
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ConcreteOtlpHandler = @ptrCast(@alignCast(ptr));
        allocator.destroy(self.exporter);
        allocator.destroy(self);
    }

    pub fn create(allocator: std.mem.Allocator, config: otel_exporters.otlp.OtlpExporterConfig) !LogHandler {
        const exporter = try allocator.create(otel_exporters.otlp.OtlpLogExporter);
        exporter.* = otel_exporters.otlp.OtlpLogExporter.init(allocator, config);

        const handler = try allocator.create(ConcreteOtlpHandler);
        handler.* = ConcreteOtlpHandler{
            .exporter = exporter,
            .allocator = allocator,
        };

        return LogHandler{
            .ptr = handler,
            .vtable = &vtable,
        };
    }
};

/// No-op handler implementation
const ConcreteNoopHandler = struct {
    const vtable = LogHandler.VTable{
        .handle = handleImpl,
        .deinit = deinitImpl,
    };

    fn handleImpl(ptr: *anyopaque, ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void {
        _ = ptr;
        _ = ctx;
        _ = record;
        _ = resource;
        // No-op: do nothing
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        _ = ptr;
        _ = allocator;
        // No-op handler has no resources to clean up
    }

    pub fn create(allocator: std.mem.Allocator) !LogHandler {
        const handler = try allocator.create(ConcreteNoopHandler);
        handler.* = ConcreteNoopHandler{};
        return LogHandler{
            .ptr = handler,
            .vtable = &vtable,
        };
    }
};

/// Test handler that wraps a function pointer (for testing purposes)
const TestFunctionHandler = struct {
    handler_fn: *const fn (ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void,

    const vtable = LogHandler.VTable{
        .handle = handleImpl,
        .deinit = deinitImpl,
    };

    fn handleImpl(ptr: *anyopaque, ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void {
        const self: *TestFunctionHandler = @ptrCast(@alignCast(ptr));
        self.handler_fn(ctx, record, resource);
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *TestFunctionHandler = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }

    pub fn create(allocator: std.mem.Allocator, handler_fn: *const fn (ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void) !LogHandler {
        const handler = try allocator.create(TestFunctionHandler);
        handler.* = TestFunctionHandler{
            .handler_fn = handler_fn,
        };
        return LogHandler{
            .ptr = handler,
            .vtable = &vtable,
        };
    }
};

/// RAII handle for logging setup that manages resource cleanup
pub const LoggingSetup = struct {
    allocator: std.mem.Allocator,
    handler_ptr: *LogHandler,
    sdk_provider: *sdk_logs.StandardLoggerProvider,
    api_provider: *otel_api.logs.LoggerProvider,

    pub fn deinit(self: *@This()) void {
        self.handler_ptr.deinit(self.allocator);
        self.allocator.destroy(self.handler_ptr);
        self.api_provider.deinit();
        self.allocator.destroy(self.api_provider);
        self.allocator.destroy(self.sdk_provider);
        otel_api.provider_registry.resetGlobalLoggerProvider();
    }
};

/// Error types for setup operations
pub const SetupError = error{
    AllocationFailed,
    ProviderCreationFailed,
    GlobalRegistrationFailed,
} || std.mem.Allocator.Error;

/// OTLP logging setup with custom configuration
pub fn otlpLogging(allocator: std.mem.Allocator, config: otel_exporters.otlp.OtlpExporterConfig) SetupError!LoggingSetup {
    // Create OTLP handler
    const handler = ConcreteOtlpHandler.create(allocator, config) catch |err| switch (err) {
        error.OutOfMemory => return SetupError.AllocationFailed,
    };

    return setupWithHandler(allocator, handler, .info);
}

/// Console logging setup with configurable minimum severity level
pub fn consoleLogging(allocator: std.mem.Allocator, min_level: otel_api.logs.Severity) SetupError!LoggingSetup {
    // Create console handler
    const handler = ConcreteConsoleHandler.create(allocator) catch |err| switch (err) {
        error.OutOfMemory => return SetupError.AllocationFailed,
    };

    return setupWithHandler(allocator, handler, min_level);
}

/// Setup no-op logging (disables all logging)
pub fn noopLogging(allocator: std.mem.Allocator) SetupError!LoggingSetup {
    // Create no-op handler
    const handler = ConcreteNoopHandler.create(allocator) catch |err| switch (err) {
        error.OutOfMemory => return SetupError.AllocationFailed,
    };

    return setupWithHandler(allocator, handler, .trace);
}

/// Setup with a custom log handler
pub fn setupWithHandler(
    allocator: std.mem.Allocator,
    handler: LogHandler,
    min_level: otel_api.logs.Severity,
) SetupError!LoggingSetup {
    // Static dispatch function that calls the LogHandler interface
    const handlerDispatch = struct {
        fn dispatch(context: *anyopaque, ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void {
            const handler_ptr: *LogHandler = @ptrCast(@alignCast(context));
            handler_ptr.handle(ctx, record, resource);
        }
    }.dispatch;

    // Create SDK logger provider on heap
    const sdk_provider = try allocator.create(sdk_logs.StandardLoggerProvider);
    
    // We need to create a stable handler pointer for the provider
    const handler_ptr = try allocator.create(LogHandler);
    handler_ptr.* = handler;

    sdk_provider.* = try sdk_logs.StandardLoggerProvider.init(allocator, handler_ptr, handlerDispatch, null);

    // Set minimum severity level for all loggers from this provider
    // Note: This is a simplified approach - in a full implementation,
    // we'd want per-logger configuration
    _ = min_level; // TODO: Add severity filtering to provider

    // Wrap SDK provider for API use
    const api_provider = bridge.wrapStandardProvider(allocator, sdk_provider) catch |err| switch (err) {
        error.OutOfMemory => return SetupError.AllocationFailed,
    };

    // Register globally
    otel_api.provider_registry.setGlobalLoggerProvider(api_provider);
    
    return LoggingSetup{
        .allocator = allocator,
        .handler_ptr = handler_ptr,
        .sdk_provider = sdk_provider,
        .api_provider = api_provider,
    };
}

test "console logging setup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a memory buffer to capture console output
    var output_buffer = std.ArrayList(u8).init(allocator);
    defer output_buffer.deinit();

    const TestState = struct {
        var buffer: ?*std.ArrayList(u8) = null;
    };
    TestState.buffer = &output_buffer;

    const BufferedConsoleHandler = struct {
        fn handler(ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void {
            _ = ctx;
            _ = resource;
            if (TestState.buffer) |buffer| {
                const writer = buffer.writer();

                // Format similar to console handler
                if (record.timestamp_ns) |timestamp| {
                    const seconds = @divFloor(timestamp, std.time.ns_per_s);
                    const nanos = @mod(timestamp, std.time.ns_per_s);
                    writer.print("[{d}.{d:0>9}] ", .{ seconds, nanos }) catch return;
                }

                // Print severity level
                const severity = record.severity_number;
                const level_text = switch (severity) {
                    .trace => "TRACE",
                    .debug => "DEBUG",
                    .info => "INFO ",
                    .warn => "WARN ",
                    .@"error" => "ERROR",
                    .fatal => "FATAL",
                    else => "UNKN ",
                };
                writer.print("[{s}] ", .{level_text}) catch return;

                // Print message body
                if (record.body) |body| {
                    switch (body) {
                        .string => |s| writer.print("{s}", .{s}) catch return,
                        .int => |i| writer.print("{}", .{i}) catch return,
                        .float => |f| writer.print("{d}", .{f}) catch return,
                        .bool => |b| writer.print("{}", .{b}) catch return,
                        else => writer.print("<unsupported type>", .{}) catch return,
                    }
                }

                writer.print("\n", .{}) catch return;
            }
        }
    };

    // Setup with buffered console handler that captures output
    const handler = try TestFunctionHandler.create(allocator, BufferedConsoleHandler.handler);
    var setup = try setupWithHandler(allocator, handler, .info);
    defer setup.deinit();

    // Get a logger and test it
    const logger = try otel_api.provider_registry.getGlobalLogger("test.setup");
    const ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    // This should write to our buffer instead of stdout
    logger.info(ctx, "Test message from quick setup", .{});

    // Verify we got an SDK logger, not noop
    try testing.expect(logger.* == .sdk);

    // Verify the console output was captured in the buffer
    try testing.expect(output_buffer.items.len > 0);
    try testing.expect(std.mem.containsAtLeast(u8, output_buffer.items, 1, "Test message from quick setup"));
    try testing.expect(std.mem.containsAtLeast(u8, output_buffer.items, 1, "[INFO ]"));

    // Clean up test state
    TestState.buffer = null;
}

test "custom handler setup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestState = struct {
        var message_count: usize = 0;
        var last_message: ?[]const u8 = null;
    };
    TestState.message_count = 0;
    TestState.last_message = null;

    const TestHandler = struct {
        fn handler(ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void {
            _ = ctx;
            _ = resource;
            TestState.message_count += 1;
            if (record.body) |body| {
                switch (body) {
                    .string => |s| TestState.last_message = s,
                    else => {},
                }
            }
        }
    };

    // Setup with custom handler
    const handler = try TestFunctionHandler.create(allocator, TestHandler.handler);
    var setup = try setupWithHandler(allocator, handler, .debug);
    defer setup.deinit();

    // Test logging
    const logger = try otel_api.provider_registry.getGlobalLogger("test.custom");
    const ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    logger.info(ctx, "Custom handler test", .{});

    try testing.expectEqual(@as(usize, 1), TestState.message_count);
    try testing.expectEqualStrings("Custom handler test", TestState.last_message.?);

    // Handler state is automatically cleaned up with defer
}

test "noop logging setup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Setup noop logging
    var setup = try noopLogging(allocator);
    defer setup.deinit();

    // Get logger and verify it's SDK-backed
    const logger = try otel_api.provider_registry.getGlobalLogger("test.noop");
    try testing.expect(logger.* == .sdk);
}

test "logging setup cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test that logging setup is properly cleaned up
    {
        var setup = try consoleLogging(allocator, .info);
        defer setup.deinit();

        // Verify we have an SDK provider while setup is active
        const logger = try otel_api.provider_registry.getGlobalLogger("test.cleanup");
        try testing.expect(logger.* == .sdk);
    }

    // After deinit, we should be back to noop
    const provider = otel_api.provider_registry.getGlobalLoggerProvider();
    try testing.expect(provider.* == .noop);
}

test "shutdown prevents memory leaks" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a memory buffer to capture console output
    var output_buffer = std.ArrayList(u8).init(allocator);
    defer output_buffer.deinit();

    const TestState = struct {
        var buffer: ?*std.ArrayList(u8) = null;
    };
    TestState.buffer = &output_buffer;

    const BufferedConsoleHandler = struct {
        fn handler(ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void {
            _ = ctx;
            _ = resource;
            if (TestState.buffer) |buffer| {
                const writer = buffer.writer();

                // Print message body
                if (record.body) |body| {
                    switch (body) {
                        .string => |s| writer.print("{s}", .{s}) catch return,
                        .int => |i| writer.print("{}", .{i}) catch return,
                        .float => |f| writer.print("{d}", .{f}) catch return,
                        .bool => |b| writer.print("{}", .{b}) catch return,
                        else => writer.print("<unsupported type>", .{}) catch return,
                    }
                }
                writer.print("\n", .{}) catch return;
            }
        }
    };

    // Setup with buffered console handler that captures output
    const handler = try TestFunctionHandler.create(allocator, BufferedConsoleHandler.handler);
    var setup = try setupWithHandler(allocator, handler, .info);
    defer setup.deinit();

    // Get a logger and use it to create internal resources
    const logger = try otel_api.provider_registry.getGlobalLogger("test.shutdown.leak");
    const ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    // Log something to ensure internal structures are allocated
    logger.info(ctx, "Test message for shutdown leak test", .{});

    // Verify we have an SDK logger
    try testing.expect(logger.* == .sdk);

    // Resources will be cleaned up by defer setup.deinit()
    // Clean up test state
    TestState.buffer = null;
}
test "multiple setups work independently" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const NoopHandler = struct {
        fn handler(ctx: otel_api.Context, record: otel_api.logs.LogRecord, resource: *const Resource) void {
            _ = ctx;
            _ = record;
            _ = resource;
        }
    };

    // Test that we can create and clean up multiple setups sequentially
    {
        const handler1 = try TestFunctionHandler.create(allocator, NoopHandler.handler);
        var setup1 = try setupWithHandler(allocator, handler1, .info);
        defer setup1.deinit();

        const logger1 = try otel_api.provider_registry.getGlobalLogger("test.multi1");
        try testing.expect(logger1.* == .sdk);
    }

    // Should be back to noop
    const provider_between = otel_api.provider_registry.getGlobalLoggerProvider();
    try testing.expect(provider_between.* == .noop);

    {
        const handler2 = try TestFunctionHandler.create(allocator, NoopHandler.handler);
        var setup2 = try setupWithHandler(allocator, handler2, .info);
        defer setup2.deinit();

        const logger2 = try otel_api.provider_registry.getGlobalLogger("test.multi2");
        try testing.expect(logger2.* == .sdk);
    }

    // Should be back to noop again
    const provider_final = otel_api.provider_registry.getGlobalLoggerProvider();
    try testing.expect(provider_final.* == .noop);
}
