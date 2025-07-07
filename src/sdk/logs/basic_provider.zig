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
const FlushResult = otel_api.common.FlushResult;
const Context = otel_api.Context;
const Severity = otel_api.logs.Severity;
const AttributeValue = otel_api.common.AttributeValue;
const TraceId = otel_api.common.TraceId;
const SpanId = otel_api.common.SpanId;

// Import validation functions from API layer
const reportValidationError = otel_api.common.reportValidationError;

const PipelineBuilder = @import("../common/pipeline.zig").PipelineBuilder;
const Resource = @import("../resource/resource.zig").Resource;
const LogProcessor = @import("processor.zig").LogProcessor;
const LogRecord = @import("log_record.zig").LogRecord;
const InstrumentationScopeMapContext = @import("../common/scope_context.zig").InstrumentationScopeMapContext;

const LoggerCacheContext = InstrumentationScopeMapContext;

/// Basic logger provider with caching
pub const BasicLoggerProvider = struct {
    // internal state fields
    allocator: std.mem.Allocator,
    resource: Resource,
    cache: std.HashMapUnmanaged(InstrumentationScope, *BasicLogger, LoggerCacheContext, 80),
    processors: std.ArrayListUnmanaged(LogProcessor),
    mutex: std.Thread.Mutex,

    pub const unconfigured: BasicLoggerProvider = .{
        .allocator = std.heap.page_allocator,
        .resource = Resource.empty,
        .cache = .empty,
        .processors = .empty,
        .mutex = .{},
    };

    pub fn init(
        allocator: std.mem.Allocator,
        resource: Resource,
    ) BasicLoggerProvider {
        return .{
            .allocator = allocator,
            .resource = resource,
            .cache = .empty,
            .processors = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *BasicLoggerProvider) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up the loggers
        var iter = self.cache.iterator();
        while (iter.next()) |kv| {
            // Clean up the logger.
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

    pub fn destroy(self: *BasicLoggerProvider) void {
        self.allocator.destroy(self);
    }

    /// Interface definde method to get a logger.
    ///
    /// The provided scope is copied interally.
    pub fn getLoggerWithScope(self: *BasicLoggerProvider, scope: InstrumentationScope) !Logger {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check cache first
        if (self.cache.get(scope)) |logger| {
            return logger.logger();
        }

        // Create a locally owned Scope.
        const owned_scope = try InstrumentationScope.initOwned(self.allocator, scope);
        errdefer owned_scope.deinitOwned(self.allocator);

        // Create new SDK logger
        const std_logger = try self.allocator.create(BasicLogger);
        errdefer self.allocator.destroy(std_logger);

        std_logger.* = BasicLogger.init(self.allocator, .invalid, owned_scope, self);

        try self.cache.put(self.allocator, owned_scope, std_logger);

        return std_logger.logger();
    }

    /// Interface defined method to force the attached processor to flush.
    pub fn forceFlush(self: *BasicLoggerProvider, timeout_ms: ?u64) FlushResult {
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

    pub fn shutdown(self: *BasicLoggerProvider, timeout_ms: ?u64) otel_api.common.ProcessResult {
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
    pub fn registerProcessor(self: *BasicLoggerProvider, processor: LogProcessor) !void {
        try self.processors.append(self.allocator, processor);
    }

    /// Convert the provider into an API interface.
    pub fn loggerProvider(self: *BasicLoggerProvider) otel_api.logs.LoggerProvider {
        return otel_api.logs.LoggerProvider{ .bridge = otel_api.logs.LoggerProviderBridge.init(self) };
    }

    /// Generate a pipelinebuilder for this provider.
    pub fn pipelineBuilder(self: *BasicLoggerProvider) PipelineBuilder(*BasicLoggerProvider) {
        return .init(self);
    }
};

/// Basic logger implementation with configurable severity and handler
const BasicLogger = struct {
    allocator: std.mem.Allocator,
    min_severity: Severity,
    is_shutdown: std.atomic.Value(bool),
    scope: otel_api.common.InstrumentationScope,
    provider: *BasicLoggerProvider,

    pub fn init(
        allocator: std.mem.Allocator,
        min_severity: Severity,
        instrument_scope: otel_api.common.InstrumentationScope,
        provider_ptr: *BasicLoggerProvider,
    ) BasicLogger {
        return .{
            .allocator = allocator,
            .min_severity = min_severity,
            .is_shutdown = .init(false),
            .scope = instrument_scope,
            .provider = provider_ptr,
        };
    }

    pub fn deinit(self: *BasicLogger) void {
        _ = self;
    }

    pub fn shutdown(self: *BasicLogger) void {
        self.is_shutdown.store(true, .release);
    }

    pub inline fn emitLogRecord(
        self: *BasicLogger,
        ctx: Context,
        severity: ?Severity,
        body: ?AttributeValue,
        attributes: ?[]const AttributeKeyValue,
        timestamp_ns: ?i64,
        observed_timestamp_ns: ?i64,
        event_name: ?[]const u8,
        severity_text: ?[]const u8,
        trace_id: ?TraceId,
        span_id: ?SpanId,
        flags: ?u8,
    ) void {
        if (self.is_shutdown.load(.unordered)) {
            return;
        }

        // Validate parameters in debug mode
        const validated_severity = otel_api.logs.validateSeverity(severity);
        const validated_body = otel_api.logs.validateLogBody(body);
        const validated_attributes = otel_api.logs.validateLogAttributes(attributes);
        const validated_event_name = otel_api.logs.validateEventName(event_name);
        const validated_severity_text = otel_api.logs.validateSeverityText(severity_text);
        const validated_trace_id = otel_api.common.validateTraceId(trace_id);
        const validated_span_id = otel_api.common.validateSpanId(span_id);
        const validated_flags = otel_api.common.validateTraceFlags(flags);

        const record_severity = validated_severity orelse .invalid;

        // Check severity filtering
        if (self.enabled(ctx, record_severity)) {
            // Construct LogRecord from individual parameters
            const record = LogRecord{
                .timestamp_ns = timestamp_ns,
                .observed_timestamp_ns = observed_timestamp_ns,
                .severity_number = record_severity,
                .severity_text = validated_severity_text,
                .body = validated_body,
                .event_name = validated_event_name,
                .attributes = validated_attributes orelse &[_]AttributeKeyValue{},
                .trace_id = validated_trace_id,
                .span_id = validated_span_id,
                .flags = validated_flags,
                .instrumentation_scope = self.scope,
            };

            // This iteration should be safe, as the processors are
            // not able to be changed after the initial setup.
            for (self.provider.processors.items) |processor| {
                processor.onEmit(record, ctx, self.provider.resource);
            }
        }
    }

    pub inline fn enabled(self: *const BasicLogger, ctx: Context, severity: ?Severity) bool {
        if (self.is_shutdown.load(.unordered)) {
            return false;
        }

        // Use INFO level as default when severity is null
        const actual_severity = severity orelse .info;

        // Compare severity levels for filtering
        if (@intFromEnum(actual_severity) < @intFromEnum(self.min_severity)) {
            return false;
        }

        // Check if there are any processors (spec requirement)
        if (self.provider.processors.items.len == 0) {
            return false;
        }

        // Check processors per spec: only return false if ALL processors return false
        for (self.provider.processors.items) |processor| {
            if (processor.enabled(ctx, self.scope, actual_severity, null)) {
                return true; // At least one processor wants this record
            }
        }

        // All processors returned false
        return false;
    }

    pub inline fn enabledWithEvent(
        self: *const BasicLogger,
        ctx: Context,
        severity: ?Severity,
        event_name: []const u8,
    ) bool {
        if (self.is_shutdown.load(.unordered)) {
            return false;
        }

        // Use INFO level as default when severity is null
        const actual_severity = severity orelse .info;

        // Compare severity levels for filtering
        if (@intFromEnum(actual_severity) < @intFromEnum(self.min_severity)) {
            return false;
        }

        // Check if there are any processors (spec requirement)
        if (self.provider.processors.items.len == 0) {
            return false;
        }

        // Check processors per spec: only return false if ALL processors return false
        for (self.provider.processors.items) |processor| {
            if (processor.enabled(ctx, self.scope, actual_severity, event_name)) {
                return true; // At least one processor wants this record
            }
        }

        // All processors returned false
        return false;
    }

    pub inline fn logger(self: *BasicLogger) Logger {
        return otel_api.logs.Logger{
            .bridge = otel_api.logs.LoggerBridge.init(self),
        };
    }
};

// ============================================================================
// TESTS
// ============================================================================

const MockLogExporter = @import("exporter.zig").MockLogExporter;
const BasicLogProcessor = @import("basic_processor.zig").BasicLogProcessor;
const ResourceBuilder = @import("../resource/resource.zig").ResourceBuilder;

test "BasicLoggerProvider lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create resource
    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    // Create provider (takes ownership of resource)
    var provider = BasicLoggerProvider.init(allocator, resource);
    defer provider.deinit();

    try testing.expect(provider.processors.items.len == 0);
    try testing.expect(provider.cache.count() == 0);
}

test "BasicLoggerProvider logger caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicLoggerProvider.init(allocator, resource);
    defer provider.deinit();

    const scope1 = try InstrumentationScope.initSimple("test.logger", "1.0.0");
    const scope2 = try InstrumentationScope.initSimple("test.logger", "1.0.0"); // Same
    const scope3 = try InstrumentationScope.initSimple("other.logger", "1.0.0"); // Different

    const logger1 = try provider.getLoggerWithScope(scope1);
    const logger2 = try provider.getLoggerWithScope(scope2);
    const logger3 = try provider.getLoggerWithScope(scope3);

    // Same scope should return same logger instance
    try testing.expect(logger1.bridge.logger_ptr == logger2.bridge.logger_ptr);
    try testing.expect(logger1.bridge.logger_ptr != logger3.bridge.logger_ptr);

    // Verify cache contains 2 unique entries
    try testing.expectEqual(@as(u32, 2), provider.cache.count());
}

test "BasicLoggerProvider processor registration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicLoggerProvider.init(allocator, resource);
    defer provider.deinit();

    try @import("../common/pipeline.zig").PipelineBuilder(*BasicLoggerProvider).init(&provider)
        .with(BasicLogProcessor.PipelineStep.init({}).flowTo(MockLogExporter.PipelineStep.init({})))
        .done();

    try testing.expectEqual(@as(usize, 1), provider.processors.items.len);
}

test "BasicLogger log emission through pipeline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicLoggerProvider.init(allocator, resource);
    defer provider.deinit();

    // Create mock exporter
    const mock_exporter = try allocator.create(MockLogExporter);
    mock_exporter.* = MockLogExporter.init(allocator);
    // Processor takes ownership of this memory.

    // Create processor (heap-allocated)
    const processor = try allocator.create(BasicLogProcessor);
    processor.* = BasicLogProcessor.init(allocator, mock_exporter.logExporter());

    // Register processor (provider takes ownership)
    try provider.registerProcessor(processor.logProcessor());

    // Get logger
    const scope = try InstrumentationScope.initSimple("test.logger", "1.0.0");
    var logger = try provider.getLoggerWithScope(scope);

    // Emit logs of different severities
    const ctx = Context.init(allocator);

    logger.emitLogRecord(
        ctx,
        .info,
        .{ .string = "Info message" },
        null,
        null,
        null,
        null,
        "INFO",
        null,
        null,
        null,
    );

    logger.emitLogRecord(
        ctx,
        .@"error",
        .{ .string = "Error message" },
        null,
        null,
        null,
        null,
        "ERROR",
        null,
        null,
        null,
    );

    // Verify records were exported
    try testing.expectEqual(@as(usize, 2), mock_exporter.recordCount());

    if (mock_exporter.getRecord(0)) |record| {
        try testing.expectEqual(Severity.info, record.severity_number);
        try testing.expectEqualStrings("Info message", record.body.?.string);
        try testing.expectEqualStrings("INFO", record.severity_text.?);
    }

    if (mock_exporter.getRecord(1)) |record| {
        try testing.expectEqual(Severity.@"error", record.severity_number);
        try testing.expectEqualStrings("Error message", record.body.?.string);
        try testing.expectEqualStrings("ERROR", record.severity_text.?);
    }
}

