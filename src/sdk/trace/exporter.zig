//! OpenTelemetry Span Exporter Interface
//!
//! This module defines the SpanExporter interface for exporting spans
//! to various backends. Exporters are responsible for serializing and
//! transmitting span data to their destinations.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/sdk.md#span-exporter

const std = @import("std");
const otel_api = @import("otel-api");

const ProcessResult = otel_api.common.ProcessResult;
const RecordingSpan = @import("data.zig").RecordingSpan;
const Resource = @import("../resource/resource.zig").Resource;

/// SpanExporter interface for exporting spans
pub const SpanExporter = struct {
    exporter_ptr: *anyopaque,
    exportSpansFn: *const fn (exporter_ptr: *anyopaque, spans: []const *RecordingSpan, resource: Resource) ProcessResult,
    forceFlushFn: *const fn (exporter_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    shutdownFn: *const fn (exporter_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    deinitFn: *const fn (exporter_ptr: *anyopaque) void,

    /// Export a batch of spans
    pub fn exportSpans(self: SpanExporter, spans: []const *RecordingSpan, resource: Resource) ProcessResult {
        return self.exportSpansFn(self.exporter_ptr, spans, resource);
    }

    /// Force flush any buffered spans
    pub fn forceFlush(self: SpanExporter, timeout_ms: ?u64) ProcessResult {
        return self.forceFlushFn(self.exporter_ptr, timeout_ms);
    }

    /// Shutdown the exporter
    pub fn shutdown(self: SpanExporter, timeout_ms: ?u64) ProcessResult {
        return self.shutdownFn(self.exporter_ptr, timeout_ms);
    }

    /// Clean up exporter resources
    pub fn deinit(self: SpanExporter) void {
        self.deinitFn(self.exporter_ptr);
    }
};

/// Helper to create a SpanExporter from any type that implements the required methods
pub fn createSpanExporter(ptr: anytype) SpanExporter {
    const T = @TypeOf(ptr);
    const ptr_info = @typeInfo(T);

    const VTable = struct {
        pub fn exportSpans(exporter_ptr: *anyopaque, spans: []const *RecordingSpan, resource: Resource) ProcessResult {
            const self: T = @ptrCast(@alignCast(exporter_ptr));
            return ptr_info.pointer.child.exportSpans(self, spans, resource);
        }
        pub fn forceFlush(exporter_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult {
            const self: T = @ptrCast(@alignCast(exporter_ptr));
            return ptr_info.pointer.child.forceFlush(self, timeout_ms);
        }
        pub fn shutdown(exporter_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult {
            const self: T = @ptrCast(@alignCast(exporter_ptr));
            return ptr_info.pointer.child.shutdown(self, timeout_ms);
        }
        pub fn deinit(exporter_ptr: *anyopaque) void {
            const self: T = @ptrCast(@alignCast(exporter_ptr));
            return ptr_info.pointer.child.deinit(self);
        }
    };

    return .{
        .exporter_ptr = ptr,
        .exportSpansFn = VTable.exportSpans,
        .forceFlushFn = VTable.forceFlush,
        .shutdownFn = VTable.shutdown,
        .deinitFn = VTable.deinit,
    };
}

/// Result of an export operation
pub const ExportResult = enum {
    success,
    failure,
};

test "SpanExporter interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const MockExporter = struct {
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
            self.allocator.destroy(self);
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
    };

    const mock = try MockExporter.init(allocator);
    defer mock.deinit();

    const exporter = createSpanExporter(mock);

    // Test export
    const spans = [_]*RecordingSpan{};
    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };
    try testing.expectEqual(ProcessResult.success, exporter.exportSpans(&spans, resource));

    // Test flush
    try testing.expectEqual(ProcessResult.success, exporter.forceFlush(null));
    try testing.expectEqual(@as(usize, 1), mock.flush_count);

    // Test shutdown
    try testing.expectEqual(ProcessResult.success, exporter.shutdown(null));
    try testing.expectEqual(@as(usize, 1), mock.shutdown_count);
}
