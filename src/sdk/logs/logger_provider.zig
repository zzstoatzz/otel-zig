//! OpenTelemetry Logger Provider SDK Implementation
//!
//! This module provides the concrete implementation of LoggerProvider for the SDK.
//! It manages logger lifecycle, caching, and configuration.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md

const std = @import("std");
const otel_api = @import("otel-api");

const Logger = otel_api.logs.Logger;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const KeyValue = otel_api.common.KeyValue;
const Context = otel_api.Context;
const LogRecord = otel_api.logs.LogRecord;

const StandardLogger = @import("logger.zig").StandardLogger;
const createStandardLogger = @import("logger.zig").createStandardLogger;
const bridge = @import("../bridge/root.zig");
const Resource = @import("../resource/resource.zig").Resource;
const getDefaultResource = @import("../resource/resource.zig").getDefaultResource;

/// Key for logger cache based on instrumentation scope
const LoggerCacheKey = struct {
    name: []const u8,
    version: ?[]const u8,
    schema_url: ?[]const u8,

    fn hash(self: LoggerCacheKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(self.name);
        if (self.version) |v| hasher.update(v);
        if (self.schema_url) |url| hasher.update(url);
        return hasher.final();
    }

    fn eql(a: LoggerCacheKey, b: LoggerCacheKey) bool {
        if (!std.mem.eql(u8, a.name, b.name)) return false;

        if (a.version != null and b.version != null) {
            if (!std.mem.eql(u8, a.version.?, b.version.?)) return false;
        } else if (a.version != null or b.version != null) {
            return false;
        }

        if (a.schema_url != null and b.schema_url != null) {
            if (!std.mem.eql(u8, a.schema_url.?, b.schema_url.?)) return false;
        } else if (a.schema_url != null or b.schema_url != null) {
            return false;
        }

        return true;
    }
};

/// Context for logger cache HashMap
const LoggerCacheContext = struct {
    pub fn hash(_: LoggerCacheContext, key: LoggerCacheKey) u64 {
        return key.hash();
    }

    pub fn eql(_: LoggerCacheContext, a: LoggerCacheKey, b: LoggerCacheKey) bool {
        return LoggerCacheKey.eql(a, b);
    }
};

/// LoggerProvider union for SDK implementations
pub const LoggerProvider = union(enum) {
    standard: StandardLoggerProvider,

    /// Get or create a logger with direct parameters
    pub inline fn getLogger(
        self: *LoggerProvider,
        name: []const u8,
        version: ?[]const u8,
        schema_url: ?[]const u8,
        attributes: []const KeyValue,
    ) !*Logger {
        return switch (self.*) {
            .standard => |*provider| provider.getLogger(name, version, schema_url, attributes),
        };
    }

    /// Get or create a logger for the given instrumentation scope
    pub inline fn getLoggerWithScope(self: *LoggerProvider, scope: InstrumentationScope) !*Logger {
        return switch (self.*) {
            .standard => |*provider| provider.getLoggerWithScope(scope),
        };
    }

    /// Convenience method to get a logger with just a name
    pub inline fn getLoggerWithName(self: *LoggerProvider, name: []const u8) !*Logger {
        return self.getLogger(name, null, null, &[_]KeyValue{});
    }

    /// Clean up provider resources
    pub fn deinit(self: *LoggerProvider) void {
        switch (self.*) {
            .standard => |*provider| provider.deinit(),
        }
    }
};

