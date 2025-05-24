//! OpenTelemetry Logger Provider API
//!
//! This module defines the LoggerProvider interface for creating Logger instances.
//! LoggerProvider manages the lifecycle of loggers and ensures consistent
//! logger instances for the same instrumentation scope.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/api.md#loggerprovider

const std = @import("std");
const Logger = @import("logger.zig").Logger;
const createNoopLogger = @import("logger.zig").createNoopLogger;
const Context = @import("../context/root.zig").Context;
const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const KeyValue = @import("../common/root.zig").KeyValue;

/// LoggerProvider interface using tagged union for polymorphism
pub const LoggerProvider = union(enum) {
    noop: NoopLoggerProvider,
    sdk: SdkProviderBridge,  // SDK provider bridge

    /// Get or create a logger with direct parameters (OpenTelemetry API specification compliant)
    pub inline fn getLogger(
        self: *LoggerProvider,
        name: []const u8,
        version: ?[]const u8,
        schema_url: ?[]const u8,
        attributes: []const KeyValue,
    ) !*Logger {
        return switch (self.*) {
            .noop => |*provider| provider.getLogger(name, version, schema_url, attributes),
            .sdk => |*bridge| bridge.vtable.getLogger(bridge.provider_ptr, name, version, schema_url, attributes),
        };
    }

    /// Get or create a logger for the given instrumentation scope
    pub inline fn getLoggerWithScope(self: *LoggerProvider, scope: InstrumentationScope) !*Logger {
        return switch (self.*) {
            .noop => |*provider| provider.getLoggerWithScope(scope),
            .sdk => |*bridge| bridge.vtable.getLoggerWithScope(bridge.provider_ptr, scope),
        };
    }

    /// Convenience method to get a logger with just a name
    pub inline fn getLoggerWithName(self: *LoggerProvider, name: []const u8) !*Logger {
        return self.getLogger(name, null, null, &[_]KeyValue{});
    }

    /// Convenience method to get a logger with name and version
    pub inline fn getLoggerWithVersion(
        self: *LoggerProvider,
        name: []const u8,
        version: []const u8,
    ) !*Logger {
        return self.getLogger(name, version, null, &[_]KeyValue{});
    }

    /// Clean up provider resources
    pub fn deinit(self: *LoggerProvider) void {
        switch (self.*) {
            .noop => |*provider| provider.deinit(),
            .sdk => |*bridge| bridge.vtable.deinit(bridge.provider_ptr),
        }
    }
};

/// No-operation logger provider that creates noop loggers
pub const NoopLoggerProvider = struct {
    allocator: std.mem.Allocator,
    loggers: std.ArrayList(*Logger),

    pub fn init(allocator: std.mem.Allocator) NoopLoggerProvider {
        return .{
            .allocator = allocator,
            .loggers = std.ArrayList(*Logger).init(allocator),
        };
    }

    pub fn deinit(self: *NoopLoggerProvider) void {
        for (self.loggers.items) |logger| {
            logger.deinit();
            self.allocator.destroy(logger);
        }
        self.loggers.deinit();
    }

    pub fn getLogger(
        self: *NoopLoggerProvider,
        name: []const u8,
        version: ?[]const u8,
        schema_url: ?[]const u8,
        attributes: []const KeyValue,
    ) !*Logger {
        const scope = try InstrumentationScope.init(name, version, schema_url, attributes);
        return self.getLoggerWithScope(scope);
    }

    pub fn getLoggerWithScope(self: *NoopLoggerProvider, scope: InstrumentationScope) !*Logger {
        const logger = try self.allocator.create(Logger);
        errdefer self.allocator.destroy(logger);

        logger.* = createNoopLogger(scope);
        try self.loggers.append(logger);

        return logger;
    }
};

/// Create a no-operation logger provider
pub fn createNoopProvider(allocator: std.mem.Allocator) LoggerProvider {
    return .{ .noop = NoopLoggerProvider.init(allocator) };
}

