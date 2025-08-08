//! Basic Periodic Metrics Processor
//!
//! This module provides a basic metrics processor that collects metrics from registered
//! meters on a periodic basis using a background thread. It uses POSIX threads
//! for cross-platform compatibility.
//!
//! The processor maintains a thread that wakes up at regular intervals to collect
//! metrics from all registered meters and export them via the configured exporter.

const std = @import("std");
const api = @import("otel-api");
const c = std.c;

const sdk = struct {
    const BridgeReader = @import("reader.zig").BridgeReader;
    const Meter = @import("meter.zig").Meter;
    const MetricData = @import("data.zig").MetricData;
    const Reader = @import("reader.zig").Reader;
    const MetricExporter = @import("exporter.zig").MetricExporter;
    const ReaderAggregationState = @import("reader_aggregation_state.zig").ReaderAggregationState;
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const MetricValue = @import("reader.zig").MetricValue;
};

/// Basic periodic metrics processor that collects metrics at regular intervals
pub const PeriodicReader = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        PeriodicReader,
        sdk.Reader,
        ?u32,
        reader,
        _initFn,
        setExporter,
    );
    pub fn _initFn(self: *PeriodicReader, interval: ?u32, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, null, interval);
        try self.start();
    }

    allocator: std.mem.Allocator,
    exporter: ?sdk.MetricExporter,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    is_shutdown: std.atomic.Value(bool),
    is_running: std.atomic.Value(bool),
    flush_in_progress: std.atomic.Value(bool),
    collection_in_progress: std.atomic.Value(bool),
    flush_complete: std.Thread.Condition,
    collection_complete: std.Thread.Condition,
    last_collection_time: std.atomic.Value(i64),
    thread: ?std.Thread,
    collection_interval_ms: u32,
    registered_meters: std.ArrayListUnmanaged(*sdk.Meter),
    reader_state: sdk.ReaderAggregationState,

    /// Initialize a new basic periodic metrics processor
    /// collection_interval_ms: How often to collect metrics (default: 60000ms = 60s)
    pub fn init(
        allocator: std.mem.Allocator,
        exporter: ?sdk.MetricExporter,
        collection_interval_ms: ?u32,
    ) PeriodicReader {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .condition = .{},
            .is_shutdown = std.atomic.Value(bool).init(false),
            .is_running = std.atomic.Value(bool).init(false),
            .flush_in_progress = std.atomic.Value(bool).init(false),
            .collection_in_progress = std.atomic.Value(bool).init(false),
            .flush_complete = .{},
            .collection_complete = .{},
            .last_collection_time = std.atomic.Value(i64).init(0),
            .thread = null,
            .collection_interval_ms = collection_interval_ms orelse 60000, // 60 seconds default
            .registered_meters = .{},
            .reader_state = sdk.ReaderAggregationState.init(
                allocator,
                .Delta, // Default to Delta temporality for now
                @import("reader_aggregation_state.zig").defaultAggregationSelector,
            ),
        };
    }

    /// Start the background collection thread
    pub fn start(self: *PeriodicReader) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_running.load(.acquire) or self.thread != null) {
            return;
        }

        self.is_running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, collectionThreadFn, .{self});
    }

    /// Stop the background collection thread and clean up resources
    pub fn deinit(self: *PeriodicReader) void {
        // Signal shutdown
        self.is_shutdown.store(true, .release);
        self.is_running.store(false, .release);

        self.mutex.lock();
        self.condition.signal();
        self.mutex.unlock();

        // Wait for thread to finish
        if (self.thread) |thread| {
            thread.join();
        }

        // Clean up resources
        self.reader_state.deinit();
        self.registered_meters.deinit(self.allocator);
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    /// Destroy the processor and free its memory
    pub fn destroy(self: *PeriodicReader) void {
        self.allocator.destroy(self);
    }

    pub fn recordMeasurement(
        self: *PeriodicReader,
        instrument: *anyopaque,
        value: sdk.MetricValue,
        attributes: []const api.AttributeKeyValue,
        metadata: sdk.MetricMetadata,
    ) void {
        self.reader_state.recordMeasurement(instrument, value, attributes, metadata);
    }

    /// Collect metrics from all registered meters (called by background thread)
    pub fn collect(self: *PeriodicReader) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown.load(.acquire)) return;

        // Collect from reader state (regular instruments)
        var collected_metrics = std.ArrayList(sdk.MetricData).init(arena_allocator);

        const reader_state_metrics = self.reader_state.collect(arena_allocator) catch {
            // Log error if needed
            return;
        };
        collected_metrics.appendSlice(reader_state_metrics) catch return;

        // Collect from observable instruments in registered meters
        for (self.registered_meters.items) |meter| {
            // Collect from i64 observable counters
            for (meter.observable_counters_i64.items) |obs_counter| {
                const data_points = obs_counter.collect(arena_allocator) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_counter.name,
                        .description = obs_counter.description,
                        .unit = obs_counter.unit,
                        .type = .sum,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }

            // Collect from f64 observable counters
            for (meter.observable_counters_f64.items) |obs_counter| {
                const data_points = obs_counter.collect(arena_allocator) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_counter.name,
                        .description = obs_counter.description,
                        .unit = obs_counter.unit,
                        .type = .sum,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }

            // Collect from i64 observable gauges
            for (meter.observable_gauges_i64.items) |obs_gauge| {
                const data_points = obs_gauge.collect(arena_allocator) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_gauge.name,
                        .description = obs_gauge.description,
                        .unit = obs_gauge.unit,
                        .type = .gauge,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }

            // Collect from f64 observable gauges
            for (meter.observable_gauges_f64.items) |obs_gauge| {
                const data_points = obs_gauge.collect(arena_allocator) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_gauge.name,
                        .description = obs_gauge.description,
                        .unit = obs_gauge.unit,
                        .type = .gauge,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }

            // Collect from i64 observable up-down counters
            for (meter.observable_updown_counters_i64.items) |obs_updown| {
                const data_points = obs_updown.collect(arena_allocator) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_updown.name,
                        .description = obs_updown.description,
                        .unit = obs_updown.unit,
                        .type = .sum,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }

            // Collect from f64 observable up-down counters
            for (meter.observable_updown_counters_f64.items) |obs_updown| {
                const data_points = obs_updown.collect(arena_allocator) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_updown.name,
                        .description = obs_updown.description,
                        .unit = obs_updown.unit,
                        .type = .sum,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }
        }

        // Export all collected metrics. Exporter must copy memory
        // that it needs beyond the duration of this call.
        if (self.exporter) |*exporter| _ = exporter.exportMetrics(collected_metrics.items);
        // Arena cleans up all the memory.
    }

    /// Force flush the exporter
    pub fn forceFlush(self: *PeriodicReader, timeout_ms: ?u64) api.common.ProcessResult {
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

        // Wait for any collection in progress
        while (self.collection_in_progress.load(.acquire)) {
            const remaining_ms = if (timeout_ms) |ms|
                ms -| @as(u64, @intCast(std.time.milliTimestamp() - start_time))
            else
                null;

            if (remaining_ms == 0) {
                return .timeout;
            }

            if (remaining_ms) |ms| {
                self.collection_complete.timedWait(&self.mutex, ms * std.time.ns_per_ms) catch {
                    return .timeout;
                };
            } else {
                self.collection_complete.wait(&self.mutex);
            }
        }

        // Now do immediate collection with atomic flag
        self.collection_in_progress.store(true, .release);
        defer {
            self.collection_in_progress.store(false, .release);
            self.collection_complete.broadcast();
        }

        // Perform immediate metric collection
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Collect from reader state (regular instruments)
        var collected_metrics = std.ArrayList(sdk.MetricData).init(arena.allocator());

        const reader_state_metrics = self.reader_state.collect(arena.allocator()) catch {
            return .failure;
        };
        collected_metrics.appendSlice(reader_state_metrics) catch return .failure;

        // Collect from observable instruments in registered meters
        for (self.registered_meters.items) |meter| {
            // Collect from i64 observable counters
            for (meter.observable_counters_i64.items) |obs_counter| {
                const data_points = obs_counter.collect(arena.allocator()) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_counter.name,
                        .description = obs_counter.description,
                        .unit = obs_counter.unit,
                        .type = .sum,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }

            // Collect from f64 observable counters
            for (meter.observable_counters_f64.items) |obs_counter| {
                const data_points = obs_counter.collect(arena.allocator()) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_counter.name,
                        .description = obs_counter.description,
                        .unit = obs_counter.unit,
                        .type = .sum,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }

            // Collect from i64 observable gauges
            for (meter.observable_gauges_i64.items) |obs_gauge| {
                const data_points = obs_gauge.collect(arena.allocator()) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_gauge.name,
                        .description = obs_gauge.description,
                        .unit = obs_gauge.unit,
                        .type = .gauge,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }

            // Collect from f64 observable gauges
            for (meter.observable_gauges_f64.items) |obs_gauge| {
                const data_points = obs_gauge.collect(arena.allocator()) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_gauge.name,
                        .description = obs_gauge.description,
                        .unit = obs_gauge.unit,
                        .type = .gauge,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }

            // Collect from i64 observable up-down counters
            for (meter.observable_updown_counters_i64.items) |obs_updown| {
                const data_points = obs_updown.collect(arena.allocator()) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_updown.name,
                        .description = obs_updown.description,
                        .unit = obs_updown.unit,
                        .type = .sum,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }

            // Collect from f64 observable up-down counters
            for (meter.observable_updown_counters_f64.items) |obs_updown| {
                const data_points = obs_updown.collect(arena.allocator()) catch continue;
                if (data_points.len > 0) {
                    const metric_data = sdk.MetricData{
                        .name = obs_updown.name,
                        .description = obs_updown.description,
                        .unit = obs_updown.unit,
                        .type = .sum,
                        .data_points = data_points,
                        .scope = meter.scope,
                        .resource = meter.resource,
                    };
                    collected_metrics.append(metric_data) catch continue;
                }
            }
        }

        // Update last collection time atomically
        self.last_collection_time.store(std.time.milliTimestamp(), .release);

        // Export if we have metrics
        if (collected_metrics.items.len > 0 and self.exporter != null) {
            // Temporarily release mutex for export
            self.mutex.unlock();
            const export_result = self.exporter.?.exportMetrics(collected_metrics.items);
            self.mutex.lock();

            if (export_result != .success) {
                return .failure;
            }
        }

        // Flush the exporter
        if (self.exporter) |*exporter| {
            self.mutex.unlock();
            const flush_result = exporter.forceFlush(timeout_ms);
            self.mutex.lock();

            return if (flush_result == .success) .success else .failure;
        }

        return .success;
    }

    /// Shutdown the processor
    pub fn shutdown(self: *PeriodicReader, timeout_ms: ?u64) api.common.ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown.swap(true, .seq_cst)) {
            return .success;
        }

        self.is_running.store(false, .release);
        self.condition.signal();

        // Shutdown the exporter
        const result = if (self.exporter) |*exporter| exporter.shutdown(timeout_ms) else .success;
        return if (result == .success) .success else .failure;
    }

    /// Register a meter for periodic collection
    pub fn registerMeter(self: *PeriodicReader, meter: *sdk.Meter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown.load(.acquire)) return;

        self.registered_meters.append(self.allocator, meter) catch {
            // Handle allocation failure silently for now
            return;
        };
    }

    /// Unregister a meter from periodic collection
    pub fn unregisterMeter(self: *PeriodicReader, meter: *sdk.Meter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown.load(.acquire)) return;

        for (self.registered_meters.items, 0..) |registered_meter, i| {
            if (registered_meter == meter) {
                _ = self.registered_meters.swapRemove(i);
                break;
            }
        }
    }

    /// Set the exporter for this processor
    pub fn setExporter(self: *PeriodicReader, exporter: ?sdk.MetricExporter) !void {
        if (self.exporter) |old_exporter| {
            old_exporter.deinit();
            old_exporter.destroy();
        }
        self.exporter = exporter;
    }

    /// Get the processor as a MetricProcessor union
    pub fn reader(self: *PeriodicReader) sdk.Reader {
        return .{ .bridge = sdk.BridgeReader.init(self) };
    }

    /// Background thread function that periodically collects metrics
    fn collectionThreadFn(self: *PeriodicReader) void {
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
            const wait_ns = @as(u64, self.collection_interval_ms) * std.time.ns_per_ms;

            // Wait for the specified interval or until signaled
            self.condition.timedWait(&self.mutex, wait_ns) catch {
                // Timeout - normal collection cycle
            };

            // Skip if flush is in progress
            if (self.flush_in_progress.load(.acquire)) {
                continue;
            }

            // Try to acquire collection lock
            if (self.collection_in_progress.swap(true, .seq_cst)) {
                // Already collecting, skip this cycle
                continue;
            }

            defer {
                self.collection_in_progress.store(false, .release);
                self.collection_complete.broadcast();
            }

            // Update last collection time
            self.last_collection_time.store(std.time.milliTimestamp(), .release);

            // Do the collection
            self.mutex.unlock();
            self.collect();
            self.mutex.lock();
        }
    }
};

