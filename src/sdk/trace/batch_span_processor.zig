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
const otel_api = @import("otel-api");

const ProcessResult = otel_api.common.ProcessResult;
const ExportResult = otel_api.common.ExportResult;
const SpanLimits = otel_api.trace.SpanLimits;
const RecordingSpan = @import("data.zig").RecordingSpan;
const SpanExporter = @import("exporter.zig").SpanExporter;
const Resource = @import("../resource/resource.zig").Resource;

// Import error handler for structured error reporting
const error_handler = otel_api.common;

// Import the processor interface and bridge
const processor_zig = @import("processor.zig");
const SpanProcessor = processor_zig.SpanProcessor;
const BridgeSpanProcessor = processor_zig.BridgeSpanProcessor;

/// Convert ExportResult to ProcessResult
fn exportResultToProcessResult(result: ExportResult) ProcessResult {
    return switch (result) {
        .success => .success,
        .failure => .failure,
    };
}

/// Noop exporter for initial BatchSpanProcessor state
const NoopExporter = struct {
    pub fn exportSpans(self: *NoopExporter, spans: []const *RecordingSpan, resource: Resource) ExportResult {
        _ = self;
        _ = spans;
        _ = resource;
        return .success;
    }

    pub fn forceFlush(self: *NoopExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        return .success;
    }

    pub fn shutdown(self: *NoopExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        return .success;
    }

    pub fn deinit(self: *NoopExporter) void {
        _ = self;
    }

    pub fn destroy(self: *NoopExporter) void {
        _ = self;
    }
};