test "BasicLogger severity filtering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicLoggerProvider.init(allocator, resource);
    defer provider.deinit();

    // Add a processor so enabled() can return true per spec
    const mock_exporter = try allocator.create(MockLogExporter);
    mock_exporter.* = MockLogExporter.init(allocator);

    const processor = try allocator.create(BasicLogProcessor);
    processor.* = BasicLogProcessor.init(allocator, mock_exporter.logExporter());

    try provider.registerProcessor(processor.logProcessor());

    const scope = try InstrumentationScope.initSimple("test.logger", "1.0.0");
    var logger = try provider.getLoggerWithScope(scope);
    const ctx = Context.init(allocator);

    // Test enabled() method - with processor registered, all severities should be enabled
    // since min_severity = .invalid allows all severities through
    try testing.expect(logger.enabled(ctx, .@"error"));
    try testing.expect(logger.enabled(ctx, .warn));
    try testing.expect(logger.enabled(ctx, .info));
    try testing.expect(logger.enabled(ctx, .debug));
    try testing.expect(logger.enabled(ctx, .trace));
}

test "BasicLogger processor enabled() integration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicLoggerProvider.init(allocator, resource);
    defer provider.deinit();

    const scope = try InstrumentationScope.initSimple("test.logger", "1.0.0");
    var logger = try provider.getLoggerWithScope(scope);
    const ctx = Context.init(allocator);

    // Test 1: No processors - should return false per spec
    try testing.expect(!logger.enabled(ctx, .info));
    try testing.expect(!logger.enabledWithEvent(ctx, .info, "test.event"));

    // Test 2: Add processor without enabled() method - should return true (default behavior)
    const mock_exporter = try allocator.create(MockLogExporter);
    mock_exporter.* = MockLogExporter.init(allocator);

    const basic_processor = try allocator.create(BasicLogProcessor);
    basic_processor.* = BasicLogProcessor.init(allocator, mock_exporter.logExporter());

    try provider.registerProcessor(basic_processor.logProcessor());

    // Now enabled() should return true since BasicLogProcessor doesn't implement enabled()
    // and gets the default "true" behavior
    try testing.expect(logger.enabled(ctx, .info));
    try testing.expect(logger.enabledWithEvent(ctx, .info, "test.event"));

    // Test 3: Verify severity filtering still works
    // Since min_severity = .invalid (0), all severities should be enabled
    try testing.expect(logger.enabled(ctx, .@"error"));
    try testing.expect(logger.enabled(ctx, .trace)); // All severities >= .invalid (0)
}

