//! OpenTelemetry Log Processor Interface
//!
//! This module defines the LogRecordProcessor interface for processing log records
//! in the OpenTelemetry SDK. Processors receive log records from loggers
//! and are responsible for batching, filtering, and forwarding them to exporters.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md#logrecordprocessor

const std = @import("std");
const api = @import("otel-api");
const sdk = struct {
    const LogRecord = @import("log_record.zig").LogRecord;
    const LogExporter = @import("exporter.zig").LogExporter;
    const Resource = @import("../resource/resource.zig").Resource;
};

/// LogRecordProcessor interface using tagged union for polymorphism
pub const LogRecordProcessor = union(enum) {
    noop: void,
    bridge: BridgeLogRecordProcessor,

    /// Called when a log record is emitted
    pub fn onEmit(self: *const LogRecordProcessor, record: sdk.LogRecord, ctx: api.Context, resource: sdk.Resource) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.onEmitFn(processor.processor_ptr, record, ctx, resource),
        }
    }

    /// Force flush any buffered log records
    pub fn forceFlush(self: *LogRecordProcessor, timeout_ms: ?u64) api.common.ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |processor| processor.forceFlushFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Shutdown the processor
    pub fn shutdown(self: *LogRecordProcessor, timeout_ms: ?u64) api.common.ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |processor| processor.shutdownFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Clean up processor resources
    pub fn deinit(self: *const LogRecordProcessor) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.deinitFn(processor.processor_ptr),
        }
    }

    /// Destroy processor memory
    pub fn destroy(self: *const LogRecordProcessor) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.destroyFn(processor.processor_ptr),
        }
    }

    /// Check if this processor would process a log record with given parameters
    pub fn enabled(
        self: *const LogRecordProcessor,
        ctx: api.Context,
        scope: api.InstrumentationScope,
        severity: ?api.logs.Severity,
        event_name: ?[]const u8,
    ) bool {
        return switch (self.*) {
            .noop => false, // noop processor never processes anything
            .bridge => |processor| processor.enabledFn(
                processor.processor_ptr,
                ctx,
                scope,
                severity,
                event_name,
            ),
        };
    }
};

/// Interface for bridging to a more complex processor.
pub const BridgeLogRecordProcessor = struct {
    processor_ptr: *anyopaque,
    onEmitFn: *const fn (processor_ptr: *anyopaque, record: sdk.LogRecord, ctx: api.Context, resource: sdk.Resource) void,
    forceFlushFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) api.common.ProcessResult,
    shutdownFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) api.common.ProcessResult,
    deinitFn: *const fn (processor_ptr: *anyopaque) void,
    destroyFn: *const fn (processor_ptr: *anyopaque) void,
    enabledFn: *const fn (
        processor_ptr: *anyopaque,
        ctx: api.Context,
        scope: api.InstrumentationScope,
        severity: ?api.logs.Severity,
        event_name: ?[]const u8,
    ) bool,

    pub fn init(ptr: anytype) BridgeLogRecordProcessor {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn onEmit(pointer: *anyopaque, record: sdk.LogRecord, ctx: api.Context, resource: sdk.Resource) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.onEmit(self, record, ctx, resource);
            }
            pub fn forceFlush(pointer: *anyopaque, timeout_ms: ?u64) api.common.ProcessResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.forceFlush(self, timeout_ms);
            }
            pub fn shutdown(pointer: *anyopaque, timeout_ms: ?u64) api.common.ProcessResult {
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
            pub fn enabled(
                pointer: *anyopaque,
                ctx: api.Context,
                scope: api.InstrumentationScope,
                severity: ?api.logs.Severity,
                event_name: ?[]const u8,
            ) bool {
                const self: T = @ptrCast(@alignCast(pointer));

                if (@hasDecl(ptr_info.pointer.child, "enabled")) {
                    return ptr_info.pointer.child.enabled(self, ctx, scope, severity, event_name);
                } else {
                    return true;
                }
            }
        };

        return .{
            .processor_ptr = ptr,
            .onEmitFn = VTable.onEmit,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
            .destroyFn = VTable.destroy,
            .enabledFn = VTable.enabled,
        };
    }
};