var noop_exporter_instance = NoopExporter{};

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
        self.* = .{
            .allocator = allocator,
            .exporter = SpanExporter{ .bridge = @import("exporter.zig").BridgeSpanExporter.init(&noop_exporter_instance) },
            .resource = @import("../resource/resource.zig").Resource.empty,
            .mutex = .{},
            .condition = .{},
            .is_shutdown = std.atomic.Value(bool).init(false),
            .is_running = std.atomic.Value(bool).init(false),
            .flush_in_progress = std.atomic.Value(bool).init(false),
            .export_in_progress = std.atomic.Value(bool).init(false),
            .flush_complete = .{},
            .export_complete = .{},
            .thread = null,
            .export_interval_ms = config.export_interval_ms orelse 5000,
            .max_queue_size = config.max_queue_size orelse 2048,
            .span_queue = std.ArrayList(*RecordingSpan).init(allocator),
        };
        try self.start();
    }
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    resource: Resource,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    is_shutdown: std.atomic.Value(bool),
    is_running: std.atomic.Value(bool),
    flush_in_progress: std.atomic.Value(bool),
    export_in_progress: std.atomic.Value(bool),
    flush_complete: std.Thread.Condition,
    export_complete: std.Thread.Condition,
    thread: ?std.Thread,
    export_interval_ms: u32,
    max_queue_size: usize,
    span_queue: std.ArrayList(*RecordingSpan),

    /// Initialize a new batch span processor
    /// export_interval_ms: How often to export spans (default: 5000ms = 5s)
    /// max_queue_size: Maximum spans to queue before dropping (default: 2048)
    ///
    /// Owner of the processor must destroy the memory.
    pub fn init(
        allocator: std.mem.Allocator,
        exporter: SpanExporter,
        resource: Resource,
        export_interval_ms: ?u32,
        max_queue_size: ?usize,
    ) !*BatchSpanProcessor {
        const self = try allocator.create(BatchSpanProcessor);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .exporter = exporter,
            .resource = resource,
            .mutex = .{},
            .condition = .{},
            .is_shutdown = std.atomic.Value(bool).init(false),
            .is_running = std.atomic.Value(bool).init(false),
            .flush_in_progress = std.atomic.Value(bool).init(false),
            .export_in_progress = std.atomic.Value(bool).init(false),
            .flush_complete = .{},
            .export_complete = .{},
            .thread = null,
            .export_interval_ms = export_interval_ms orelse 5000,
            .max_queue_size = max_queue_size orelse 2048,
            .span_queue = std.ArrayList(*RecordingSpan).init(allocator),
        };

        return self;
    }

    pub fn setExporter(self: *BatchSpanProcessor, exporter: ?SpanExporter) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (exporter) |exp| {
            self.exporter = exp;
        }
    }

    /// Start the background export thread
    pub fn start(self: *BatchSpanProcessor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

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

        self.mutex.lock();
        self.condition.signal();
        self.mutex.unlock();

        // Wait for thread to exit
        if (self.thread) |thread| {
            thread.join();
        }

        // Clean up remaining spans
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.span_queue.items) |span| {
            span.deinitCloned();
        }
        self.span_queue.deinit();

        // Clean up the exporter
        self.exporter.deinit();
        self.exporter.destroy();
    }

    pub fn destroy(self: *BatchSpanProcessor) void {
        self.allocator.destroy(self);
    }

    pub fn spanLimits(self: *BatchSpanProcessor) SpanLimits {
        _ = self;
        return .default;
    }

    /// Called when a span ends - adds span to batch queue
    pub fn onEnd(self: *BatchSpanProcessor, span: *RecordingSpan) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown.load(.acquire)) {
            return;
        }

        // Drop newest if queue is full
        if (self.span_queue.items.len >= self.max_queue_size) {
            return;
        }

        // Clone span for queuing (original will be deinitialized by caller)
        const cloned_span = span.clone(self.allocator) catch |err| {
            // Log error instead of silent drop
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

        // Add cloned span to queue
        self.span_queue.append(cloned_span) catch |err| {
            cloned_span.deinitCloned();
            // Log queue overflow
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
    pub fn forceFlush(self: *BatchSpanProcessor, timeout_ms: ?u64) ProcessResult {
        // Quick check without mutex
        if (self.is_shutdown.load(.acquire)) {
            return .failure;
        }

        const start_time = std.time.milliTimestamp();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to set flush_in_progress atomically
        const was_flushing = self.flush_in_progress.swap(true, .seq_cst);
        if (was_flushing) {
            // Another flush is in progress, wait for it
            const remaining_ms = if (timeout_ms) |ms|
                ms -| @as(u64, @intCast(std.time.milliTimestamp() - start_time))
            else
                null;

            if (remaining_ms == 0) {
                return .timeout;
            }

            if (remaining_ms) |ms| {
                self.flush_complete.timedWait(&self.mutex, ms * std.time.ns_per_ms) catch {
                    return .timeout;
                };
            } else {
                self.flush_complete.wait(&self.mutex);
            }
            return .success;
        }

        defer {
            self.flush_in_progress.store(false, .release);
            self.flush_complete.broadcast();
        }

        // Wait for any export in progress
        while (self.export_in_progress.load(.acquire)) {
            const remaining_ms = if (timeout_ms) |ms|
                ms -| @as(u64, @intCast(std.time.milliTimestamp() - start_time))
            else
                null;

            if (remaining_ms == 0) {
                return .timeout;
            }

            if (remaining_ms) |ms| {
                self.export_complete.timedWait(&self.mutex, ms * std.time.ns_per_ms) catch {
                    return .timeout;
                };
            } else {
                self.export_complete.wait(&self.mutex);
            }
        }

        // Now do the export with atomic flag
        self.export_in_progress.store(true, .release);
        defer {
            self.export_in_progress.store(false, .release);
            self.export_complete.broadcast();
        }

        // Export spans (mutex is held)
        if (self.span_queue.items.len > 0) {
            const spans_to_export = self.span_queue.toOwnedSlice() catch |err| {
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
            self.mutex.unlock();
            const result = self.exporter.exportSpans(spans_to_export, self.resource);
            self.mutex.lock();

            // Clean up spans
            for (spans_to_export) |span| {
                span.deinitCloned();
            }
            self.allocator.free(spans_to_export);

            if (result != .success) {
                return .failure;
            }
        }

        // Flush the exporter
        self.mutex.unlock();
        const flush_result = self.exporter.forceFlush(timeout_ms);
        self.mutex.lock();

        return exportResultToProcessResult(flush_result);
    }

    /// Shutdown the processor
    pub fn shutdown(self: *BatchSpanProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown.swap(true, .seq_cst)) {
            return .success;
        }

        self.is_running.store(false, .release);
        self.condition.signal();

        // Shutdown the exporter
        const result = self.exporter.shutdown(timeout_ms);
        return exportResultToProcessResult(result);
    }

    /// Export all queued spans (must be called with mutex held)
    fn exportBatchLocked(self: *BatchSpanProcessor) void {
        if (self.is_shutdown.load(.acquire) or self.span_queue.items.len == 0) {
            return;
        }

        // Export all queued spans
        _ = self.exporter.exportSpans(self.span_queue.items, self.resource);

        // Clean up exported spans
        for (self.span_queue.items) |span| {
            span.deinitCloned();
        }
        self.span_queue.clearRetainingCapacity();
    }

    /// Export all queued spans (acquires mutex)
    fn exportBatch(self: *BatchSpanProcessor) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.exportBatchLocked();
    }

    /// Background thread function that periodically exports spans
    fn exportThreadFn(self: *BatchSpanProcessor) void {
        while (true) {
            // Fast path check without mutex
            if (self.is_shutdown.load(.acquire)) {
                break;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            // Double-check under mutex
            if (self.is_shutdown.load(.acquire)) {
                break;
            }

            // Calculate wait time in nanoseconds
            const wait_ns = @as(u64, self.export_interval_ms) * std.time.ns_per_ms;

            // Wait for the specified interval or until signaled
            self.condition.timedWait(&self.mutex, wait_ns) catch {
                // Timeout - normal export cycle
            };

            // Skip if flush is in progress
            if (self.flush_in_progress.load(.acquire)) {
                continue;
            }

            // Try to acquire export lock
            if (self.export_in_progress.swap(true, .seq_cst)) {
                // Already exporting, skip this cycle
                continue;
            }

            defer {
                self.export_in_progress.store(false, .release);
                self.export_complete.broadcast();
            }

            // Do the export
            self.exportBatchLocked();
        }
    }

    pub fn spanProcessor(self: *BatchSpanProcessor) SpanProcessor {
        return SpanProcessor{ .bridge = BridgeSpanProcessor.init(self) };
    }
};

test "BatchSpanProcessor - basic initialization and cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock exporter for testing
    const MockExporter = struct {
        export_count: usize = 0,
        exported_spans: std.ArrayList(*RecordingSpan),
        flush_count: usize = 0,
        shutdown_count: usize = 0,
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) !*@This() {
            const self = try alloc.create(@This());
            self.* = .{
                .allocator = alloc,
                .exported_spans = std.ArrayList(*RecordingSpan).init(alloc),
            };
            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.exported_spans.deinit();
            self.allocator.destroy(self);
        }

        pub fn exportSpans(self: *@This(), spans: []const *RecordingSpan, resource: Resource) ExportResult {
            _ = resource;
            self.export_count += spans.len;
            for (spans) |span| {
                self.exported_spans.append(span) catch {};
            }
            return .success;
        }

        pub fn forceFlush(self: *@This(), timeout_ms: ?u64) ExportResult {
            _ = timeout_ms;
            self.flush_count += 1;
            return .success;
        }

        pub fn shutdown(self: *@This(), timeout_ms: ?u64) ExportResult {
            _ = timeout_ms;
            self.shutdown_count += 1;
            return .success;
        }

        pub fn destroy(self: *@This()) void {
            self.allocator.destroy(self);
        }

        pub fn spanExporter(self: *@This()) SpanExporter {
            return SpanExporter{ .bridge = @import("exporter.zig").BridgeSpanExporter.init(self) };
        }
    };

    var mock_exporter = try MockExporter.init(allocator);
    defer mock_exporter.deinit();

    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = try BatchSpanProcessor.init(
        allocator,
        mock_exporter.spanExporter(),
        resource,
        100, // Very short interval for testing
        5, // Small queue for testing
    );
    defer processor.deinit();

    // Test initial state
    try testing.expect(!processor.is_running);
    try testing.expect(!processor.is_shutdown);
    try testing.expectEqual(@as(usize, 0), processor.span_queue.items.len);
}

