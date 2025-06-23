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
    bridge: BridgeLogProcessor,

    /// Called when a log record is emitted
    pub fn onEmit(self: *const LogProcessor, record: LogRecord, ctx: Context, resource: Resource) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.onEmitFn(processor.processor_ptr, record, ctx, resource),
        }
    }

    /// Force flush any buffered log records
    pub fn forceFlush(self: *LogProcessor, timeout_ms: ?u64) ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |processor| processor.forceFlushFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Shutdown the processor
    pub fn shutdown(self: *LogProcessor, timeout_ms: ?u64) ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |processor| processor.shutdownFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Clean up processor resources
    pub fn deinit(self: *const LogProcessor) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.deinitFn(processor.processor_ptr),
        }
    }

    /// Destroy processor memory
    pub fn destroy(self: *const LogProcessor) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.destroyFn(processor.processor_ptr),
        }
    }
};

/// Interface for bridging to a more complex processor.
pub const BridgeLogProcessor = struct {
    processor_ptr: *anyopaque,
    onEmitFn: *const fn (processor_ptr: *anyopaque, record: LogRecord, ctx: Context, resource: Resource) void,
    forceFlushFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    shutdownFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    deinitFn: *const fn (processor_ptr: *anyopaque) void,
    destroyFn: *const fn (processor_ptr: *anyopaque) void,

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
            pub fn destroy(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.destroy(self);
            }
        };

        return .{
            .processor_ptr = ptr,
            .onEmitFn = VTable.onEmit,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
            .destroyFn = VTable.destroy,
        };
    }
};
