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
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const Context = otel_api.Context;
const LogRecord = otel_api.logs.LogRecord;

const Resource = @import("../resource/resource.zig").Resource;
const LogProcessor = @import("processor.zig").LogProcessor;
const StandardLogger = @import("logger.zig").StandardLogger;

/// Context for logger cache HashMap
const LoggerCacheContext = struct {
    pub fn hash(_: LoggerCacheContext, key: InstrumentationScope) u64 {
        return key.hashCode();
    }

    pub fn eql(_: LoggerCacheContext, a: InstrumentationScope, b: InstrumentationScope) bool {
        return InstrumentationScope.eql(a, b);
    }
};

/// Standard logger provider with caching
pub const StandardLoggerProvider = struct {
    allocator: std.mem.Allocator,
    resource: Resource,
    cache: std.HashMapUnmanaged(InstrumentationScope, *StandardLogger, LoggerCacheContext, 80),
    default_processor: LogProcessor,

    pub fn init(
        allocator: std.mem.Allocator,
        resource: Resource,
        log_processor: LogProcessor,
    ) !*StandardLoggerProvider {
        const self = try allocator.create(StandardLoggerProvider);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .resource = resource,
            .cache = .empty,
            .default_processor = log_processor,
        };
        return self;
    }

    pub fn deinit(self: *StandardLoggerProvider) void {
        // Clean up all API loggers
        var iter = self.cache.iterator();
        while (iter.next()) |kv| {
            kv.key_ptr.deinitOwned(self.allocator);
            kv.value_ptr.*.deinit();
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.cache.deinit(self.allocator);
        self.resource.deinitOwned(self.allocator);
        self.default_processor.deinit();

        // free the pointer associated with this.
        self.allocator.destroy(self);
    }

    pub fn getLoggerWithScope(self: *StandardLoggerProvider, scope: InstrumentationScope) !Logger {
        // Check cache first
        if (self.cache.get(scope)) |logger| {
            return otel_api.logs.Logger{
                .bridge = otel_api.logs.LoggerBridge.init(logger),
            };
        }

        // Create a locally owned Scope.
        const owned_scope = try InstrumentationScope.init(
            try self.allocator.dupe(u8, scope.name),
            if (scope.version) |version| try self.allocator.dupe(u8, version) else null,
            if (scope.schema_url) |url| try self.allocator.dupe(u8, url) else null,
            try otel_api.AttributeKeyValue.initOwnedSlice(self.allocator, scope.attributes),
        );
        errdefer owned_scope.deinitOwned(self.allocator);

        // Create new SDK logger
        const std_logger = try self.allocator.create(StandardLogger);
        errdefer self.allocator.destroy(std_logger);

        std_logger.* = StandardLogger.init(self.allocator, owned_scope, .invalid, self.resource, self.default_processor);

        try self.cache.put(self.allocator, owned_scope, std_logger);

        return otel_api.logs.Logger{
            .bridge = otel_api.logs.LoggerBridge.init(std_logger),
        };
    }

    pub fn loggerProvider(self: *StandardLoggerProvider) otel_api.logs.LoggerProvider {
        return otel_api.logs.LoggerProvider{ .bridge = otel_api.logs.LoggerProviderBridge.init(self) };
    }
};
