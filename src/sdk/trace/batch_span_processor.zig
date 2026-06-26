//! Batch Span Processor
//!
//! This module provides a span processor that batches spans and exports them
//! at regular intervals using a background thread. It uses POSIX threads
//! for cross-platform compatibility.
//!
//! The processor maintains a thread that wakes up at regular intervals to export
//! batched spans via the configured exporter. Spans are queued when they end
//! and exported in batches to improve performance.

const std = @import("std");
const io = std.Options.debug_io;const otel_api = @import("otel-api");
const sdk = struct {
    const Resource = @import("../resource/resource.zig").Resource;
    const trace = struct {
        const SpanData = @import("data.zig").SpanData;
    };
};

const ProcessResult = otel_api.common.ProcessResult;
const ExportResult = otel_api.common.ExportResult;
const RecordingSpan = @import("data.zig").RecordingSpan;
const SpanExporter = @import("exporter.zig").SpanExporter;
const MockSpanExporter = @import("exporter.zig").MockSpanExporter;

// Import error handler for structured error reporting
const error_handler = otel_api.common;

// Import the processor interface and bridge
const processor_zig = @import("processor.zig");
const SpanProcessor = processor_zig.SpanProcessor;
const BridgeSpanProcessor = processor_zig.BridgeSpanProcessor;

/// Configuration for BatchSpanProcessor PipelineStep
pub const BatchConfig = struct {
    export_interval_ms: ?u32 = null,
    max_queue_size: ?usize = null,
};

