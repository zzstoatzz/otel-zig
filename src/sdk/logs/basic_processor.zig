//! Basic Log Processor Implementation
//!
//! This module provides the BasicLogProcessor implementation for processing log records
//! in the OpenTelemetry SDK. The BasicLogProcessor immediately forwards each log record
//! to the configured exporter without any batching or filtering.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md#logrecordprocessor

const std = @import("std");
const otel_api = @import("otel-api");

const Context = otel_api.Context;
const LogRecord = @import("log_record.zig").LogRecord;
const LogExporter = @import("exporter.zig").LogExporter;
const Resource = @import("../resource/resource.zig").Resource;
const ProcessResult = @import("otel-api").common.ProcessResult;

// Import error handler for structured error reporting
const error_handler = otel_api.common;

// Import the processor interface and bridge
const processor_zig = @import("processor.zig");
const LogProcessor = processor_zig.LogProcessor;
const BridgeLogProcessor = processor_zig.BridgeLogProcessor;

/// Basic log processor implementation.
///
/// Implementation is a pass through to the exporter.
pub const BasicLogProcessor = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        BasicLogProcessor,
        LogProcessor,
        void,
        logProcessor,
        _initFn,
        setExporter,
    );
    pub fn _initFn(_: void, allocator: std.mem.Allocator) !BasicLogProcessor {
        return init(allocator, null);
    }

    allocator: std.mem.Allocator,
    exporter: ?LogExporter,
    mutex: std.Thread.Mutex,
    is_shutdown: bool,

    pub fn init(allocator: std.mem.Allocator, exporter: ?LogExporter) BasicLogProcessor {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .is_shutdown = false,
        };
    }

    pub fn deinit(self: *BasicLogProcessor) void {
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    pub fn destroy(self: *BasicLogProcessor) void {
        self.allocator.destroy(self);
    }

    pub fn setExporter(self: *BasicLogProcessor, exporter: ?LogExporter) !void {
        if (self.exporter) |old_exporter| {
            old_exporter.deinit();
            old_exporter.destroy();
        }
        self.exporter = exporter;
    }

    pub fn onEmit(self: *BasicLogProcessor, record: LogRecord, ctx: Context, resource: Resource) void {
        _ = ctx;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return;
        }

        // Export single record immediately
        const records = [_]LogRecord{record};

        if (self.exporter) |exporter| {
            const result = exporter.exportRecords(&records, resource);
            if (result != .success) {
                const message_body = if (record.body) |body| body.string else "(no message)";
                error_handler.reportError(.{
                    .component = .processor,
                    .operation = "log_export",
                    .error_type = .network,
                    .message = "Failed to export log record",
                    .context = message_body,
                });
            }
        }
    }

    pub fn forceFlush(self: *BasicLogProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = if (self.exporter) |*exporter| exporter.forceFlush(timeout_ms) else .success;
        return if (result == .success) .success else .failure;
    }

    pub fn shutdown(self: *BasicLogProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;

        // Shutdown the exporter
        const result = if (self.exporter) |*exporter| exporter.shutdown(timeout_ms) else .success;
        return if (result == .success) .success else .failure;
    }

    pub fn logProcessor(self: *BasicLogProcessor) LogProcessor {
        return LogProcessor{ .bridge = BridgeLogProcessor.init(self) };
    }
};
