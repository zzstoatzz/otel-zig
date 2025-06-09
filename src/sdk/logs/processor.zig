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
const LogRecord = @import("log_record.zig").LogRecord;
const LogExporter = @import("exporter.zig").LogExporter;
const Resource = @import("../resource/resource.zig").Resource;
const ProcessResult = @import("otel-api").common.ProcessResult;

/// LogProcessor interface using tagged union for polymorphism
pub const LogProcessor = union(enum) {
    noop: void,
    simple: *SimpleLogProcessor,
    bridge: BridgeLogProcessor,

    /// Called when a log record is emitted
    pub fn onEmit(self: *LogProcessor, record: LogRecord, ctx: Context, resource: Resource) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.onEmit(record, ctx, resource),
            .bridge => |processor| processor.onEmitFn(processor.processor_ptr, record, ctx, resource),
        }
    }

    /// Force flush any buffered log records
    pub fn forceFlush(self: *LogProcessor, timeout_ms: ?u64) ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .simple => |processor| processor.forceFlush(timeout_ms),
            .bridge => |processor| processor.forceFlushFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Shutdown the processor
    pub fn shutdown(self: *LogProcessor, timeout_ms: ?u64) ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .simple => |processor| processor.shutdown(timeout_ms),
            .bridge => |processor| processor.shutdownFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Clean up processor resources
    pub fn deinit(self: *LogProcessor) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.deinit(),
            .bridge => |processor| processor.deinitFn(processor.processor_ptr),
        }
    }
};

/// Simple log processor implementation.
///
/// Implementation is a pass through to the exporter.
pub const SimpleLogProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: LogExporter,
    mutex: std.Thread.Mutex,
    is_shutdown: bool,

    pub fn init(allocator: std.mem.Allocator, exporter: LogExporter) !*SimpleLogProcessor {
        const self = try allocator.create(SimpleLogProcessor);
        self.* = .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .is_shutdown = false,
        };
        return self;
    }

    pub fn deinit(self: *SimpleLogProcessor) void {
        self.exporter.deinit();
        self.allocator.destroy(self);
    }

    pub inline fn onEmit(self: *SimpleLogProcessor, record: LogRecord, ctx: Context, resource: Resource) void {
        _ = ctx;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return;
        }

        // Export single record immediately
        const records = [_]LogRecord{record};
        _ = self.exporter.exportRecords(&records, resource);
    }

    pub inline fn forceFlush(self: *SimpleLogProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = self.exporter.forceFlush(timeout_ms);
        return if (result == .success) .success else .failure;
    }

    pub fn shutdown(self: *SimpleLogProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;

        // Shutdown the exporter
        const result = self.exporter.shutdown(timeout_ms);
        return if (result == .success) .success else .failure;
    }

    pub fn logProcessor(self: *SimpleLogProcessor) LogProcessor {
        return LogProcessor{ .simple = self };
    }
};

/// Interface for bridging to a more complex processor.
pub const BridgeLogProcessor = struct {
    processor_ptr: *anyopaque,
    onEmitFn: *const fn (processor_ptr: *anyopaque, record: LogRecord, ctx: Context, resource: Resource) void,
    forceFlushFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    shutdownFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    deinitFn: *const fn (processor_ptr: *anyopaque) void,

    pub fn init(ptr: anytype) BridgeLogProcessor {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn onEmit(pointer: *anyopaque, record: LogRecord, ctx: Context, resource: Resource) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.onEmit(self, record, ctx, resource);
            }
            pub fn forceFlush(pointer: *anyopaque, timeout_ms: ?u64) ProcessResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.forceFlush(self, timeout_ms);
            }
            pub fn shutdown(pointer: *anyopaque, timeout_ms: ?u64) ProcessResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.shutdown(self, timeout_ms);
            }
            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.deinit(self);
            }
        };

        return .{
            .processor_ptr = ptr,
            .onEmitFn = VTable.onEmit,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
        };
    }
};