test "BasicPeriodicProcessor - direct init vs pipeline init thread behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const MockExporter = @import("exporter.zig").MockMetricExporter;
    const Resource = @import("../resource/resource.zig").Resource;

    // Create mock exporter
    const mock_exporter = try allocator.create(MockExporter);
    mock_exporter.* = MockExporter.init(allocator);

    // Create processor with very short interval for testing (direct init)
    var processor = PeriodicReader.init(allocator, mock_exporter.metricExporter(), 100); // 100ms
    defer processor.deinit();

    // Verify thread is not running when created via direct init()
    try testing.expect(!processor.is_running.load(.acquire));
    try testing.expect(processor.thread == null);

    // Create a basic meter for testing
    const scope = try api.InstrumentationScope.initSimple("test.meter", "1.0.0");
    const resource = Resource.empty;
    const basic_meter = try allocator.create(sdk.Meter);
    basic_meter.* = try sdk.Meter.init(allocator, scope, resource, null);
    defer {
        basic_meter.deinit();
        allocator.destroy(basic_meter);
    }

    // Start the thread manually (since we're not using pipeline)
    try processor.start();

    // Verify thread is now running
    try testing.expect(processor.is_running.load(.acquire));
    try testing.expect(processor.thread != null);

    // Register meter
    processor.registerMeter(basic_meter);

    // Create a second meter
    const scope2 = try api.InstrumentationScope.initSimple("test.meter2", "1.0.0");
    const basic_meter2 = try allocator.create(sdk.Meter);
    basic_meter2.* = try sdk.Meter.init(allocator, scope2, resource, null);
    defer {
        basic_meter2.deinit();
        allocator.destroy(basic_meter2);
    }

    // Register second meter
    processor.registerMeter(basic_meter2);

    // Verify thread is still running and we have both meters
    try testing.expect(processor.is_running.load(.acquire));
    try testing.expect(processor.thread != null);
    try testing.expect(processor.registered_meters.items.len == 2);

    // Wait a bit to allow some collections to happen
    std.time.sleep(250 * std.time.ns_per_ms);

    // Verify some exports happened (thread is working)
    const export_count = mock_exporter.exportCount();
    try testing.expect(export_count > 0);

    // Test shutdown - should stop the thread
    _ = processor.shutdown(1000);
    try testing.expect(processor.is_shutdown.load(.acquire));

    // Give thread time to exit
    std.time.sleep(50 * std.time.ns_per_ms);
}

test "BasicPeriodicProcessor - no thread start without meters" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create processor
    var processor = PeriodicReader.init(allocator, null, 100);
    defer processor.deinit();

    // Verify thread is not running
    try testing.expect(!processor.is_running.load(.acquire));
    try testing.expect(processor.thread == null);

    // Call forceFlush - should not crash
    const result = processor.forceFlush(100);
    try testing.expect(result == .success);

    // Thread should still not be running
    try testing.expect(!processor.is_running.load(.acquire));
    try testing.expect(processor.thread == null);

    // Shutdown should work fine
    _ = processor.shutdown(100);
    try testing.expect(processor.is_shutdown.load(.acquire));
}