test "BatchSpanProcessor - span queuing and export" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const MockExporter = struct {
        export_count: usize = 0,
        flush_count: usize = 0,
        shutdown_count: usize = 0,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn exportSpans(self: *@This(), spans: []const *RecordingSpan, resource: Resource) ExportResult {
            _ = resource;
            _ = spans;
            self.export_count += 1;
            return .success;
        }

        pub fn forceFlush(self: *@This(), timeout_ms: ?u64) ExportResult {
            _ = timeout_ms;
            self.flush_count += 1;
            return .success;
        }

        pub fn shutdown(self: *@This(), timeout_ms: ?u64) ExportResult {
            _ = timeout_ms;
            self.shutdown_count += 1;
            return .success;
        }

        pub fn destroy(self: *@This()) void {
            self.allocator.destroy(self);
        }

        pub fn spanExporter(self: *@This()) SpanExporter {
            return SpanExporter{ .bridge = @import("exporter.zig").BridgeSpanExporter.init(self) };
        }
    };

    var mock_exporter = MockExporter{};
    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = try BatchSpanProcessor.init(
        allocator,
        mock_exporter.spanExporter(),
        resource,
        50, // Short interval
        10, // Small queue
    );
    defer processor.deinit();

    // Create mock spans
    const MockSpan = struct {
        deinit_called: bool = false,

        pub fn deinit(self: *@This()) void {
            self.deinit_called = true;
        }
    };

    var mock_span = MockSpan{};
    const recording_span: *RecordingSpan = @ptrCast(&mock_span);

    // Test adding span to queue
    processor.onEnd(recording_span);

    processor.mutex.lock();
    try testing.expectEqual(@as(usize, 1), processor.span_queue.items.len);
    processor.mutex.unlock();

    // Test force flush
    try testing.expectEqual(ProcessResult.success, processor.forceFlush(null));
    try testing.expectEqual(@as(usize, 1), mock_exporter.export_count);
    try testing.expectEqual(@as(usize, 1), mock_exporter.flush_count);

    processor.mutex.lock();
    try testing.expectEqual(@as(usize, 0), processor.span_queue.items.len);
    processor.mutex.unlock();
}