test "BasicLogger shutdown behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicLoggerProvider.init(allocator, resource);
    defer provider.deinit();

    const mock_exporter = try allocator.create(MockLogExporter);
    mock_exporter.* = MockLogExporter.init(allocator);

    const processor = try allocator.create(BasicLogProcessor);
    processor.* = BasicLogProcessor.init(allocator, mock_exporter.logExporter());

    try provider.registerProcessor(processor.logProcessor());

    const scope = try InstrumentationScope.initSimple("test.logger", "1.0.0");
    var logger = try provider.getLoggerWithScope(scope);
    const ctx = Context.init(allocator);

    // Emit log before shutdown
    logger.emitLogRecord(ctx, .info, .{ .string = "Before shutdown" }, null, null, null, null, "INFO", null, null, null);
    try testing.expectEqual(@as(usize, 1), mock_exporter.recordCount());

    // Shutdown provider
    _ = provider.shutdown(null);

    // Try to emit log after shutdown - should be ignored
    logger.emitLogRecord(ctx, .info, .{ .string = "After shutdown" }, null, null, null, null, "INFO", null, null, null);
    try testing.expectEqual(@as(usize, 1), mock_exporter.recordCount()); // Should still be 1

    // Verify the logger reports as not enabled after shutdown
    try testing.expect(!logger.enabled(ctx, .info));
}

