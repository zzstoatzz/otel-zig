//! OpenTelemetry Log Exporter Interface
//!
//! This module defines the LogExporter interface for exporting log records
//! to external systems. Exporters are responsible for serializing and
//! transmitting log data to backends like files, network endpoints, or databases.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md#logrecordexporter

const std = @import("std");
const otel_api = @import("otel-api");

const LogRecord = otel_api.logs.LogRecord;
const Resource = @import("../resource/resource.zig").Resource;

/// Result of an export operation
pub const ExportResult = enum {
    success,
    failure,
    
    pub fn isSuccess(self: ExportResult) bool {
        return self == .success;
    }
    
    pub fn isFailure(self: ExportResult) bool {
        return self == .failure;
    }
};

/// LogExporter interface using tagged union for polymorphism
pub const LogExporter = union(enum) {
    console: *ConsoleExporter,
    file: *FileExporter,
    custom: *CustomExporter,
    
    /// Export a batch of log records
    pub fn exportRecords(self: *LogExporter, records: []const LogRecord, resource: *const Resource) ExportResult {
        return switch (self.*) {
            .console => |exporter| exporter.exportFn(exporter, records, resource),
            .file => |exporter| exporter.exportFn(exporter, records, resource),
            .custom => |exporter| exporter.@"export"(records, resource),
        };
    }
    
    /// Force flush any buffered data
    pub fn forceFlush(self: *LogExporter, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .console => |exporter| exporter.forceFlushFn(exporter, timeout_ms),
            .file => |exporter| exporter.forceFlushFn(exporter, timeout_ms),
            .custom => |exporter| exporter.forceFlush(timeout_ms),
        };
    }
    
    /// Shutdown the exporter
    pub fn shutdown(self: *LogExporter, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .console => |exporter| exporter.shutdownFn(exporter, timeout_ms),
            .file => |exporter| exporter.shutdownFn(exporter, timeout_ms),
            .custom => |exporter| exporter.shutdown(timeout_ms),
        };
    }
    
    /// Clean up exporter resources
    /// Clean up the exporter
    pub fn deinit(self: *LogExporter) void {
        switch (self.*) {
            .console => |exporter| exporter.deinitFn(exporter),
            .file => |exporter| exporter.deinitFn(exporter),
            .custom => |exporter| exporter.deinit(),
        }
    }
};

/// Interface for console exporter (defined in exporters module)
pub const ConsoleExporter = struct {
    exportFn: *const fn (self: *ConsoleExporter, records: []const LogRecord, resource: *const Resource) ExportResult,
    forceFlushFn: *const fn (self: *ConsoleExporter, timeout_ms: ?u64) ExportResult,
    shutdownFn: *const fn (self: *ConsoleExporter, timeout_ms: ?u64) ExportResult,
    deinitFn: *const fn (self: *ConsoleExporter) void,
};

/// Interface for file exporter (defined in exporters module)
pub const FileExporter = struct {
    exportFn: *const fn (self: *FileExporter, records: []const LogRecord, resource: *const Resource) ExportResult,
    forceFlushFn: *const fn (self: *FileExporter, timeout_ms: ?u64) ExportResult,
    shutdownFn: *const fn (self: *FileExporter, timeout_ms: ?u64) ExportResult,
    deinitFn: *const fn (self: *FileExporter) void,
};

/// Custom exporter with user-provided implementation
pub const CustomExporter = struct {
    impl: *anyopaque,
    exportFn: *const fn (impl: *anyopaque, records: []const LogRecord, resource: *const Resource) ExportResult,
    forceFlushFn: *const fn (impl: *anyopaque, timeout_ms: ?u64) ExportResult,
    shutdownFn: *const fn (impl: *anyopaque, timeout_ms: ?u64) ExportResult,
    deinitFn: *const fn (impl: *anyopaque) void,
    
    pub fn @"export"(self: *CustomExporter, records: []const LogRecord, resource: *const Resource) ExportResult {
        return self.exportFn(self.impl, records, resource);
    }
    
    pub fn forceFlush(self: *CustomExporter, timeout_ms: ?u64) ExportResult {
        return self.forceFlushFn(self.impl, timeout_ms);
    }
    
    pub fn shutdown(self: *CustomExporter, timeout_ms: ?u64) ExportResult {
        return self.shutdownFn(self.impl, timeout_ms);
    }
    
    pub fn deinit(self: *CustomExporter) void {
        self.deinitFn(self.impl);
    }
};

/// Create a custom exporter
pub fn createCustomExporter(
    impl: *anyopaque,
    exportFn: *const fn (impl: *anyopaque, records: []const LogRecord, resource: *const Resource) ExportResult,
    forceFlushFn: *const fn (impl: *anyopaque, timeout_ms: ?u64) ExportResult,
    shutdownFn: *const fn (impl: *anyopaque, timeout_ms: ?u64) ExportResult,
    deinitFn: *const fn (impl: *anyopaque) void,
) CustomExporter {
    return .{
        .impl = impl,
        .exportFn = exportFn,
        .forceFlushFn = forceFlushFn,
        .shutdownFn = shutdownFn,
        .deinitFn = deinitFn,
    };
}

test "ExportResult operations" {
    const testing = std.testing;
    
    const success = ExportResult.success;
    const failure = ExportResult.failure;
    
    try testing.expect(success.isSuccess());
    try testing.expect(!success.isFailure());
    try testing.expect(!failure.isSuccess());
    try testing.expect(failure.isFailure());
}

test "CustomExporter operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const TestImpl = struct {
        export_count: usize = 0,
        last_batch_size: usize = 0,
        flushed: bool = false,
        is_shutdown: bool = false,
        
        fn exportRecords(impl: *anyopaque, records: []const LogRecord, resource: *const Resource) ExportResult {
            _ = resource;
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            self.export_count += 1;
            self.last_batch_size = records.len;
            return .success;
        }
        
        fn forceFlush(impl: *anyopaque, timeout_ms: ?u64) ExportResult {
            _ = timeout_ms;
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            self.flushed = true;
            return .success;
        }
        
        fn shutdown(impl: *anyopaque, timeout_ms: ?u64) ExportResult {
            _ = timeout_ms;
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            self.is_shutdown = true;
            return .success;
        }
        
        fn deinit(impl: *anyopaque) void {
            _ = impl;
        }
    };
    
    var impl = TestImpl{};
    var custom = createCustomExporter(
        &impl,
        TestImpl.exportRecords,
        TestImpl.forceFlush,
        TestImpl.shutdown,
        TestImpl.deinit,
    );
    
    var exporter = LogExporter{ .custom = &custom };
    defer exporter.deinit();
    
    // Test export
    const records = try allocator.alloc(LogRecord, 3);
    defer allocator.free(records);
    
    for (records) |*record| {
        record.* = LogRecord{
            .severity_number = .info,
            .body = otel_api.AttributeValue{ .string = "test message" },
        };
    }
    
    const test_resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer test_resource.deinitOwned(allocator);
    
    const result = exporter.exportRecords(records, &test_resource);
    try testing.expectEqual(ExportResult.success, result);
    try testing.expectEqual(@as(usize, 1), impl.export_count);
    try testing.expectEqual(@as(usize, 3), impl.last_batch_size);
    
    // Test flush
    const flush_result = exporter.forceFlush(5000);
    try testing.expectEqual(ExportResult.success, flush_result);
    try testing.expect(impl.flushed);
    
    // Test shutdown
    const shutdown_result = exporter.shutdown(5000);
    try testing.expectEqual(ExportResult.success, shutdown_result);
    try testing.expect(impl.is_shutdown);
}