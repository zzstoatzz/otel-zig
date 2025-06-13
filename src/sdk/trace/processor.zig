//! OpenTelemetry Span Processor Interface
//!
//! This module defines the SpanProcessor interface for processing spans
//! in the OpenTelemetry SDK. Processors receive spans when they end
//! and are responsible for batching, filtering, and forwarding them to exporters.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/sdk.md#span-processor

const std = @import("std");
const otel_api = @import("otel-api");

const Context = otel_api.Context;
const SpanLimits = otel_api.trace.SpanLimits;
const ProcessResult = otel_api.common.ProcessResult;
const RecordingSpan = @import("data.zig").RecordingSpan;
const SpanExporter = @import("exporter.zig").SpanExporter;
const Resource = @import("../resource/resource.zig").Resource;

/// SpanProcessor interface using tagged union for polymorphism
pub const SpanProcessor = union(enum) {
    noop: void,
    simple: *SimpleSpanProcessor,
    bridge: BridgeSpanProcessor,

    /// Exposes the limits that the processor will support.
    pub fn spanLimits(self: *const SpanProcessor) SpanLimits {
        return switch (self.*) {
            .noop => .default,
            .simple => |processor| processor.spanLimits(),
            .bridge => |processor| processor.spanLimitsFn(processor.processor_ptr),
        };
    }

    /// Called when a span ends
    pub fn onEnd(self: *SpanProcessor, span: *RecordingSpan) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.onEnd(span),
            .bridge => |processor| processor.onEndFn(processor.processor_ptr, span),
        }
    }

    /// Force flush any buffered spans
    pub fn forceFlush(self: *SpanProcessor, timeout_ms: ?u64) ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .simple => |processor| processor.forceFlush(timeout_ms),
            .bridge => |processor| processor.forceFlushFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Shutdown the processor
    pub fn shutdown(self: *SpanProcessor, timeout_ms: ?u64) ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .simple => |processor| processor.shutdown(timeout_ms),
            .bridge => |processor| processor.shutdownFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Clean up processor resources
    pub fn deinit(self: *SpanProcessor) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.deinit(),
            .bridge => |processor| processor.deinitFn(processor.processor_ptr),
        }
    }
};

/// Simple span processor implementation.
///
/// Implementation is a pass through to the exporter.
pub const SimpleSpanProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    resource: Resource,
    mutex: std.Thread.Mutex,
    is_shutdown: bool,

    pub fn init(allocator: std.mem.Allocator, exporter: SpanExporter, resource: Resource) !*SimpleSpanProcessor {
        const self = try allocator.create(SimpleSpanProcessor);
        self.* = .{
            .allocator = allocator,
            .exporter = exporter,
            .resource = resource,
            .mutex = .{},
            .is_shutdown = false,
        };
        return self;
    }

    pub fn deinit(self: *SimpleSpanProcessor) void {
        self.exporter.deinit();
        self.allocator.destroy(self);
    }

    pub inline fn spanLimits(self: *SimpleSpanProcessor) SpanLimits {
        _ = self;
        return .default;
    }

    pub inline fn onEnd(self: *SimpleSpanProcessor, span: *RecordingSpan) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return;
        }

        // Export single span immediately
        const spans = [_]*RecordingSpan{span};
        _ = self.exporter.exportSpans(&spans, self.resource);
    }

    pub inline fn forceFlush(self: *SimpleSpanProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = self.exporter.forceFlush(timeout_ms);
        return if (result == .success) .success else .failure;
    }

    pub fn shutdown(self: *SimpleSpanProcessor, timeout_ms: ?u64) ProcessResult {
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

    pub fn spanProcessor(self: *SimpleSpanProcessor) SpanProcessor {
        return SpanProcessor{ .simple = self };
    }
};

/// Interface for bridging to a more complex processor.
pub const BridgeSpanProcessor = struct {
    processor_ptr: *anyopaque,
    spanLimitsFn: *const fn (processor_ptr: *anyopaque) SpanLimits,
    onEndFn: *const fn (processor_ptr: *anyopaque, span: *RecordingSpan) void,
    forceFlushFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    shutdownFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    deinitFn: *const fn (processor_ptr: *anyopaque) void,

    pub fn init(ptr: anytype) BridgeSpanProcessor {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn spanLimits(pointer: *anyopaque) SpanLimits {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.spanLimits(self);
            }
            pub fn onEnd(pointer: *anyopaque, span: *RecordingSpan) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.onEnd(self, span);
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
            .spanLimitsFn = VTable.spanLimits,
            .onEndFn = VTable.onEnd,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
        };
    }
};

test "SimpleSpanProcessor basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock exporter for testing
    const MockExporter = struct {
        export_called: bool = false,
        flush_called: bool = false,
        shutdown_called: bool = false,

        pub fn spanExporter(self: *@This()) SpanExporter {
            return SpanExporter{
                .exporter_ptr = self,
                .exportSpansFn = exportSpans,
                .forceFlushFn = flush,
                .shutdownFn = shutdown,
                .deinitFn = deinit,
            };
        }

        fn exportSpans(exporter_ptr: *anyopaque, spans: []const *RecordingSpan, resource: Resource) ProcessResult {
            _ = spans;
            _ = resource;
            const self = @as(*@This(), @ptrCast(@alignCast(exporter_ptr)));
            self.export_called = true;
            return .success;
        }

        fn flush(exporter_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult {
            _ = timeout_ms;
            const self = @as(*@This(), @ptrCast(@alignCast(exporter_ptr)));
            self.flush_called = true;
            return .success;
        }

        fn shutdown(exporter_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult {
            _ = timeout_ms;
            const self = @as(*@This(), @ptrCast(@alignCast(exporter_ptr)));
            self.shutdown_called = true;
            return .success;
        }

        fn deinit(exporter_ptr: *anyopaque) void {
            _ = exporter_ptr;
        }
    };

    var mock_exporter = MockExporter{};
    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = try SimpleSpanProcessor.init(
        allocator,
        mock_exporter.spanExporter(),
        resource,
    );
    defer processor.deinit();

    var span_processor = processor.spanProcessor();

    // Test force flush
    try testing.expectEqual(ProcessResult.success, span_processor.forceFlush(null));
    try testing.expect(mock_exporter.flush_called);

    // Test shutdown
    try testing.expectEqual(ProcessResult.success, span_processor.shutdown(null));
    try testing.expect(mock_exporter.shutdown_called);

    // Operations after shutdown should fail
    try testing.expectEqual(ProcessResult.failure, span_processor.forceFlush(null));
}
