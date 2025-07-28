const std = @import("std");
const api = @import("otel-api");
const sdk = struct {
    const InstrumentationScopeMapContext = @import("../common/scope_context.zig").InstrumentationScopeMapContext;
    const LogRecordProcessor = @import("processor.zig").LogRecordProcessor;
    const Logger = @import("logger.zig").Logger;
    const PipelineBuilder = @import("../common/pipeline.zig").PipelineBuilder;
    const Resource = @import("../resource/resource.zig").Resource;
    const ResourceBuilder = @import("../resource/resource.zig").ResourceBuilder;
};

/// Basic logger provider with caching
pub const LoggerProvider = struct {
    // internal state fields
    allocator: std.mem.Allocator,
    resource: sdk.Resource,
    cache: std.HashMapUnmanaged(api.InstrumentationScope, *sdk.Logger, sdk.InstrumentationScopeMapContext, 80),
    processors: std.ArrayListUnmanaged(sdk.LogRecordProcessor),
    mutex: std.Thread.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        resource: sdk.Resource,
    ) LoggerProvider {
        return .{
            .allocator = allocator,
            .resource = resource,
            .cache = .empty,
            .processors = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *LoggerProvider) void {
        // Iterate over all the loggers to clean them up.
        var iter = self.cache.iterator();
        while (iter.next()) |kv| {
            // Clean up the logger and the hash key.
            kv.key_ptr.deinitOwned(self.allocator);
            kv.value_ptr.*.deinit();
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.cache.deinit(self.allocator);

        // Iterate over the processors.
        for (self.processors.items) |processor| {
            // Clean up the processor.
            processor.deinit();
            processor.destroy();
        }
        self.processors.deinit(self.allocator);

        // Clean up the resource.
        self.resource.deinitOwned(self.allocator);
    }

    pub fn destroy(self: *LoggerProvider) void {
        self.allocator.destroy(self);
    }

    /// Interface definde method to get a logger.
    pub fn getLoggerWithScope(self: *LoggerProvider, scope: api.InstrumentationScope) !api.logs.Logger {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check cache first
        if (self.cache.get(scope)) |logger| {
            // Already created, so return the type erased interface.
            return logger.logger();
        }

        // Create a locally owned Scope.
        const owned_scope = try api.InstrumentationScope.initOwned(self.allocator, scope);
        errdefer owned_scope.deinitOwned(self.allocator);

        // Create new SDK logger
        const sdk_logger = try self.allocator.create(sdk.Logger);
        errdefer self.allocator.destroy(sdk_logger);

        // TODO: Why is the invalid hard-coded here? Should come from config.
        sdk_logger.* = sdk.Logger.init(self.allocator, .invalid, owned_scope, self);

        // Cache the resulting logger for this scope.
        try self.cache.put(self.allocator, owned_scope, sdk_logger);

        // Return the type erased interface.
        return sdk_logger.logger();
    }

    /// Interface defined method to force the attached processor to flush.
    pub fn forceFlush(self: *LoggerProvider, timeout_ms: ?u64) api.common.FlushResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.processors.items) |*processor| {
            const flush_result = processor.forceFlush(timeout_ms);
            switch (flush_result) {
                .success => {},
                .failure => return .failure,
                .timeout => return .timeout,
            }
        }
        return .success;
    }

    pub fn shutdown(self: *LoggerProvider, timeout_ms: ?u64) api.common.ProcessResult {
        // The mutex block is distinct because the mutex must be released before
        // forceFlush can be called.
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // flag each logger as shutdown to stop collection.
            var iter = self.cache.iterator();
            while (iter.next()) |kv| {
                kv.value_ptr.*.shutdown();
            }
        }

        // Above mutex is now unlocked so forceFlush can take the mutex.
        const flush_result = self.forceFlush(timeout_ms);
        return switch (flush_result) {
            .success => .success,
            .failure => .failure,
            .timeout => .timeout,
        };
    }

    /// Attach a processor to this provider.
    ///
    /// This method is not thread-safe and should only be called during initialization.
    pub fn registerProcessor(self: *LoggerProvider, processor: sdk.LogRecordProcessor) !void {
        try self.processors.append(self.allocator, processor);
    }

    /// Convert the provider into an API interface.
    pub fn loggerProvider(self: *LoggerProvider) api.logs.LoggerProvider {
        return api.logs.LoggerProvider{ .bridge = api.logs.LoggerProviderBridge.init(self) };
    }

    /// Generate a pipelinebuilder for this provider.
    pub fn pipelineBuilder(self: *LoggerProvider) sdk.PipelineBuilder(*LoggerProvider) {
        return .init(self);
    }
};

test "LoggerProvider logger caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = LoggerProvider.init(allocator, resource);
    defer provider.deinit();

    const scope1 = try api.InstrumentationScope.initSimple("test.logger", "1.0.0");
    const scope2 = try api.InstrumentationScope.initSimple("test.logger", "1.0.0"); // Same
    const scope3 = try api.InstrumentationScope.initSimple("other.logger", "1.0.0"); // Different

    const logger1 = try provider.getLoggerWithScope(scope1);
    const logger2 = try provider.getLoggerWithScope(scope2);
    const logger3 = try provider.getLoggerWithScope(scope3);

    // Same scope should return same logger instance
    try testing.expect(logger1.bridge.logger_ptr == logger2.bridge.logger_ptr);
    try testing.expect(logger1.bridge.logger_ptr != logger3.bridge.logger_ptr);

    // Verify cache contains 2 unique entries
    try testing.expectEqual(@as(u32, 2), provider.cache.count());
}

test "LoggerProvider processor registration using pipeline builder" {
    const SimpleLogRecordProcessor = @import("simple_processor.zig").SimpleLogRecordProcessor;
    const MockLogExporter = @import("exporter.zig").MockLogExporter;

    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = LoggerProvider.init(allocator, resource);
    defer provider.deinit();

    try sdk.PipelineBuilder(*LoggerProvider).init(&provider)
        .with(SimpleLogRecordProcessor.PipelineStep.init({}).flowTo(MockLogExporter.PipelineStep.init({})))
        .done();

    try testing.expectEqual(@as(usize, 1), provider.processors.items.len);
}
