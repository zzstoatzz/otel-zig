//! OpenTelemetry Metrics Processor
//!
//! This module provides metric processors that collect measurements from instruments
//! and export them via metric exporters. Processors handle the timing and batching
//! of metric exports.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md#metricreader

const std = @import("std");
const otel_api = @import("otel-api");

const Context = otel_api.Context;
const KeyValue = otel_api.KeyValue;
const InstrumentationScope = otel_api.InstrumentationScope;
const Resource = @import("../resource/resource.zig").Resource;
const ExportResult = @import("../logs/exporter.zig").ExportResult;

/// Metric data point representing a single measurement
pub const MetricDataPoint = struct {
    /// Timestamp when the measurement was recorded
    timestamp_ns: u64,
    /// Start timestamp for monotonic counters (null for gauges)
    start_timestamp_ns: ?u64,
    /// Attributes associated with this data point
    attributes: []const KeyValue,
    /// The actual value
    value: MetricValue,
};

/// Possible metric values
pub const MetricValue = union(enum) {
    i64_sum: i64,
    f64_sum: f64,
    i64_gauge: i64,
    f64_gauge: f64,
    // Histogram support can be added later
};

/// Aggregated metric data
pub const MetricData = struct {
    /// Instrument name
    name: []const u8,
    /// Instrument description
    description: ?[]const u8,
    /// Unit of measurement
    unit: ?[]const u8,
    /// Type of metric
    type: MetricType,
    /// Aggregated data points
    data_points: []const MetricDataPoint,
    /// Instrumentation scope that created this metric
    scope: InstrumentationScope,
    /// Resource associated with this metric
    resource: *const Resource,
};

pub const MetricType = enum {
    sum,
    gauge,
    histogram,
};

/// Metric exporter interface
pub const MetricExporter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        exportFn: *const fn (ptr: *anyopaque, metrics: []const MetricData) ExportResult,
        forceFlush: *const fn (ptr: *anyopaque, timeout_ms: ?u64) ExportResult,
        shutdown: *const fn (ptr: *anyopaque, timeout_ms: ?u64) ExportResult,
    };

    pub fn exportMetrics(self: MetricExporter, metrics: []const MetricData) ExportResult {
        return self.vtable.exportFn(self.ptr, metrics);
    }

    pub fn forceFlush(self: MetricExporter, timeout_ms: ?u64) ExportResult {
        return self.vtable.forceFlush(self.ptr, timeout_ms);
    }

    pub fn shutdown(self: MetricExporter, timeout_ms: ?u64) ExportResult {
        return self.vtable.shutdown(self.ptr, timeout_ms);
    }
};

/// Metric processor interface
pub const MetricProcessor = union(enum) {
    simple: SimpleMetricProcessor,
    periodic: PeriodicMetricProcessor,

    pub fn collect(self: *MetricProcessor) !void {
        switch (self.*) {
            .simple => |*processor| try processor.collect(),
            .periodic => |*processor| try processor.collect(),
        }
    }

    pub fn forceFlush(self: *MetricProcessor, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .simple => |*processor| processor.forceFlush(timeout_ms),
            .periodic => |*processor| processor.forceFlush(timeout_ms),
        };
    }

    pub fn shutdown(self: *MetricProcessor) void {
        switch (self.*) {
            .simple => |*processor| processor.shutdown(),
            .periodic => |*processor| processor.shutdown(),
        }
    }
};

/// Simple processor that exports metrics immediately
pub const SimpleMetricProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: MetricExporter,
    mutex: std.Thread.Mutex,
    is_shutdown: bool,

    pub fn init(allocator: std.mem.Allocator, exporter: MetricExporter) SimpleMetricProcessor {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .is_shutdown = false,
        };
    }

    pub fn deinit(self: *SimpleMetricProcessor) void {
        _ = self;
    }

    pub fn collect(self: *SimpleMetricProcessor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return;

        // In a real implementation, this would:
        // 1. Iterate through all registered meter providers
        // 2. Collect metrics from all instruments
        // 3. Export them immediately
        // For MVP, we'll just note this is where collection happens
    }

    pub fn forceFlush(self: *SimpleMetricProcessor, timeout_ms: ?u64) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return .failure;

        return self.exporter.forceFlush(timeout_ms);
    }

    pub fn shutdown(self: *SimpleMetricProcessor) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return;

        self.is_shutdown = true;
        _ = self.exporter.shutdown(null);
    }
};