/// Batch span processor that exports spans at regular intervals
pub const BatchSpanProcessor = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        BatchSpanProcessor,
        SpanProcessor,
        BatchConfig,
        spanProcessor,
        _initFn,
        setExporter,
    );

    pub fn _initFn(self: *BatchSpanProcessor, config: BatchConfig, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, null, config);
        try self.start();
    }

    allocator: std.mem.Allocator,
    exporter: ?SpanExporter,
    mutex: std.Io.Mutex,
    condition: std.Io.Condition = std.Io.Condition.init,
    is_shutdown: std.atomic.Value(bool),
    is_running: std.atomic.Value(bool),
    flush_in_progress: std.atomic.Value(bool),
    export_in_progress: std.atomic.Value(bool),
    flush_complete: std.Io.Condition = std.Io.Condition.init,
    export_complete: std.Io.Condition = std.Io.Condition.init,
    thread: ?std.Thread,
    export_interval_ms: u32,
    max_queue_size: usize,
    span_queue: std.ArrayList(struct { resource: sdk.Resource, data: sdk.trace.SpanData }),

    /// Initialize a new batch span processor
    /// export_interval_ms: How often to export spans (default: 5000ms = 5s)
    /// max_queue_size: Maximum spans to queue before dropping (default: 2048)
    ///
    /// Owner of the processor must destroy the memory.
    pub fn init(
        allocator: std.mem.Allocator,
        exporter: ?SpanExporter,
        config: BatchConfig,
    ) BatchSpanProcessor {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = std.Io.Mutex.init,
            .condition = std.Io.Condition.init,
            .is_shutdown = .init(false),
            .is_running = .init(false),
            .flush_in_progress = .init(false),
            .export_in_progress = .init(false),
            .flush_complete = std.Io.Condition.init,
            .export_complete = std.Io.Condition.init,
            .thread = null,
            .export_interval_ms = config.export_interval_ms orelse 5000,
            .max_queue_size = config.max_queue_size orelse 2048,
            .span_queue = .empty,
        };
    }

    pub fn setExporter(self: *BatchSpanProcessor, exporter: ?SpanExporter) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (exporter) |exp| {
            self.exporter = exp;
        }
    }

    /// Start the background export thread
    pub fn start(self: *BatchSpanProcessor) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.is_running.load(.acquire) or self.thread != null) {
            return;
        }

        self.is_running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, exportThreadFn, .{self});
    }

    /// Stop the background export thread and clean up resources
    pub fn deinit(self: *BatchSpanProcessor) void {
        // Signal shutdown
        self.is_shutdown.store(true, .release);
        self.is_running.store(false, .release);

        self.mutex.lockUncancelable(io);
        self.condition.signal(io);
        self.mutex.unlock(io);

        // Wait for thread to exit
        if (self.thread) |thread| {
            thread.join();
        }

        // Clean up remaining spans
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.span_queue.items) |span| {
            span.data.deinitOwned(self.allocator);
        }
        self.span_queue.deinit(self.allocator);

        // Clean up the exporter
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    pub fn destroy(self: *BatchSpanProcessor) void {
        self.allocator.destroy(self);
    }

    pub fn spanLimits(self: *BatchSpanProcessor) otel_api.trace.Span.Limits {
        _ = self;
        return .default;
    }

    /// Called when a span ends - adds span to batch queue
    pub fn onEnd(self: *BatchSpanProcessor, span: sdk.trace.SpanData, resource: sdk.Resource) void {
        // Fast pre-check without the lock; a racing shutdown is re-checked below.
        if (self.is_shutdown.load(.acquire)) {
            return;
        }

        // Clone the span BEFORE taking the lock. initOwned is the expensive part
        // of onEnd: a deep heap copy of the span name and every attribute (which
        // for DB/HTTP instrumentation includes large SQL/URL strings). Cloning
        // under the mutex serializes every concurrent onEnd — and with many
        // request threads on few cores, a thread preempted mid-copy stalls all
        // the others. That lock convoy turns a flood of sub-millisecond spans
        // into multi-second tail latency (observed downstream: 14 spans/request
        // × 24 concurrent requests → seconds of inter-span gaps). Cloning first
        // keeps the critical section to a capacity check plus a pointer append.
        const cloned_span = sdk.trace.SpanData.initOwned(self.allocator, span) catch |err| {
            error_handler.reportError(.{
                .component = .processor,
                .operation = "span_clone",
                .error_type = .resource_exhausted,
                .message = "Failed to clone span for batching",
                .context = span.name,
                .source_error = err,
            });
            return;
        };

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Re-check under the lock: shutdown may have raced us, and the queue may
        // have filled while we were cloning. Free the clone in either case so it
        // is not leaked (the caller still owns and deinits the original `span`).
        if (self.is_shutdown.load(.acquire) or self.span_queue.items.len >= self.max_queue_size) {
            cloned_span.deinitOwned(self.allocator);
            return;
        }

        self.span_queue.append(self.allocator, .{ .resource = resource, .data = cloned_span }) catch |err| {
            cloned_span.deinitOwned(self.allocator);
            error_handler.reportError(.{
                .component = .processor,
                .operation = "queue_append",
                .error_type = .resource_exhausted,
                .message = "Span queue overflow, dropping span",
                .context = span.name,
                .source_error = err,
            });
            return;
        };
    }

    /// Force export all queued spans immediately
    pub fn forceFlush(self: *BatchSpanProcessor, timeout_ms: ?u64) otel_api.common.FlushResult {
        // Quick check without mutex
        if (self.is_shutdown.load(.acquire)) {
            return .failure;
        }

        const start_time = @as(i64, @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms)));

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Try to set flush_in_progress atomically
        const was_flushing = self.flush_in_progress.swap(true, .seq_cst);
        if (was_flushing) {
            // Another flush is in progress, wait for it
            const remaining_ms = if (timeout_ms) |ms|
                ms -| @as(u64, @intCast(@as(i64, @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms))) - start_time))
            else
                null;

            if (remaining_ms == 0) {
                return .timeout;
            }

            self.flush_complete.waitUncancelable(io, &self.mutex);
            return .success;
        }

        defer {
            self.flush_in_progress.store(false, .release);
            self.flush_complete.broadcast(io);
        }

        // Wait for any export in progress
        while (self.export_in_progress.load(.acquire)) {
            self.export_complete.waitUncancelable(io, &self.mutex);
        }

        // Now do the export with atomic flag
        self.export_in_progress.store(true, .release);
        defer {
            self.export_in_progress.store(false, .release);
            self.export_complete.broadcast(io);
        }

        // Export spans (mutex is held)
        if (self.span_queue.items.len > 0) {
            const spans_to_export = self.span_queue.toOwnedSlice(self.allocator) catch |err| {
                error_handler.reportError(.{
                    .component = .processor,
                    .operation = "batch_export",
                    .error_type = .resource_exhausted,
                    .message = "Failed to export batch spans",
                    .source_error = err,
                });
                return .failure;
            };

            // Temporarily release mutex for export
            self.mutex.unlock(io);
            if (self.exporter) |exporter| {
                for (spans_to_export) |data_pair| {
                    _ = exporter.exportSpans(&.{data_pair.data}, data_pair.resource);
                }
            }
            for (spans_to_export) |data_pair| {
                data_pair.data.deinitOwned(self.allocator);
            }
            self.allocator.free(spans_to_export);
            self.mutex.lockUncancelable(io);
        }

        // Flush the exporter
        self.mutex.unlock(io);
        const flush_result = if (self.exporter) |exporter| exporter.forceFlush(timeout_ms) else ExportResult.success;
        self.mutex.lockUncancelable(io);

        return flush_result.asFlushResult();
    }

    /// Shutdown the processor
    pub fn shutdown(self: *BatchSpanProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.is_shutdown.swap(true, .seq_cst)) {
            return .success;
        }

        self.is_running.store(false, .release);
        self.condition.signal(io);

        // Shutdown the exporter
        const result = if (self.exporter) |exporter| exporter.shutdown(timeout_ms) else ExportResult.success;
        return result.asFlushResult().asProcessResult();
    }

    /// Export all queued spans, releasing the mutex during HTTP export.
    /// Must be called with mutex held. Mutex is held again on return.
    fn exportBatchUnlocked(self: *BatchSpanProcessor) void {
        if (self.is_shutdown.load(.acquire) or self.span_queue.items.len == 0) {
            return;
        }

        // Drain queue under the lock
        const spans_to_export = self.span_queue.toOwnedSlice(self.allocator) catch return;

        // Release mutex during export — HTTP calls can take seconds
        self.mutex.unlock(io);

        if (self.exporter) |exporter| {
            for (spans_to_export) |item| {
                _ = exporter.exportSpans(&.{item.data}, item.resource);
            }
        }

        for (spans_to_export) |span| {
            span.data.deinitOwned(self.allocator);
        }
        self.allocator.free(spans_to_export);

        // Re-acquire mutex before returning
        self.mutex.lockUncancelable(io);
    }

    /// Export all queued spans (acquires mutex)
    fn exportBatch(self: *BatchSpanProcessor) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.exportBatchUnlocked();
    }

    /// Background thread function that periodically exports spans
    fn exportThreadFn(self: *BatchSpanProcessor) void {
        while (true) {
            // Fast path check without mutex
            if (self.is_shutdown.load(.acquire)) {
                break;
            }

            self.mutex.lockUncancelable(io);

            // Double-check under mutex
            if (self.is_shutdown.load(.acquire)) {
                self.mutex.unlock(io);
                break;
            }

            // Sleep for the export interval, releasing the mutex
            const wait_ns: i96 = @intCast(@as(u64, self.export_interval_ms) * std.time.ns_per_ms);
            self.mutex.unlock(io);
            io.sleep(.{ .nanoseconds = wait_ns }, .real) catch {};
            self.mutex.lockUncancelable(io);

            // Skip if flush is in progress
            if (self.flush_in_progress.load(.acquire)) {
                self.mutex.unlock(io);
                continue;
            }

            // Try to acquire export lock
            if (self.export_in_progress.swap(true, .seq_cst)) {
                // Already exporting, skip this cycle
                self.mutex.unlock(io);
                continue;
            }

            // Drain queue under the lock, then release before exporting
            // (same pattern as forceFlush — avoids blocking onEnd callers during HTTP export)
            const spans_to_export = if (self.span_queue.items.len > 0)
                self.span_queue.toOwnedSlice(self.allocator) catch null
            else
                null;

            self.mutex.unlock(io);

            // Export outside the lock — HTTP calls can take seconds
            if (spans_to_export) |spans| {
                if (self.exporter) |exporter| {
                    for (spans) |item| {
                        _ = exporter.exportSpans(&.{item.data}, item.resource);
                    }
                }
                for (spans) |span| {
                    span.data.deinitOwned(self.allocator);
                }
                self.allocator.free(spans);
            }

            self.export_in_progress.store(false, .release);
            self.export_complete.broadcast(io);
        }
    }

    pub fn spanProcessor(self: *BatchSpanProcessor) SpanProcessor {
        return SpanProcessor{ .bridge = BridgeSpanProcessor.init(self) };
    }
};

