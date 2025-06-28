//! OpenTelemetry Span Exporter Interface
//!
//! This module defines the SpanExporter interface for exporting spans
//! to various backends. Exporters are responsible for serializing and
//! transmitting span data to their destinations.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/sdk.md#span-exporter

const std = @import("std");
const otel_api = @import("otel-api");

const ExportResult = @import("otel-api").common.ExportResult;
const RecordingSpan = @import("data.zig").RecordingSpan;
const Resource = @import("../resource/resource.zig").Resource;

/// SpanExporter interface using tagged union for polymorphism
pub const SpanExporter = union(enum) {
    noop: void,
    bridge: BridgeSpanExporter,

    /// Export a batch of spans.
    ///
    /// The caller is required to manage `spans`. The exporter must be finished with
    /// the memory when this function returns. That includes making deep copies if
    /// necessary for buffering.
    pub fn exportSpans(self: *const SpanExporter, spans: []const *RecordingSpan, resource: Resource) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.exportFn(exporter, spans, resource),
        };
    }

    /// Force flush any buffered data
    pub fn forceFlush(self: *const SpanExporter, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.forceFlushFn(exporter, timeout_ms),
        };
    }

    /// Shutdown the exporter
    pub fn shutdown(self: *const SpanExporter, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.shutdownFn(exporter, timeout_ms),
        };
    }

    /// Clean up exporter resources
    pub fn deinit(self: *const SpanExporter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |exporter| exporter.deinitFn(exporter),
        }
    }

    /// Destroy exporter memory
    pub fn destroy(self: *const SpanExporter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |exporter| exporter.destroyFn(exporter.exporter_ptr),
        }
    }
};

/// Custom exporter with user-provided implementation
pub const BridgeSpanExporter = struct {
    exporter_ptr: *anyopaque,
    exportFn: *const fn (self: BridgeSpanExporter, spans: []const *RecordingSpan, resource: Resource) ExportResult,
    forceFlushFn: *const fn (self: BridgeSpanExporter, timeout_ms: ?u64) ExportResult,
    shutdownFn: *const fn (self: BridgeSpanExporter, timeout_ms: ?u64) ExportResult,
    deinitFn: *const fn (self: BridgeSpanExporter) void,
    destroyFn: *const fn (ptr: *anyopaque) void,

    pub fn init(ptr: anytype) BridgeSpanExporter {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn exportSpans(self: BridgeSpanExporter, spans: []const *RecordingSpan, resource: Resource) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.exportSpans(actual_self, spans, resource);
            }
            pub fn forceFlush(self: BridgeSpanExporter, timeout_ms: ?u64) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.forceFlush(actual_self, timeout_ms);
            }
            pub fn shutdown(self: BridgeSpanExporter, timeout_ms: ?u64) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.shutdown(actual_self, timeout_ms);
            }
            pub fn deinit(self: BridgeSpanExporter) void {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.deinit(actual_self);
            }
            pub fn destroy(pointer: *anyopaque) void {
                const actual_self: T = @ptrCast(@alignCast(pointer));
                actual_self.destroy();
            }
        };

        return .{
            .exporter_ptr = ptr,
            .exportFn = VTable.exportSpans,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
            .destroyFn = VTable.destroy,
        };
    }
};

/// Mock span exporter for testing purposes
/// Captures exported spans for verification without external dependencies.
pub const MockSpanExporter = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        Self,
        SpanExporter,
        void,
        spanExporter,
        _init,
        @import("../common/pipeline.zig").PipelineDeinitConnection,
    );
    const Self = @This();

    pub fn _init(_: void, allocator: std.mem.Allocator) !Self {
        return init(allocator);
    }

    allocator: std.mem.Allocator,
    exported_spans: std.ArrayList(*RecordingSpan),
    export_result: ExportResult,
    flush_result: ExportResult,
    shutdown_result: ExportResult,

    pub fn init(allocator: std.mem.Allocator) MockSpanExporter {
        return .{
            .allocator = allocator,
            .exported_spans = std.ArrayList(*RecordingSpan).init(allocator),
            .export_result = .success,
            .flush_result = .success,
            .shutdown_result = .success,
        };
    }

    pub fn deinit(self: *MockSpanExporter) void {
        self.exported_spans.deinit();
    }

    pub fn destroy(self: *MockSpanExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportSpans(self: *MockSpanExporter, spans: []const *RecordingSpan, resource: Resource) ExportResult {
        _ = resource;
        for (spans) |span| {
            // Store reference to span since the exporter needs to own the data
            self.exported_spans.append(span) catch return .failure;
        }
        return self.export_result;
    }

    pub fn forceFlush(self: *MockSpanExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        return self.flush_result;
    }

    pub fn shutdown(self: *MockSpanExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        return self.shutdown_result;
    }

    pub fn spanExporter(self: *MockSpanExporter) SpanExporter {
        return SpanExporter{ .bridge = BridgeSpanExporter.init(self) };
    }

    // Test helpers
    pub fn clearSpans(self: *MockSpanExporter) void {
        self.exported_spans.clearRetainingCapacity();
    }

    pub fn spanCount(self: *const MockSpanExporter) usize {
        return self.exported_spans.items.len;
    }

    pub fn getSpan(self: *const MockSpanExporter, index: usize) ?*RecordingSpan {
        if (index >= self.exported_spans.items.len) return null;
        return self.exported_spans.items[index];
    }
};

test "SpanExporter interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestExporter = struct {
        export_count: usize = 0,
        flush_count: usize = 0,
        shutdown_count: usize = 0,
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) !*@This() {
            const self = try alloc.create(@This());
            self.* = .{
                .allocator = alloc,
            };
            return self;
        }

        pub fn deinit(self: *@This()) void {
            // Nothing to deinit for this test struct
            _ = self;
        }

        pub fn destroy(self: *@This()) void {
            self.allocator.destroy(self);
        }

        pub fn exportSpans(self: *@This(), spans: []const *RecordingSpan, resource: Resource) ExportResult {
            _ = resource;
            self.export_count += spans.len;
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
    };

    const test_exporter = try TestExporter.init(allocator);
    defer test_exporter.destroy();

    const exporter = SpanExporter{ .bridge = BridgeSpanExporter.init(test_exporter) };

    // Test export
    const spans = [_]*RecordingSpan{};
    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };
    try testing.expectEqual(ExportResult.success, exporter.exportSpans(&spans, resource));

    // Test flush
    try testing.expectEqual(ExportResult.success, exporter.forceFlush(null));
    try testing.expectEqual(@as(usize, 1), test_exporter.flush_count);

    // Test shutdown
    try testing.expectEqual(ExportResult.success, exporter.shutdown(null));
    try testing.expectEqual(@as(usize, 1), test_exporter.shutdown_count);
}

test "MockSpanExporter functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock = MockSpanExporter.init(allocator);
    defer mock.deinit();

    const exporter = mock.spanExporter();

    // Test initial state
    try testing.expectEqual(@as(usize, 0), mock.spanCount());

    // Test export (without actual spans for this test)
    const spans = [_]*RecordingSpan{};
    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };
    try testing.expectEqual(ExportResult.success, exporter.exportSpans(&spans, resource));

    // Test lifecycle methods
    try testing.expectEqual(ExportResult.success, exporter.forceFlush(5000));
    try testing.expectEqual(ExportResult.success, exporter.shutdown(5000));

    // Test failure scenarios
    mock.export_result = .failure;
    try testing.expectEqual(ExportResult.failure, exporter.exportSpans(&spans, resource));
}
