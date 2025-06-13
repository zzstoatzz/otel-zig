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
};

pub const BridgeMetricExporter = struct {
    exporter_ptr: *anyopaque,
    exportFn: *const fn (ptr: BridgeMetricExporter, metrics: []const MetricData) ExportResult,
    forceFlushFn: *const fn (ptr: BridgeMetricExporter, timeout_ms: ?u64) ExportResult,
    shutdownFn: *const fn (ptr: BridgeMetricExporter, timeout_ms: ?u64) ExportResult,
    deinitFn: *const fn (self: BridgeMetricExporter) void,

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
        };

        return .{
            .exporter_ptr = ptr,
            .exportFn = VTable.exportMetrics,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
        };
    }
};