test "BatchSpanProcessor - basic initialization and cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use mock error handler to capture errors instead of printing to stderr
    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    const mock_exporter = try allocator.create(MockSpanExporter);
    mock_exporter.* = MockSpanExporter.init(allocator);

    const processor = try allocator.create(BatchSpanProcessor);
    processor.* = BatchSpanProcessor.init(
        allocator,
        mock_exporter.spanExporter(),
        .{ .export_interval_ms = 100, .max_queue_size = 5 },
    );
    defer {
        processor.deinit();
        processor.destroy();
    }

    // Test initial state
    try testing.expect(!processor.is_running.load(.unordered));
    try testing.expect(!processor.is_shutdown.load(.unordered));
    try testing.expectEqual(@as(usize, 0), processor.span_queue.items.len);
}

test "BatchSpanProcessor - span queuing and export" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use mock error handler to capture errors instead of printing to stderr
    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    const mock_exporter = try allocator.create(MockSpanExporter);
    mock_exporter.* = MockSpanExporter.init(allocator);

    const processor = try allocator.create(BatchSpanProcessor);
    processor.* = BatchSpanProcessor.init(
        allocator,
        mock_exporter.spanExporter(),
        .{ .export_interval_ms = 50, .max_queue_size = 10 },
    );

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, resource, .{ .random = .init() }, .keep);
    defer provider.deinit();

    try provider.registerProcessor(processor.spanProcessor());
    const tracer = try provider.getTracerWithScope(.empty);

    // Create proper RecordingSpan for testing
    const span_context = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{1} ** 16 },
        .span_id = otel_api.common.SpanId{ .bytes = [_]u8{1} ** 8 },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const recording_span_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, recording_span_ctx);
    var recording_span = try tracer.startSpan("test-span", .{}, recording_span_ctx);
    defer recording_span.deinit();

    // Test adding span to queue
    recording_span.end(null);

    processor.mutex.lockUncancelable(io);
    try testing.expectEqual(@as(usize, 1), processor.span_queue.items.len);
    processor.mutex.unlock(io);

    // Test force flush
    try testing.expectEqual(otel_api.common.FlushResult.success, processor.forceFlush(null));
    try testing.expectEqual(@as(usize, 1), mock_exporter.spanCount());

    processor.mutex.lockUncancelable(io);
    try testing.expectEqual(@as(usize, 0), processor.span_queue.items.len);
    processor.mutex.unlock(io);
}

