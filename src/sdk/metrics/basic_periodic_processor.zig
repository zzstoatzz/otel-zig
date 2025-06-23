//! Basic Periodic Metrics Processor
//!
//! This module provides a basic metrics processor that collects metrics from registered
//! meters on a periodic basis using a background thread. It uses POSIX threads
//! for cross-platform compatibility.
//!
//! The processor maintains a thread that wakes up at regular intervals to collect
//! metrics from all registered meters and export them via the configured exporter.

const std = @import("std");
const c = std.c;
const otel_api = @import("otel-api");

const ProcessResult = otel_api.common.ProcessResult;
const MetricData = @import("data.zig").MetricData;
const MetricExporter = @import("exporter.zig").MetricExporter;
const BasicMeter = @import("basic_provider.zig").BasicMeter;
const MetricProcessor = @import("processor.zig").MetricProcessor;

/// Basic periodic metrics processor that collects metrics at regular intervals
pub const BasicPeriodicProcessor = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        BasicPeriodicProcessor,
        MetricProcessor,
        ?u32,
        metricProcessor,
        _initFn,
        setExporter,
    );
    pub fn _initFn(interval: ?u32, allocator: std.mem.Allocator) !BasicPeriodicProcessor {
        var processor = init(allocator, null, interval);
        errdefer processor.deinit();

        try processor.start();
        return processor;
    }

    allocator: std.mem.Allocator,
    exporter: ?MetricExporter,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    is_shutdown: bool,
    is_running: bool,
    thread: ?std.Thread,
    collection_interval_ms: u32,
    registered_meters: std.ArrayListUnmanaged(*BasicMeter),

    /// Initialize a new basic periodic metrics processor
    /// collection_interval_ms: How often to collect metrics (default: 60000ms = 60s)
    pub fn init(
        allocator: std.mem.Allocator,
        exporter: ?MetricExporter,
        collection_interval_ms: ?u32,
    ) BasicPeriodicProcessor {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .condition = .{},
            .is_shutdown = false,
            .is_running = false,
            .thread = null,
            .collection_interval_ms = collection_interval_ms orelse 60000, // 60 seconds default
            .registered_meters = .{},
        };
    }

    /// Start the background collection thread
    pub fn start(self: *BasicPeriodicProcessor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_running or self.is_shutdown) {
            return;
        }

        self.is_running = true;
        self.thread = try std.Thread.spawn(.{}, collectionThreadFn, .{self});
    }

    /// Stop the background collection thread and clean up resources
    pub fn deinit(self: *BasicPeriodicProcessor) void {
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

        // Clean up resources
        self.registered_meters.deinit(self.allocator);
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    /// Destroy the processor and free its memory
    pub fn destroy(self: *BasicPeriodicProcessor) void {
        self.allocator.destroy(self);
    }

    /// Collect metrics from all registered meters (called by background thread)
    pub fn collect(self: *BasicPeriodicProcessor) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return;

        // Initialize collection data structure
        var collected_metrics = std.ArrayList(MetricData).init(arena_allocator);

        // Iterate through registered meters
        for (self.registered_meters.items) |meter| {
            // Collect from each meter, continue on errors
            const meter_metrics = meter.collectMetrics(arena_allocator) catch {
                // Log error if needed, but continue with next meter
                continue;
            };

            // Append to main collection, continue on errors
            collected_metrics.appendSlice(meter_metrics) catch {
                // Could log allocation failure, but continue
                continue;
            };
        }

        // Export all collected metrics. Exporter must copy memory
        // that it needs beyond the duration of this call.
        if (self.exporter) |*exporter| _ = exporter.exportMetrics(collected_metrics.items);
        // Arena cleans up all the memory.
    }

    /// Force flush the exporter
    pub fn forceFlush(self: *BasicPeriodicProcessor, timeout_ms: ?u64) ProcessResult {
        // Collect immediately before flushing
        // This has to be before the mutex, because collect expects
        // to take the mutex.
        self.collect();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = if (self.exporter) |*exporter| exporter.forceFlush(timeout_ms) else .success;
        return if (result == .success) .success else .failure;
    }

    /// Shutdown the processor
    pub fn shutdown(self: *BasicPeriodicProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;
        self.condition.signal(); // Wake up the collection thread

        // Shutdown the exporter
        const result = if (self.exporter) |*exporter| exporter.shutdown(timeout_ms) else .success;
        return if (result == .success) .success else .failure;
    }

    /// Register a meter for periodic collection
    pub fn registerMeter(self: *BasicPeriodicProcessor, meter: *BasicMeter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return;

        self.registered_meters.append(self.allocator, meter) catch {
            // Handle allocation failure silently for now
            return;
        };
    }

    /// Unregister a meter from periodic collection
    pub fn unregisterMeter(self: *BasicPeriodicProcessor, meter: *BasicMeter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return;

        for (self.registered_meters.items, 0..) |registered_meter, i| {
            if (registered_meter == meter) {
                _ = self.registered_meters.swapRemove(i);
                break;
            }
        }
    }

    /// Set the exporter for this processor
    pub fn setExporter(self: *BasicPeriodicProcessor, exporter: ?MetricExporter) !void {
        if (self.exporter) |old_exporter| {
            old_exporter.deinit();
            old_exporter.destroy();
        }
        self.exporter = exporter;
    }

    /// Get the processor as a MetricProcessor union
    pub fn metricProcessor(self: *BasicPeriodicProcessor) MetricProcessor {
        return MetricProcessor{
            .bridge = @import("processor.zig").BridgeMetricProcessor.init(self),
        };
    }

    /// Background thread function that periodically collects metrics
    fn collectionThreadFn(self: *BasicPeriodicProcessor) void {
        while (true) {
            self.mutex.lock();

            // Check if we should shutdown
            if (self.is_shutdown) {
                self.is_running = false;
                self.mutex.unlock();
                break;
            }

            // Calculate wait time in nanoseconds
            const wait_ns = @as(u64, self.collection_interval_ms) * std.time.ns_per_ms;

            // Wait for the specified interval or until signaled to shutdown
            self.condition.timedWait(&self.mutex, wait_ns) catch {
                // On timeout or error, continue with collection
                self.mutex.unlock();
                self.collect();
                continue;
            };

            // We were signaled, likely for shutdown - check if we should exit
            if (self.is_shutdown) {
                self.is_running = false;
                self.mutex.unlock();
                break;
            }

            // Otherwise continue with collection
            self.mutex.unlock();
            self.collect();
        }
    }
};
