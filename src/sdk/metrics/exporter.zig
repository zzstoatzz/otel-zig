const std = @import("std");
const otel_api = @import("otel-api");

const ExportResult = @import("otel-api").common.ExportResult;
const MetricData = @import("../metrics/data.zig").MetricData;

/// Metric exporter interface
pub const MetricExporter = union(enum) {
    noop: void,
    bridge: BridgeMetricExporter,

    /// Export a batch of metrics
    ///
    /// The caller is required to manage `metrics`. The exporter must be finished with
    /// the memory when this function returns. That includes making deep copies if
    /// necessary for buffering.
    pub fn exportMetrics(self: *MetricExporter, metrics: []const MetricData) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.exportFn(exporter, metrics),
        };
    }

    /// Force flush any buffered data
    pub fn forceFlush(self: *MetricExporter, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.forceFlushFn(exporter, timeout_ms),
        };
    }

    /// Shutdown the exporter
    pub fn shutdown(self: *MetricExporter, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.shutdownFn(exporter, timeout_ms),
        };
    }

    /// Clean up exporter resources
    pub fn deinit(self: *const MetricExporter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |exporter| exporter.deinitFn(exporter),
        }
    }

    /// Destroy exporter memory
    pub fn destroy(self: *const MetricExporter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |exporter| exporter.destroyFn(exporter.exporter_ptr),
        }
    }
};

pub const BridgeMetricExporter = struct {
    exporter_ptr: *anyopaque,
    exportFn: *const fn (ptr: BridgeMetricExporter, metrics: []const MetricData) ExportResult,
    forceFlushFn: *const fn (ptr: BridgeMetricExporter, timeout_ms: ?u64) ExportResult,
    shutdownFn: *const fn (ptr: BridgeMetricExporter, timeout_ms: ?u64) ExportResult,
    deinitFn: *const fn (self: BridgeMetricExporter) void,
    destroyFn: *const fn (ptr: *anyopaque) void,

    pub fn init(ptr: anytype) BridgeMetricExporter {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn exportMetrics(self: BridgeMetricExporter, metrics: []const MetricData) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.exportMetrics(actual_self, metrics);
            }
            pub fn forceFlush(self: BridgeMetricExporter, timeout_ms: ?u64) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.forceFlush(actual_self, timeout_ms);
            }
            pub fn shutdown(self: BridgeMetricExporter, timeout_ms: ?u64) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.shutdown(actual_self, timeout_ms);
            }
            pub fn deinit(self: BridgeMetricExporter) void {
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
            .exportFn = VTable.exportMetrics,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
            .destroyFn = VTable.destroy,
        };
    }
};

/// Mock metric exporter for testing purposes
/// Captures exported metrics for verification without external dependencies.
pub const MockMetricExporter = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        Self,
        MetricExporter,
        void,
        metricExporter,
        _init,
        @import("../common/pipeline.zig").PipelineDeinitConnection,
    );
    const Self = @This();

    pub fn _init(self: *Self, _: void, allocator: std.mem.Allocator) !void {
        self.* = init(allocator);
    }

    allocator: std.mem.Allocator,
    exported_metrics: std.ArrayList(MetricData),
    export_result: ExportResult,
    flush_result: ExportResult,
    shutdown_result: ExportResult,

    pub fn init(allocator: std.mem.Allocator) MockMetricExporter {
        return .{
            .allocator = allocator,
            .exported_metrics = std.ArrayList(MetricData).init(allocator),
            .export_result = .success,
            .flush_result = .success,
            .shutdown_result = .success,
        };
    }

    pub fn deinit(self: *MockMetricExporter) void {
        self.exported_metrics.deinit();
    }

    pub fn destroy(self: *MockMetricExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportMetrics(self: *MockMetricExporter, metrics: []const MetricData) ExportResult {
        for (metrics) |metric| {
            // Deep copy the metric since the exporter needs to own the data
            self.exported_metrics.append(metric) catch return .failure;
        }
        return self.export_result;
    }

    pub fn forceFlush(self: *MockMetricExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        return self.flush_result;
    }

    pub fn shutdown(self: *MockMetricExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        return self.shutdown_result;
    }

    pub fn metricExporter(self: *MockMetricExporter) MetricExporter {
        return MetricExporter{ .bridge = BridgeMetricExporter.init(self) };
    }

    // Test helpers
    pub fn clearMetrics(self: *MockMetricExporter) void {
        self.exported_metrics.clearRetainingCapacity();
    }

    pub fn metricCount(self: *const MockMetricExporter) usize {
        return self.exported_metrics.items.len;
    }

    pub fn getMetric(self: *const MockMetricExporter, index: usize) ?MetricData {
        if (index >= self.exported_metrics.items.len) return null;
        return self.exported_metrics.items[index];
    }
};