test "BatchSpanProcessor - queue overflow drops newest" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use mock error handler to capture errors instead of printing to stderr
    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    const mock_exporter = try allocator.create(MockSpanExporter);
    mock_exporter.* = MockSpanExporter.init(allocator);

    const processor = try allocator.create(BatchSpanProcessor);
    processor.* = BatchSpanProcessor.init(
        allocator,
        mock_exporter.spanExporter(),
        .{ .export_interval_ms = 1000, .max_queue_size = 2 },
    );

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, resource, .{ .random = .init() }, .keep);
    defer provider.deinit();

    try provider.registerProcessor(processor.spanProcessor());

    const tracer = try provider.getTracerWithScope(.empty);

    // Create proper RecordingSpans for testing
    const span_context1 = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{1} ** 16 },
        .span_id = otel_api.common.SpanId{ .bytes = [_]u8{1} ** 8 },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };
    const span_context2 = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{2} ** 16 },
        .span_id = otel_api.common.SpanId{ .bytes = [_]u8{2} ** 8 },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };
    const span_context3 = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{3} ** 16 },
        .span_id = otel_api.common.SpanId{ .bytes = [_]u8{3} ** 8 },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const span1_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context1);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, span1_ctx);
    var span1 = try tracer.startSpan("test-span-1", .{}, span1_ctx);
    defer span1.deinit();

    const span2_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context2);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, span2_ctx);
    var span2 = try tracer.startSpan("test-span-2", .{}, span2_ctx);
    defer span2.deinit();

    const span3_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context3);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, span3_ctx);
    var span3 = try tracer.startSpan("test-span-3", .{}, span3_ctx);
    defer span3.deinit();

    // Fill queue to capacity
    span1.end(null);
    span2.end(null);

    processor.mutex.lockUncancelable(io);
    try testing.expectEqual(@as(usize, 2), processor.span_queue.items.len);
    processor.mutex.unlock(io);

    // This should be dropped (newest dropped policy)
    span3.end(null);

    processor.mutex.lockUncancelable(io);
    try testing.expectEqual(@as(usize, 2), processor.span_queue.items.len); // Still 2
    processor.mutex.unlock(io);
}