/// Standard logger provider with caching and configuration
pub const StandardLoggerProvider = struct {
    allocator: std.mem.Allocator,
    resource: Resource,
    cache: std.HashMap(LoggerCacheKey, *Logger, LoggerCacheContext, 80),
    handler_context: *anyopaque,
    handler_fn: *const fn (context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void,
    owned_keys: std.ArrayList(LoggerCacheKey),
    loggers: std.ArrayList(*Logger),
    sdk_loggers: std.ArrayList(*StandardLogger),

    pub fn init(
        allocator: std.mem.Allocator,
        handler_context: *anyopaque,
        handler_fn: *const fn (context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void,
        resource: ?Resource,
    ) !StandardLoggerProvider {
        // Set bridge allocator for proper integration
        bridge.setBridgeAllocator(allocator);
        
        // Resolve resource: provided -> default -> error
        const resolved_resource = resource orelse try getDefaultResource(allocator);
        
        return .{
            .allocator = allocator,
            .resource = resolved_resource,
            .cache = std.HashMap(LoggerCacheKey, *Logger, LoggerCacheContext, 80).init(allocator),
            .handler_context = handler_context,
            .handler_fn = handler_fn,
            .owned_keys = std.ArrayList(LoggerCacheKey).init(allocator),
            .loggers = std.ArrayList(*Logger).init(allocator),
            .sdk_loggers = std.ArrayList(*StandardLogger).init(allocator),
        };
    }

    pub fn deinit(self: *StandardLoggerProvider) void {
        // Clean up all API loggers
        for (self.loggers.items) |logger| {
            logger.deinit();
            self.allocator.destroy(logger);
        }
        self.loggers.deinit();
        
        // Clean up all SDK loggers
        for (self.sdk_loggers.items) |sdk_logger| {
            sdk_logger.deinit();
            self.allocator.destroy(sdk_logger);
        }
        self.sdk_loggers.deinit();
        
        self.cache.deinit();

        // Clean up owned keys
        for (self.owned_keys.items) |key| {
            self.allocator.free(key.name);
            if (key.version) |v| self.allocator.free(v);
            if (key.schema_url) |url| self.allocator.free(url);
        }
        self.owned_keys.deinit();
        
        // Clean up owned resource
        self.resource.deinitOwned(self.allocator);
    }

    pub fn getLogger(
        self: *StandardLoggerProvider,
        name: []const u8,
        version: ?[]const u8,
        schema_url: ?[]const u8,
        attributes: []const KeyValue,
    ) !*Logger {
        const scope = try InstrumentationScope.init(name, version, schema_url, attributes);
        return self.getLoggerWithScope(scope);
    }

    pub fn getLoggerWithScope(self: *StandardLoggerProvider, scope: InstrumentationScope) !*Logger {
        const key = LoggerCacheKey{
            .name = scope.name,
            .version = scope.version,
            .schema_url = scope.schema_url,
        };

        // Check cache first
        if (self.cache.get(key)) |logger| {
            return logger;
        }

        // Create new SDK logger
        const sdk_logger = try self.allocator.create(StandardLogger);
        errdefer self.allocator.destroy(sdk_logger);
        
        sdk_logger.* = StandardLogger.init(self.allocator, scope, .invalid, self.handler_context, self.handler_fn, &self.resource);
        
        // Wrap SDK logger for API use
        const logger = try bridge.wrapStandardLogger(self.allocator, sdk_logger);

        // Create owned key for cache
        const owned_key = LoggerCacheKey{
            .name = try self.allocator.dupe(u8, scope.name),
            .version = if (scope.version) |v| try self.allocator.dupe(u8, v) else null,
            .schema_url = if (scope.schema_url) |url| try self.allocator.dupe(u8, url) else null,
        };
        errdefer {
            self.allocator.free(owned_key.name);
            if (owned_key.version) |v| self.allocator.free(v);
            if (owned_key.schema_url) |url| self.allocator.free(url);
        }

        try self.cache.put(owned_key, logger);
        try self.owned_keys.append(owned_key);
        try self.loggers.append(logger);
        try self.sdk_loggers.append(sdk_logger);

        return logger;
    }
};

/// Create a standard logger provider with a handler
pub fn createProvider(
    allocator: std.mem.Allocator,
    handler_context: *anyopaque,
    handler_fn: *const fn (context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void,
) !StandardLoggerProvider {
    return try StandardLoggerProvider.init(allocator, handler_context, handler_fn, null);
}

/// Create a standard logger provider with a handler and resource
pub fn createProviderWithResource(
    allocator: std.mem.Allocator,
    handler_context: *anyopaque,
    handler_fn: *const fn (context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void,
    resource: Resource,
) !StandardLoggerProvider {
    return try StandardLoggerProvider.init(allocator, handler_context, handler_fn, resource);
}

// Tests

test "StandardLoggerProvider caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestHandler = struct {
        fn handler(context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void {
            _ = context;
            _ = ctx;
            _ = record;
            _ = resource;
        }
    };

    var test_context: u8 = 0;
    var provider = try createProvider(allocator, &test_context, TestHandler.handler);
    defer provider.deinit();

    // Get logger with same scope multiple times
    const scope = try InstrumentationScope.initWithName("test.logger");
    const logger1 = try provider.getLoggerWithScope(scope);
    const logger2 = try provider.getLoggerWithScope(scope);
    const logger3 = try provider.getLoggerWithScope(scope);

    // Should return the same instance
    try testing.expectEqual(logger1, logger2);
    try testing.expectEqual(logger2, logger3);

    // Get logger with different scope
    const scope2 = try InstrumentationScope.initWithName("test.logger2");
    const logger4 = try provider.getLoggerWithScope(scope2);

    // Should be different instance
    try testing.expect(logger1 != logger4);
}

test "StandardLoggerProvider convenience methods" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestHandler = struct {
        fn handler(context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void {
            _ = context;
            _ = ctx;
            _ = record;
            _ = resource;
        }
    };

    var test_context: u8 = 0;
    var provider = try createProvider(allocator, &test_context, TestHandler.handler);
    defer provider.deinit();

    // Test getLogger with name
    const logger1 = try provider.getLogger("simple.logger", null, null, &[_]KeyValue{});
    // TODO: API Logger doesn't expose scope directly - need to add getInstrumentationScope method
    // try testing.expectEqualStrings("simple.logger", logger1.scope.name);

    // Test getLogger with version
    const logger2 = try provider.getLogger("versioned.logger", "1.0.0", null, &[_]KeyValue{});
    // TODO: API Logger doesn't expose scope directly - need to add getInstrumentationScope method
    // try testing.expectEqualStrings("versioned.logger", logger2.scope.name);
    // try testing.expectEqualStrings("1.0.0", logger2.scope.version.?);
    
    // Verify we got standard (SDK) loggers, not noop loggers
    try testing.expect(logger1.* == .sdk);
    try testing.expect(logger2.* == .sdk);
    
    // Test that we can access instrumentation scopes through the bridge
    const scope1 = logger1.getInstrumentationScope();
    try testing.expectEqualStrings("simple.logger", scope1.name);
    
    const scope2 = logger2.getInstrumentationScope();
    try testing.expectEqualStrings("versioned.logger", scope2.name);
    try testing.expectEqualStrings("1.0.0", scope2.version.?);
}

test "LoggerProvider scope differentiation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestHandler = struct {
        fn handler(context: *anyopaque, ctx: Context, record: LogRecord, resource: *const Resource) void {
            _ = context;
            _ = ctx;
            _ = record;
            _ = resource;
        }
    };

    var test_context: u8 = 0;
    var provider = try createProvider(allocator, &test_context, TestHandler.handler);
    defer provider.deinit();

    // Same name, different versions
    const logger1 = try provider.getLogger("app.logger", "1.0.0", null, &[_]KeyValue{});
    const logger2 = try provider.getLogger("app.logger", "2.0.0", null, &[_]KeyValue{});
    const logger3 = try provider.getLogger("app.logger", "1.0.0", null, &[_]KeyValue{});

    // Different versions should get different loggers
    try testing.expect(logger1 != logger2);
    // Same version should get cached logger
    try testing.expectEqual(logger1, logger3);

    // Test with schema URL
    const scope1 = try InstrumentationScope.init("test", "1.0", "http://schema.v1", &.{});
    const scope2 = try InstrumentationScope.init("test", "1.0", "http://schema.v2", &.{});
    const scope3 = try InstrumentationScope.init("test", "1.0", "http://schema.v1", &.{});

    const logger4 = try provider.getLoggerWithScope(scope1);
    const logger5 = try provider.getLoggerWithScope(scope2);
    const logger6 = try provider.getLoggerWithScope(scope3);

    // Different schema URLs should get different loggers
    try testing.expect(logger4 != logger5);
    // Same everything should get cached logger
    try testing.expectEqual(logger4, logger6);
}