test "NoopLoggerProvider basic creation and cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test 1: Create provider without getting any loggers
    {
        var provider = createNoopProvider(allocator);
        defer provider.deinit();
        // Should not crash on deinit even with empty loggers list
    }

    // Test 2: Create provider and get one logger
    {
        var provider = createNoopProvider(allocator);
        defer provider.deinit();
        
        const logger = try provider.getLoggerWithName("test.logger");
        try testing.expect(logger.* == .noop);
    }
}

test "NoopLoggerProvider operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = createNoopProvider(allocator);
    defer provider.deinit();

    // Get logger with different scopes
    const logger1 = try provider.getLoggerWithName("test.logger1");
    const logger2 = try provider.getLoggerWithName("test.logger2");

    // Both should be noop loggers
    try testing.expect(logger1.* == .noop);
    try testing.expect(logger2.* == .noop);

    // Test logger functionality
    const ctx = Context.empty(allocator);
    logger1.info(ctx, "Test message from logger1", .{});
    logger2.warn(ctx, "Test message from logger2", .{});
}

test "LoggerProvider convenience methods" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = createNoopProvider(allocator);
    defer provider.deinit();

    // Test getLoggerWithName
    const logger1 = try provider.getLoggerWithName("simple.logger");
    try testing.expect(logger1.* == .noop);
    try testing.expectEqualStrings("simple.logger", logger1.getInstrumentationScope().name);

    // Test getLoggerWithVersion
    const logger2 = try provider.getLoggerWithVersion("versioned.logger", "1.0.0");
    try testing.expect(logger2.* == .noop);
    try testing.expectEqualStrings("versioned.logger", logger2.getInstrumentationScope().name);
    try testing.expectEqualStrings("1.0.0", logger2.getInstrumentationScope().version.?);
}

/// Virtual table for SDK logger provider implementations
pub const SdkProviderVTable = struct {
    getLogger: *const fn (provider_ptr: *anyopaque, name: []const u8, version: ?[]const u8, schema_url: ?[]const u8, attributes: []const KeyValue) anyerror!*Logger,
    getLoggerWithScope: *const fn (provider_ptr: *anyopaque, scope: InstrumentationScope) anyerror!*Logger,
    deinit: *const fn (provider_ptr: *anyopaque) void,
};

/// Bridge structure that holds SDK provider pointer and vtable
pub const SdkProviderBridge = struct {
    provider_ptr: *anyopaque,
    vtable: SdkProviderVTable,
};

test "LoggerProvider spec-compliant getLogger API" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = createNoopProvider(allocator);
    defer provider.deinit();

    // Test spec-compliant API with all parameters
    const attributes = [_]KeyValue{
        KeyValue.init("key1", @import("../common/root.zig").AttributeValue{ .string = "value1" }),
        KeyValue.init("key2", @import("../common/root.zig").AttributeValue{ .int = 42 }),
    };

    const logger1 = try provider.getLogger("test.service", "1.0.0", "https://schema.example.com", &attributes);
    try testing.expect(logger1.* == .noop);

    const scope1 = logger1.getInstrumentationScope();
    try testing.expectEqualStrings("test.service", scope1.name);
    try testing.expectEqualStrings("1.0.0", scope1.version.?);
    try testing.expectEqualStrings("https://schema.example.com", scope1.schema_url.?);
    try testing.expectEqual(@as(usize, 2), scope1.attributes.len);

    // Test with minimal parameters (only name)
    const logger2 = try provider.getLogger("minimal.service", null, null, &[_]KeyValue{});
    try testing.expect(logger2.* == .noop);

    const scope2 = logger2.getInstrumentationScope();
    try testing.expectEqualStrings("minimal.service", scope2.name);
    try testing.expect(scope2.version == null);
    try testing.expect(scope2.schema_url == null);
    try testing.expectEqual(@as(usize, 0), scope2.attributes.len);
}