/// Periodic processor that exports metrics on a timer
pub const PeriodicMetricProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: MetricExporter,
    export_interval_ms: u64,
    export_timeout_ms: u64,
    mutex: std.Thread.Mutex,
    is_shutdown: bool,
    export_thread: ?std.Thread,
    shutdown_event: std.Thread.ResetEvent,

    pub fn init(
        allocator: std.mem.Allocator,
        exporter: MetricExporter,
        export_interval_ms: u64,
        export_timeout_ms: u64,
    ) PeriodicMetricProcessor {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .export_interval_ms = export_interval_ms,
            .export_timeout_ms = export_timeout_ms,
            .mutex = .{},
            .is_shutdown = false,
            .export_thread = null,
            .shutdown_event = .{},
        };
    }

    pub fn start(self: *PeriodicMetricProcessor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown or self.export_thread != null) return;

        self.export_thread = try std.Thread.spawn(.{}, exportLoop, .{self});
    }

    pub fn deinit(self: *PeriodicMetricProcessor) void {
        self.shutdown();
    }

    fn exportLoop(self: *PeriodicMetricProcessor) void {
        while (true) {
            // Wait for interval or shutdown signal
            self.shutdown_event.timedWait(self.export_interval_ms * std.time.ns_per_ms) catch {};

            self.mutex.lock();
            const should_exit = self.is_shutdown;
            self.mutex.unlock();

            if (should_exit) break;

            // Collect and export metrics
            self.collect() catch |err| {
                std.log.err("Failed to collect metrics: {}", .{err});
            };
        }
    }

    pub fn collect(self: *PeriodicMetricProcessor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.collectUnlocked();
    }

    fn collectUnlocked(self: *PeriodicMetricProcessor) !void {
        if (self.is_shutdown) return;

        // In a real implementation, this would:
        // 1. Iterate through all registered meter providers
        // 2. Collect metrics from all instruments
        // 3. Export them via the exporter
        // For MVP, we'll just note this is where collection happens
    }

    pub fn forceFlush(self: *PeriodicMetricProcessor, timeout_ms: ?u64) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return .failure;

        // Force a collection and export
        self.collectUnlocked() catch return .failure;
        return self.exporter.forceFlush(timeout_ms);
    }

    pub fn shutdown(self: *PeriodicMetricProcessor) void {
        self.mutex.lock();
        const thread = self.export_thread;
        self.is_shutdown = true;
        self.shutdown_event.set();
        self.mutex.unlock();

        if (thread) |t| {
            t.join();
        }

        _ = self.exporter.shutdown(null);
    }
};

/// Create a simple metric processor
pub fn createSimpleProcessor(allocator: std.mem.Allocator, exporter: MetricExporter) MetricProcessor {
    return .{ .simple = SimpleMetricProcessor.init(allocator, exporter) };
}

/// Create a periodic metric processor
pub fn createPeriodicProcessor(
    allocator: std.mem.Allocator,
    exporter: MetricExporter,
    export_interval_ms: u64,
    export_timeout_ms: u64,
) MetricProcessor {
    return .{ .periodic = PeriodicMetricProcessor.init(
        allocator,
        exporter,
        export_interval_ms,
        export_timeout_ms,
    ) };
}

// Tests

test "SimpleMetricProcessor operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a mock exporter
    const MockExporter = struct {
        export_called: bool = false,
        flush_called: bool = false,
        shutdown_called: bool = false,

        fn exportFn(ptr: *anyopaque, metrics: []const MetricData) ExportResult {
            const self = @as(*@This(), @ptrCast(@alignCast(ptr)));
            _ = metrics;
            self.export_called = true;
            return .success;
        }

        fn forceFlush(ptr: *anyopaque, timeout_ms: ?u64) ExportResult {
            const self = @as(*@This(), @ptrCast(@alignCast(ptr)));
            _ = timeout_ms;
            self.flush_called = true;
            return .success;
        }

        fn shutdown(ptr: *anyopaque, timeout_ms: ?u64) ExportResult {
            const self = @as(*@This(), @ptrCast(@alignCast(ptr)));
            _ = timeout_ms;
            self.shutdown_called = true;
            return .success;
        }
    };

    var mock = MockExporter{};
    const exporter = MetricExporter{
        .ptr = &mock,
        .vtable = &.{
            .exportFn = MockExporter.exportFn,
            .forceFlush = MockExporter.forceFlush,
            .shutdown = MockExporter.shutdown,
        },
    };

    var processor = createSimpleProcessor(allocator, exporter);
    defer processor.shutdown();

    // Test operations
    try processor.collect();
    
    const flush_result = processor.forceFlush(5000);
    try testing.expectEqual(ExportResult.success, flush_result);
    try testing.expect(mock.flush_called);
}

test "PeriodicMetricProcessor lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a mock exporter
    const MockExporter = struct {
        fn exportFn(ptr: *anyopaque, metrics: []const MetricData) ExportResult {
            _ = ptr;
            _ = metrics;
            return .success;
        }

        fn forceFlush(ptr: *anyopaque, timeout_ms: ?u64) ExportResult {
            _ = ptr;
            _ = timeout_ms;
            return .success;
        }

        fn shutdown(ptr: *anyopaque, timeout_ms: ?u64) ExportResult {
            _ = ptr;
            _ = timeout_ms;
            return .success;
        }
    };

    var mock = struct{}{};
    const exporter = MetricExporter{
        .ptr = &mock,
        .vtable = &.{
            .exportFn = MockExporter.exportFn,
            .forceFlush = MockExporter.forceFlush,
            .shutdown = MockExporter.shutdown,
        },
    };

    var processor = createPeriodicProcessor(allocator, exporter, 60000, 5000);
    defer processor.shutdown();

    // Start the processor
    if (processor == .periodic) {
        try processor.periodic.start();
    }

    // Test force flush
    const flush_result = processor.forceFlush(5000);
    try testing.expectEqual(ExportResult.success, flush_result);
}