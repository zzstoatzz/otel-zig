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
const SpanLimits = otel_api.trace.SpanLimits;
const RecordingSpan = @import("data.zig").RecordingSpan;
const SpanExporter = @import("exporter.zig").SpanExporter;
const Resource = @import("../resource/resource.zig").Resource;

/// Batch span processor that exports spans at regular intervals
pub const BatchSpanProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    resource: Resource,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    is_shutdown: bool,
    is_running: bool,
    thread: ?std.Thread,
    export_interval_ms: u32,
    max_queue_size: usize,
    span_queue: std.ArrayListUnmanaged(*RecordingSpan),

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
            .is_shutdown = false,
            .is_running = false,
            .thread = null,
            .export_interval_ms = export_interval_ms orelse 5000, // 5 seconds default
            .max_queue_size = max_queue_size orelse 2048,
            .span_queue = .{},
        };

        return self;
    }

    /// Start the background export thread
    pub fn start(self: *BatchSpanProcessor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_running or self.is_shutdown) {
            return;
        }

        self.is_running = true;
        self.thread = try std.Thread.spawn(.{}, exportThreadFn, .{self});
    }

    /// Stop the background export thread and clean up resources
    pub fn deinit(self: *BatchSpanProcessor) void {
        // Signal shutdown
        self.mutex.lock();
        if (!self.is_shutdown) {
            self.is_shutdown = true;
            self.condition.signal();
        }
        self.mutex.unlock();

        // Wait for thread to finish
        if (self.thread) |thread| {
            thread.join();
        }

        // Clean up any remaining spans
        self.mutex.lock();
        for (self.span_queue.items) |span| {
            span.deinitCloned();
        }
        self.span_queue.deinit(self.allocator);
        self.mutex.unlock();

        // Clean up resources
        self.exporter.deinit();
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

        if (self.is_shutdown) {
            return;
        }

        // Drop newest if queue is full
        if (self.span_queue.items.len >= self.max_queue_size) {
            return;
        }

        // Clone span for queuing (original will be deinitialized by caller)
        const cloned_span = span.clone(self.allocator) catch {
            // If cloning fails, drop the span
            return;
        };

        // Add cloned span to queue
        self.span_queue.append(self.allocator, cloned_span) catch {
            // If allocation fails, clean up the clone and drop the span
            cloned_span.deinitCloned();
            return;
        };
    }

    /// Force export all queued spans immediately
    pub fn forceFlush(self: *BatchSpanProcessor, timeout_ms: ?u64) ProcessResult {
        self.exportBatch();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = self.exporter.forceFlush(timeout_ms);
        return if (result == .success) .success else .failure;
    }

    /// Shutdown the processor
    pub fn shutdown(self: *BatchSpanProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;
        self.condition.signal(); // Wake up the export thread

        // Shutdown the exporter
        const result = self.exporter.shutdown(timeout_ms);
        return if (result == .success) .success else .failure;
    }

    /// Export all queued spans (must be called with mutex held)
    fn exportBatchLocked(self: *BatchSpanProcessor) void {
        if (self.is_shutdown or self.span_queue.items.len == 0) {
            return;
        }

        // Export all queued spans
        _ = self.exporter.exportSpans(self.span_queue.items, self.resource);

        // Clean up exported cloned spans
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
            self.mutex.lock();

            // Check if we should shutdown
            if (self.is_shutdown) {
                // Export any remaining spans before shutting down
                self.exportBatchLocked();
                self.is_running = false;
                self.mutex.unlock();
                break;
            }

            // Calculate wait time in nanoseconds
            const wait_ns = @as(u64, self.export_interval_ms) * std.time.ns_per_ms;

            // Wait for the specified interval or until signaled to shutdown
            self.condition.timedWait(&self.mutex, wait_ns) catch {
                // On timeout, continue with export
                self.exportBatchLocked();
                self.mutex.unlock();
                continue;
            };

            // We were signaled, likely for shutdown - check if we should exit
            if (self.is_shutdown) {
                // Export any remaining spans before shutting down
                self.exportBatchLocked();
                self.is_running = false;
                self.mutex.unlock();
                break;
            }

            // Otherwise continue with export
            self.exportBatchLocked();
            self.mutex.unlock();
        }
    }
};

/// Create a batch span processor and start it
pub fn createBatchSpanProcessor(
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    resource: Resource,
    export_interval_ms: ?u32,
    max_queue_size: ?usize,
) !*BatchSpanProcessor {
    const processor = try BatchSpanProcessor.init(
        allocator,
        exporter,
        resource,
        export_interval_ms,
        max_queue_size,
    );
    try processor.start();
    return processor;
}

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

        pub fn exportSpans(self: *@This(), spans: []const *RecordingSpan, resource: Resource) ProcessResult {
            _ = resource;
            self.export_count += spans.len;
            for (spans) |span| {
                self.exported_spans.append(span) catch {};
            }
            return .success;
        }

        pub fn forceFlush(self: *@This(), timeout_ms: ?u64) ProcessResult {
            _ = timeout_ms;
            self.flush_count += 1;
            return .success;
        }

        pub fn shutdown(self: *@This(), timeout_ms: ?u64) ProcessResult {
            _ = timeout_ms;
            self.shutdown_count += 1;
            return .success;
        }

        pub fn spanExporter(self: *@This()) SpanExporter {
            return @import("exporter.zig").createSpanExporter(self);
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

        pub fn exportSpans(self: *@This(), spans: []const *RecordingSpan, resource: Resource) ProcessResult {
            _ = resource;
            self.export_count += spans.len;
            return .success;
        }

        pub fn forceFlush(self: *@This(), timeout_ms: ?u64) ProcessResult {
            _ = timeout_ms;
            self.flush_count += 1;
            return .success;
        }

        pub fn shutdown(self: *@This(), timeout_ms: ?u64) ProcessResult {
            _ = timeout_ms;
            self.shutdown_count += 1;
            return .success;
        }

        pub fn spanExporter(self: *@This()) SpanExporter {
            return @import("exporter.zig").createSpanExporter(self);
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
            return @import("exporter.zig").createSpanExporter(self);
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

        pub fn exportSpans(self: *@This(), spans: []const *RecordingSpan, resource: Resource) ProcessResult {
            _ = resource;
            self.export_count += spans.len;
            return .success;
        }

        pub fn forceFlush(self: *@This(), timeout_ms: ?u64) ProcessResult {
            _ = self;
            _ = timeout_ms;
            return .success;
        }

        pub fn shutdown(self: *@This(), timeout_ms: ?u64) ProcessResult {
            _ = timeout_ms;
            self.shutdown_count += 1;
            return .success;
        }

        pub fn spanExporter(self: *@This()) SpanExporter {
            return @import("exporter.zig").createSpanExporter(self);
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
