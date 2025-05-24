//! SDK Logger Provider Bridge
//!
//! This module provides bridge adapters that wrap SDK logger provider implementations
//! to work seamlessly with the API LoggerProvider interface using virtual tables.

const std = @import("std");
const otel_api = @import("otel-api");
const sdk_logs = @import("../logs/root.zig");
const logger_bridge = @import("logger_bridge.zig");

const Context = otel_api.Context;
const Logger = otel_api.logs.Logger;
const LoggerProvider = otel_api.logs.LoggerProvider;
const LogRecord = otel_api.logs.LogRecord;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const KeyValue = otel_api.common.KeyValue;
const SdkProviderVTable = otel_api.logs.SdkProviderVTable;

const StandardLoggerProvider = sdk_logs.StandardLoggerProvider;
const Resource = @import("../resource/resource.zig").Resource;

/// Wrap a StandardLoggerProvider for use with the API
pub fn wrapStandardProvider(allocator: std.mem.Allocator, sdk_provider: *StandardLoggerProvider) !*LoggerProvider {
    const api_provider = try allocator.create(LoggerProvider);
    errdefer allocator.destroy(api_provider);

    // Create the vtable for StandardLoggerProvider
    const vtable = SdkProviderVTable{
        .getLogger = standardProviderGetLogger,
        .getLoggerWithScope = standardProviderGetLoggerWithScope,
        .deinit = standardProviderDeinit,
    };

    // Create bridge structure
    const bridge = otel_api.logs.SdkProviderBridge{
        .provider_ptr = @as(*anyopaque, @ptrCast(sdk_provider)),
        .vtable = vtable,
    };

    // Create API provider with SDK variant
    api_provider.* = .{ .sdk = bridge };

    return api_provider;
}

/// Store allocator for bridge operations
var bridge_allocator: ?std.mem.Allocator = null;

/// Set the allocator used for bridge operations
pub fn setBridgeAllocator(allocator: std.mem.Allocator) void {
    bridge_allocator = allocator;
}

// StandardLoggerProvider vtable implementations

fn standardProviderGetLogger(
    provider_ptr: *anyopaque,
    name: []const u8,
    version: ?[]const u8,
    schema_url: ?[]const u8,
    attributes: []const KeyValue,
) !*Logger {
    const provider = @as(*StandardLoggerProvider, @ptrCast(@alignCast(provider_ptr)));

    // SDK provider already returns wrapped API loggers
    return provider.getLogger(name, version, schema_url, attributes);
}

fn standardProviderGetLoggerWithScope(
    provider_ptr: *anyopaque,
    scope: InstrumentationScope,
) !*Logger {
    const provider = @as(*StandardLoggerProvider, @ptrCast(@alignCast(provider_ptr)));

    // SDK provider already returns wrapped API loggers
    return provider.getLoggerWithScope(scope);
}

fn standardProviderDeinit(provider_ptr: *anyopaque) void {
    const provider = @as(*StandardLoggerProvider, @ptrCast(@alignCast(provider_ptr)));
    provider.deinit();
}

test "StandardLoggerProvider bridge" {
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

    var test_context: u8 = 0;
    var sdk_provider = try StandardLoggerProvider.init(allocator, &test_context, TestHandler.handler, null);
    defer sdk_provider.deinit();

    // Wrap SDK provider for API use
    const api_provider = try wrapStandardProvider(allocator, &sdk_provider);
    defer allocator.destroy(api_provider);

    // Test getting logger through API provider
    const logger = try api_provider.getLoggerWithName("test.provider.bridge");

    // Test that logger works
    const ctx = Context.empty(allocator);
    logger.info(ctx, "Test provider bridge message", .{});
    try testing.expectEqual(@as(usize, 1), TestState.log_count);

    // Test instrumentation scope
    const scope = logger.getInstrumentationScope();
    try testing.expectEqualStrings("test.provider.bridge", scope.name);
}

test "StandardLoggerProvider bridge with version" {
    const testing = std.testing;
    const allocator = testing.allocator;

    setBridgeAllocator(allocator);

    const TestHandler = struct {
        fn handler(context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void {
            _ = context;
            _ = ctx;
            _ = record;
            _ = resource;
        }
    };

    var test_context: u8 = 0;
    var sdk_provider = try StandardLoggerProvider.init(allocator, &test_context, TestHandler.handler, null);
    defer sdk_provider.deinit();

    // Wrap SDK provider for API use
    const api_provider = try wrapStandardProvider(allocator, &sdk_provider);
    defer allocator.destroy(api_provider);

    // Test getting logger with version
    const logger = try api_provider.getLoggerWithVersion("test.versioned", "1.0.0");

    // Test instrumentation scope has version
    const scope = logger.getInstrumentationScope();
    try testing.expectEqualStrings("test.versioned", scope.name);
    try testing.expectEqualStrings("1.0.0", scope.version.?);
}

test "StandardLoggerProvider bridge spec-compliant API" {
    const testing = std.testing;
    const allocator = testing.allocator;

    setBridgeAllocator(allocator);

    const TestHandler = struct {
        fn handler(context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void {
            _ = context;
            _ = ctx;
            _ = record;
            _ = resource;
        }
    };

    var test_context: u8 = 0;
    var sdk_provider = try StandardLoggerProvider.init(allocator, &test_context, TestHandler.handler, null);
    defer sdk_provider.deinit();

    // Wrap SDK provider for API use
    const api_provider = try wrapStandardProvider(allocator, &sdk_provider);
    defer allocator.destroy(api_provider);

    // Test spec-compliant API with all parameters
    const attributes = [_]KeyValue{
        KeyValue.init("service.name", otel_api.common.AttributeValue{ .string = "test-service" }),
        KeyValue.init("service.version", otel_api.common.AttributeValue{ .string = "1.0.0" }),
    };

    const logger = try api_provider.getLogger(
        "full.spec.logger",
        "2.0.0",
        "https://schema.example.com",
        &attributes,
    );

    // Verify all scope properties
    const scope = logger.getInstrumentationScope();
    try testing.expectEqualStrings("full.spec.logger", scope.name);
    try testing.expectEqualStrings("2.0.0", scope.version.?);
    try testing.expectEqualStrings("https://schema.example.com", scope.schema_url.?);
    try testing.expectEqual(@as(usize, 2), scope.attributes.len);
}
