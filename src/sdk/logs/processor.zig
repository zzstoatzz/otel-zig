//! OpenTelemetry Log Processor Interface
//!
//! This module defines the LogProcessor interface for processing log records
//! in the OpenTelemetry SDK. Processors receive log records from loggers
//! and are responsible for batching, filtering, and forwarding them to exporters.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md#logrecordprocessor

const std = @import("std");
const otel_api = @import("otel-api");

const Context = otel_api.Context;
const LogRecord = otel_api.logs.LogRecord;

/// Result of a flush or shutdown operation
pub const ProcessorResult = enum {
    success,
    failure,
    timeout,
};

/// LogProcessor interface using tagged union for polymorphism
pub const LogProcessor = union(enum) {
    simple: *SimpleProcessor,
    multi: *MultiProcessor,
    custom: *CustomProcessor,

    /// Called when a log record is emitted
    pub fn onEmit(self: *LogProcessor, record: LogRecord, ctx: Context) void {
        switch (self.*) {
            .simple => |processor| processor.onEmit(processor, record, ctx),
            .multi => |processor| processor.onEmit(processor, record, ctx),
            .custom => |processor| processor.onEmit(record, ctx),
        }
    }

    /// Force flush any buffered log records
    pub fn forceFlush(self: *LogProcessor, timeout_ms: ?u64) ProcessorResult {
        return switch (self.*) {
            .simple => |processor| processor.forceFlush(processor, timeout_ms),
            .multi => |processor| processor.forceFlush(processor, timeout_ms),
            .custom => |processor| processor.forceFlush(timeout_ms),
        };
    }

    /// Shutdown the processor
    pub fn shutdown(self: *LogProcessor, timeout_ms: ?u64) ProcessorResult {
        return switch (self.*) {
            .simple => |processor| processor.shutdown(processor, timeout_ms),
            .multi => |processor| processor.shutdown(processor, timeout_ms),
            .custom => |processor| processor.shutdown(timeout_ms),
        };
    }

    /// Clean up processor resources
    pub fn deinit(self: *LogProcessor) void {
        switch (self.*) {
            .simple => |processor| processor.deinit(processor),
            .multi => |processor| processor.deinit(processor),
            .custom => |processor| processor.deinit(),
        }
    }
};

/// Interface for simple processor (defined in simple_processor.zig)
pub const SimpleProcessor = struct {
    onEmit: *const fn (self: *SimpleProcessor, record: LogRecord, ctx: Context) void,
    forceFlush: *const fn (self: *SimpleProcessor, timeout_ms: ?u64) ProcessorResult,
    shutdown: *const fn (self: *SimpleProcessor, timeout_ms: ?u64) ProcessorResult,
    deinit: *const fn (self: *SimpleProcessor) void,
};



/// Interface for multi processor (processes through multiple processors)
pub const MultiProcessor = struct {
    onEmit: *const fn (self: *MultiProcessor, record: LogRecord, ctx: Context) void,
    forceFlush: *const fn (self: *MultiProcessor, timeout_ms: ?u64) ProcessorResult,
    shutdown: *const fn (self: *MultiProcessor, timeout_ms: ?u64) ProcessorResult,
    deinit: *const fn (self: *MultiProcessor) void,
};

/// Custom processor with user-provided implementation
pub const CustomProcessor = struct {
    impl: *anyopaque,
    onEmitFn: *const fn (impl: *anyopaque, record: LogRecord, ctx: Context) void,
    forceFlushFn: *const fn (impl: *anyopaque, timeout_ms: ?u64) ProcessorResult,
    shutdownFn: *const fn (impl: *anyopaque, timeout_ms: ?u64) ProcessorResult,
    deinitFn: *const fn (impl: *anyopaque) void,

    pub fn onEmit(self: *CustomProcessor, record: LogRecord, ctx: Context) void {
        self.onEmitFn(self.impl, record, ctx);
    }

    pub fn forceFlush(self: *CustomProcessor, timeout_ms: ?u64) ProcessorResult {
        return self.forceFlushFn(self.impl, timeout_ms);
    }

    pub fn shutdown(self: *CustomProcessor, timeout_ms: ?u64) ProcessorResult {
        return self.shutdownFn(self.impl, timeout_ms);
    }

    pub fn deinit(self: *CustomProcessor) void {
        self.deinitFn(self.impl);
    }
};

/// Create a custom processor
pub fn createCustomProcessor(
    impl: *anyopaque,
    onEmitFn: *const fn (impl: *anyopaque, record: LogRecord, ctx: Context) void,
    forceFlushFn: *const fn (impl: *anyopaque, timeout_ms: ?u64) ProcessorResult,
    shutdownFn: *const fn (impl: *anyopaque, timeout_ms: ?u64) ProcessorResult,
    deinitFn: *const fn (impl: *anyopaque) void,
) CustomProcessor {
    return .{
        .impl = impl,
        .onEmitFn = onEmitFn,
        .forceFlushFn = forceFlushFn,
        .shutdownFn = shutdownFn,
        .deinitFn = deinitFn,
    };
}

test "CustomProcessor operations" {
    const testing = std.testing;

    const TestImpl = struct {
        emit_count: usize = 0,
        flushed: bool = false,
        is_shutdown: bool = false,

        fn onEmit(impl: *anyopaque, record: LogRecord, ctx: Context) void {
            _ = record;
            _ = ctx;
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            self.emit_count += 1;
        }

        fn forceFlush(impl: *anyopaque, timeout_ms: ?u64) ProcessorResult {
            _ = timeout_ms;
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            self.flushed = true;
            return .success;
        }

        fn shutdown(impl: *anyopaque, timeout_ms: ?u64) ProcessorResult {
            _ = timeout_ms;
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            self.is_shutdown = true;
            return .success;
        }

        fn deinit(impl: *anyopaque) void {
            _ = impl;
        }
    };

    var impl = TestImpl{};
    var custom = createCustomProcessor(
        &impl,
        TestImpl.onEmit,
        TestImpl.forceFlush,
        TestImpl.shutdown,
        TestImpl.deinit,
    );

    var processor = LogProcessor{ .custom = &custom };
    defer processor.deinit();

    const ctx = Context.empty(testing.allocator);
    const record = LogRecord{
        .severity_number = .info,
        .body = otel_api.AttributeValue{ .string = "test message" },
    };

    processor.onEmit(record, ctx);
    try testing.expectEqual(@as(usize, 1), impl.emit_count);

    const flush_result = processor.forceFlush(5000);
    try testing.expectEqual(ProcessorResult.success, flush_result);
    try testing.expect(impl.flushed);

    const shutdown_result = processor.shutdown(5000);
    try testing.expectEqual(ProcessorResult.success, shutdown_result);
    try testing.expect(impl.is_shutdown);
}