test "BatchSpanProcessor - shutdown behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use mock error handler to capture errors instead of printing to stderr
    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, resource, .{ .random = .init() }, .keep);
    defer provider.deinit();

    var processor: *BatchSpanProcessor = undefined;
    try @import("../common/pipeline.zig").buildPipeline(&provider).withCaptured(
        BatchSpanProcessor.PipelineStep.init(.{
            .export_interval_ms = 1000,
            .max_queue_size = 2,
        }),
        &processor,
    ).done();

    const tracer = try provider.getTracerWithScope(.empty);

    // Test shutdown
    try testing.expect(processor.is_shutdown.load(.monotonic) == false);
    try testing.expectEqual(ProcessResult.success, processor.shutdown(null));
    try testing.expect(processor.is_shutdown.load(.unordered));

    // Operations after shutdown should handle gracefully
    const span_context = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{1} ** 16 },
        .span_id = otel_api.common.SpanId{ .bytes = [_]u8{1} ** 8 },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const test_span_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, test_span_ctx);
    var test_span = try tracer.startSpan("test-span", .{}, test_span_ctx);
    defer test_span.deinit();

    test_span.end(null); // Should be handled gracefully after shutdown

    try testing.expectEqual(otel_api.common.FlushResult.failure, processor.forceFlush(null));
}

test "BatchSpanProcessor - concurrent onEnd from many threads queues every span" {
    // Regression for the onEnd lock convoy: many threads end spans at once, so
    // onEnd's clone-then-lock path runs fully concurrently. Asserts every span
    // is queued exactly once (no lost or double-counted spans) and — via the
    // testing allocator — that no clone leaks on any path.
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    const mock_exporter = try allocator.create(MockSpanExporter);
    mock_exporter.* = MockSpanExporter.init(allocator);

    const processor = try allocator.create(BatchSpanProcessor);
    // High interval + no start() ⇒ the export thread never drains; the queue
    // must hold every span. Queue sized well above the total so none are dropped.
    processor.* = BatchSpanProcessor.init(
        allocator,
        mock_exporter.spanExporter(),
        .{ .export_interval_ms = 1_000_000, .max_queue_size = 4096 },
    );

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, resource, .{ .random = .init() }, .keep);
    defer provider.deinit();
    try provider.registerProcessor(processor.spanProcessor());

    const TracerProvider = @import("tracer_provider.zig").TracerProvider;
    const N_THREADS = 8;
    const SPANS_PER = 25;

    const Worker = struct {
        fn run(prov: *TracerProvider, alloc: std.mem.Allocator, ok: *std.atomic.Value(u32)) void {
            const tracer = prov.getTracerWithScope(.empty) catch return;
            const sc = otel_api.trace.Span.Context{
                .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{7} ** 16 },
                .span_id = otel_api.common.SpanId{ .bytes = [_]u8{7} ** 8 },
                .trace_flags = 0,
                .trace_state = null,
                .is_remote = false,
            };
            var i: usize = 0;
            while (i < SPANS_PER) : (i += 1) {
                const ctx = otel_api.trace.trace_context.withActiveSpanContext(alloc, &.{}, sc) catch return;
                defer otel_api.ContextKeyValue.deinitOwnedSlice(alloc, ctx);
                var span = tracer.startSpan("concurrent-span", .{}, ctx) catch return;
                span.end(null); // calls onEnd on this thread
                span.deinit();
            }
            _ = ok.fetchAdd(1, .monotonic);
        }
    };

    var ok = std.atomic.Value(u32).init(0);
    var threads: [N_THREADS]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &provider, allocator, &ok });
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, N_THREADS), ok.load(.monotonic));
    processor.mutex.lockUncancelable(io);
    defer processor.mutex.unlock(io);
    try testing.expectEqual(@as(usize, N_THREADS * SPANS_PER), processor.span_queue.items.len);
}