test "BasicLoggerProvider flush behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicLoggerProvider.init(allocator, resource);
    defer provider.deinit();

    const mock_exporter = try allocator.create(MockLogExporter);
    mock_exporter.* = MockLogExporter.init(allocator);

    const processor = try allocator.create(BasicLogProcessor);
    processor.* = BasicLogProcessor.init(allocator, mock_exporter.logExporter());

    try provider.registerProcessor(processor.logProcessor());

    // Test successful flush
    const result = provider.forceFlush(1000);
    try testing.expectEqual(FlushResult.success, result);

    // Test flush with failure
    mock_exporter.flush_result = .failure;
    const result2 = provider.forceFlush(1000);
    try testing.expectEqual(FlushResult.failure, result2);
}

test "BasicLogger with attributes and timestamps" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicLoggerProvider.init(allocator, resource);
    defer provider.deinit();

    const mock_exporter = try allocator.create(MockLogExporter);
    mock_exporter.* = MockLogExporter.init(allocator);

    const processor = try allocator.create(BasicLogProcessor);
    processor.* = BasicLogProcessor.init(allocator, mock_exporter.logExporter());
    try provider.registerProcessor(processor.logProcessor());

    const scope = try InstrumentationScope.initSimple("test.logger", "1.0.0");
    var logger = try provider.getLoggerWithScope(scope);
    const ctx = Context.init(allocator);

    // Create attributes
    const attributes = [_]AttributeKeyValue{
        .{ .key = "key1", .value = .{ .string = "value1" } },
        .{ .key = "key2", .value = .{ .int = 42 } },
    };

    const timestamp = 1234567890000000000;
    const observed_timestamp = 1234567890000000001;

    // Emit log with attributes and timestamps
    logger.emitLogRecord(
        ctx,
        .warn,
        .{ .string = "Warning with attributes" },
        &attributes,
        timestamp,
        observed_timestamp,
        "test.event",
        "WARN",
        null,
        null,
        null,
    );

    // Verify the record
    try testing.expectEqual(@as(usize, 1), mock_exporter.recordCount());

    if (mock_exporter.getRecord(0)) |record| {
        try testing.expectEqual(Severity.warn, record.severity_number);
        try testing.expectEqualStrings("Warning with attributes", record.body.?.string);
        try testing.expectEqual(@as(?i64, timestamp), record.timestamp_ns);
        try testing.expectEqual(@as(?i64, observed_timestamp), record.observed_timestamp_ns);
        try testing.expectEqualStrings("test.event", record.event_name.?);
        try testing.expectEqualStrings("WARN", record.severity_text.?);
        try testing.expectEqual(@as(usize, 2), record.attributes.len);
    }
}
