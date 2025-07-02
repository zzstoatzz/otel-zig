//! OpenTelemetry Log Exporter Interface
//!
//! This module defines the LogExporter interface for exporting log records
//! to external systems. Exporters are responsible for serializing and
//! transmitting log data to backends like files, network endpoints, or databases.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md#logrecordexporter

const std = @import("std");
const otel_api = @import("otel-api");

const LogRecord = @import("log_record.zig").LogRecord;
const Resource = @import("../resource/resource.zig").Resource;
const ExportResult = @import("otel-api").common.ExportResult;

/// LogExporter interface using tagged union for polymorphism
pub const LogExporter = union(enum) {
    noop: void,
    bridge: BridgeLogExporter,

    /// Export a batch of log records.
    ///
    /// The caller is required to manage `records`. The exporter must be finished with
    /// the memory when this function returns. That includes making deep copies if
    /// necessary for buffering.
    pub fn exportRecords(self: *const LogExporter, records: []const LogRecord, resource: Resource) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.exportFn(exporter, records, resource),
        };
    }

    /// Force flush any buffered data
    pub fn forceFlush(self: *LogExporter, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.forceFlushFn(exporter, timeout_ms),
        };
    }

    /// Shutdown the exporter
    pub fn shutdown(self: *LogExporter, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.shutdownFn(exporter, timeout_ms),
        };
    }

    /// Clean up exporter resources
    pub fn deinit(self: *const LogExporter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |exporter| exporter.deinitFn(exporter),
        }
    }

    /// Destroy exporter memory
    pub fn destroy(self: *const LogExporter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |exporter| exporter.destroyFn(exporter.exporter_ptr),
        }
    }
};

/// Custom exporter with user-provided implementation
pub const BridgeLogExporter = struct {
    exporter_ptr: *anyopaque,
    exportFn: *const fn (self: BridgeLogExporter, records: []const LogRecord, resource: Resource) ExportResult,
    forceFlushFn: *const fn (self: BridgeLogExporter, timeout_ms: ?u64) ExportResult,
    shutdownFn: *const fn (self: BridgeLogExporter, timeout_ms: ?u64) ExportResult,
    deinitFn: *const fn (self: BridgeLogExporter) void,
    destroyFn: *const fn (ptr: *anyopaque) void,

    pub fn init(ptr: anytype) BridgeLogExporter {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn exportRecords(self: BridgeLogExporter, records: []const LogRecord, resource: Resource) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.exportRecords(actual_self, records, resource);
            }
            pub fn forceFlush(self: BridgeLogExporter, timeout_ms: ?u64) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.forceFlush(actual_self, timeout_ms);
            }
            pub fn shutdown(self: BridgeLogExporter, timeout_ms: ?u64) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.shutdown(actual_self, timeout_ms);
            }
            pub fn deinit(self: BridgeLogExporter) void {
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
            .exportFn = VTable.exportRecords,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
            .destroyFn = VTable.destroy,
        };
    }
};

/// Mock log exporter for testing purposes
/// Captures exported records for verification without external dependencies.
pub const MockLogExporter = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        Self,
        LogExporter,
        void,
        logExporter,
        _init,
        @import("../common/pipeline.zig").PipelineDeinitConnection,
    );
    const Self = @This();

    pub fn _init(self: *Self, _: void, allocator: std.mem.Allocator) !void {
        self.* = init(allocator);
    }

    allocator: std.mem.Allocator,
    exported_records: std.ArrayList(LogRecord),
    export_result: ExportResult,
    flush_result: ExportResult,
    shutdown_result: ExportResult,

    pub fn init(allocator: std.mem.Allocator) MockLogExporter {
        return .{
            .allocator = allocator,
            .exported_records = std.ArrayList(LogRecord).init(allocator),
            .export_result = .success,
            .flush_result = .success,
            .shutdown_result = .success,
        };
    }

    pub fn deinit(self: *MockLogExporter) void {
        self.exported_records.deinit();
    }

    pub fn destroy(self: *MockLogExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportRecords(self: *MockLogExporter, records: []const LogRecord, resource: Resource) ExportResult {
        _ = resource;
        for (records) |record| {
            // Deep copy the record since the exporter needs to own the data
            self.exported_records.append(record) catch return .failure;
        }
        return self.export_result;
    }

    pub fn forceFlush(self: *MockLogExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        return self.flush_result;
    }

    pub fn shutdown(self: *MockLogExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        return self.shutdown_result;
    }

    pub fn logExporter(self: *MockLogExporter) LogExporter {
        return LogExporter{ .bridge = BridgeLogExporter.init(self) };
    }

    // Test helpers
    pub fn clearRecords(self: *MockLogExporter) void {
        self.exported_records.clearRetainingCapacity();
    }

    pub fn recordCount(self: *const MockLogExporter) usize {
        return self.exported_records.items.len;
    }

    pub fn getRecord(self: *const MockLogExporter, index: usize) ?LogRecord {
        if (index >= self.exported_records.items.len) return null;
        return self.exported_records.items[index];
    }
};
