//! OpenTelemetry Basic Metric Processor
//!
//! This module provides the BasicMetricProcessor that exports metrics immediately
//! when collected. It's the simplest metric processor implementation.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md#metricreader

const std = @import("std");
const otel_api = @import("otel-api");

const Context = otel_api.Context;
const AttributeKeyValue = otel_api.AttributeKeyValue;
const InstrumentationScope = otel_api.InstrumentationScope;

const MetricDataPoint = @import("data.zig").MetricDataPoint;
const MetricData = @import("data.zig").MetricData;
const ProcessResult = @import("otel-api").common.ProcessResult;
const MetricExporter = @import("exporter.zig").MetricExporter;
const MetricProcessor = @import("processor.zig").MetricProcessor;
const BridgeMetricProcessor = @import("processor.zig").BridgeMetricProcessor;
const BasicMeter = @import("basic_provider.zig").BasicMeter;

/// Basic log processor implementation.
///
/// Simple processor that exports metrics manually. Users must invoke `forceFlush`.
pub const BasicMetricProcessor = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        BasicMetricProcessor,
        MetricProcessor,
        void,
        metricProcessor,
        _initFn,
        setExporter,
    );
    pub fn _initFn(_: void, allocator: std.mem.Allocator) !BasicMetricProcessor {
        return init(allocator, null);
    }

    allocator: std.mem.Allocator,
    exporter: ?MetricExporter,
    mutex: std.Thread.Mutex,
    is_shutdown: bool,
    registered_meters: std.ArrayListUnmanaged(*BasicMeter),

    pub fn init(allocator: std.mem.Allocator, exporter: ?MetricExporter) BasicMetricProcessor {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .is_shutdown = false,
            .registered_meters = .{},
        };
    }

    pub fn deinit(self: *BasicMetricProcessor) void {
        self.registered_meters.deinit(self.allocator);
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    pub fn destroy(self: *BasicMetricProcessor) void {
        self.allocator.destroy(self);
    }

    pub fn setExporter(self: *BasicMetricProcessor, exporter: ?MetricExporter) !void {
        if (self.exporter) |old_exporter| {
            old_exporter.deinit();
            old_exporter.destroy();
        }
        self.exporter = exporter;
    }

    pub fn collect(self: *BasicMetricProcessor) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        self.mutex.lock();
        defer self.mutex.unlock();

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

    pub fn forceFlush(self: *BasicMetricProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = if (self.exporter) |*exporter| exporter.forceFlush(timeout_ms) else .success;
        return if (result == .success) .success else .failure;
    }

    pub fn shutdown(self: *BasicMetricProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;

        // Shutdown the exporter
        const result = if (self.exporter) |*exporter| exporter.shutdown(timeout_ms) else .success;
        return if (result == .success) .success else .failure;
    }

    pub fn registerMeter(self: *BasicMetricProcessor, meter: *BasicMeter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return;

        self.registered_meters.append(self.allocator, meter) catch {
            // Handle allocation failure silently for now
            return;
        };
    }

    pub fn unregisterMeter(self: *BasicMetricProcessor, meter: *BasicMeter) void {
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

    pub fn metricProcessor(self: *BasicMetricProcessor) MetricProcessor {
        return MetricProcessor{ .bridge = BridgeMetricProcessor.init(self) };
    }
};