test "BatchSpanProcessor - queue overflow drops newest" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const MockExporter = struct {
        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn exportSpans(self: *@This(), spans: []const *RecordingSpan, resource: Resource) ProcessResult {
            _ = self;
            _ = spans;
            _ = resource;
            return .success;
        }

        pub fn forceFlush(self: *@This(), timeout_ms: ?u64) ProcessResult {
            _ = self;
            _ = timeout_ms;
            return .success;
        }

        pub fn shutdown(self: *@This(), timeout_ms: ?u64) ProcessResult {
            _ = self;
            _ = timeout_ms;
            return .success;
        }

        pub fn spanExporter(self: *@This()) SpanExporter {
            return SpanExporter{ .bridge = @import("exporter.zig").BridgeSpanExporter.init(self) };
        }
    };

    var mock_exporter = MockExporter{};
    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = try BatchSpanProcessor.init(
        allocator,
        mock_exporter.spanExporter(),
        resource,
        1000, // Long interval
        2, // Very small queue
    );
    defer processor.deinit();

    const MockSpan = struct {
        id: u32,
        deinit_called: bool = false,

        pub fn deinit(self: *@This()) void {
            self.deinit_called = true;
        }
    };

    var span1 = MockSpan{ .id = 1 };
    var span2 = MockSpan{ .id = 2 };
    var span3 = MockSpan{ .id = 3 }; // This should be dropped

    // Fill queue to capacity
    processor.onEnd(@ptrCast(&span1));
    processor.onEnd(@ptrCast(&span2));

    processor.mutex.lock();
    try testing.expectEqual(@as(usize, 2), processor.span_queue.items.len);
    processor.mutex.unlock();

    // This should be dropped (newest dropped policy)
    processor.onEnd(@ptrCast(&span3));

    processor.mutex.lock();
    try testing.expectEqual(@as(usize, 2), processor.span_queue.items.len); // Still 2
    processor.mutex.unlock();

    try testing.expect(span3.deinit_called); // Dropped span should be cleaned up
}

test "BatchSpanProcessor - shutdown behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const MockExporter = struct {
        export_count: usize = 0,
        shutdown_count: usize = 0,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn exportSpans(self: *@This(), spans: []const *RecordingSpan, resource: Resource) ExportResult {
            _ = resource;
            self.export_count += spans.len;
            return .success;
        }

        pub fn forceFlush(self: *@This(), timeout_ms: ?u64) ExportResult {
            _ = self;
            _ = timeout_ms;
            return .success;
        }

        pub fn shutdown(self: *@This(), timeout_ms: ?u64) ExportResult {
            _ = timeout_ms;
            self.shutdown_count += 1;
            return .success;
        }

        pub fn destroy(self: *@This()) void {
            _ = self;
        }

        pub fn spanExporter(self: *@This()) SpanExporter {
            return SpanExporter{ .bridge = @import("exporter.zig").BridgeSpanExporter.init(self) };
        }
    };

    var mock_exporter = MockExporter{};
    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = try BatchSpanProcessor.init(
        allocator,
        mock_exporter.spanExporter(),
        resource,
        100,
        10,
    );
    defer processor.deinit();

    // Test shutdown
    try testing.expectEqual(ProcessResult.success, processor.shutdown(null));
    try testing.expect(processor.is_shutdown);
    try testing.expectEqual(@as(usize, 1), mock_exporter.shutdown_count);

    // Operations after shutdown should handle gracefully
    const MockSpan = struct {
        deinit_called: bool = false,
        pub fn deinit(self: *@This()) void {
            self.deinit_called = true;
        }
    };

    var mock_span = MockSpan{};
    processor.onEnd(@ptrCast(&mock_span));
    try testing.expect(mock_span.deinit_called); // Should be cleaned up immediately

    try testing.expectEqual(ProcessResult.failure, processor.forceFlush(null));
}
