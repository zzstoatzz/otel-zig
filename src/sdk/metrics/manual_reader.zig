//! OpenTelemetry Basic Metric Processor
//!
//! This module provides the BasicMetricProcessor that exports metrics immediately
//! when collected. It's the simplest metric processor implementation.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md#metricreader

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const BridgeMetricReader = @import("reader.zig").BridgeReader;
    const Meter = @import("meter.zig").Meter;
    const MetricExporter = @import("exporter.zig").MetricExporter;
    const Reader = @import("reader.zig").Reader;
    const MetricData = @import("data.zig").MetricData;
    const ReaderAggregationState = @import("reader_aggregation_state.zig").ReaderAggregationState;
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const MetricValue = @import("reader.zig").MetricValue;
};

/// Basic log processor implementation.
///
/// Simple processor that exports metrics manually. Users must invoke `forceFlush`.
pub const ManualReader = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        ManualReader,
        sdk.Reader,
        void,
        reader,
        _initFn,
        setExporter,
    );
    pub fn _initFn(self: *ManualReader, _: void, allocator: std.mem.Allocator) !void {
        self.* = try init(allocator, null);
    }

    allocator: std.mem.Allocator,
    exporter: ?sdk.MetricExporter,
    mutex: std.Thread.Mutex,
    is_shutdown: bool,
    registered_meters: std.ArrayListUnmanaged(*sdk.Meter),
    reader_state: sdk.ReaderAggregationState,

    pub fn init(allocator: std.mem.Allocator, exporter: ?sdk.MetricExporter) !ManualReader {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .is_shutdown = false,
            .registered_meters = .{},
            .reader_state = try sdk.ReaderAggregationState.init(
                allocator,
                .Delta, // Default to Delta temporality for now
                @import("reader_aggregation_state.zig").defaultAggregationSelector,
            ),
        };
    }

    pub fn deinit(self: *ManualReader) void {
        self.reader_state.deinit();
        self.registered_meters.deinit(self.allocator);
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    pub fn destroy(self: *ManualReader) void {
        self.allocator.destroy(self);
    }

    pub fn setExporter(self: *ManualReader, exporter: ?sdk.MetricExporter) !void {
        if (self.exporter) |old_exporter| {
            old_exporter.deinit();
            old_exporter.destroy();
        }
        self.exporter = exporter;
    }

    pub fn recordMeasurement(
        self: *ManualReader,
        value: sdk.MetricValue,
        attributes: []const api.AttributeKeyValue,
        metadata: sdk.MetricMetadata,
        metadata_hash: u64,
    ) void {
        self.reader_state.recordMeasurement(value, attributes, metadata, metadata_hash);
    }

    pub fn collect(self: *ManualReader) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        self.mutex.lock();
        defer self.mutex.unlock();

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
        if (self.exporter) |*exporter| {
            const result = exporter.exportMetrics(collected_metrics.items);
            if (result != .success) {
                api.common.reportError(.{
                    .component = .processor,
                    .operation = "metric_export",
                    .error_type = .network,
                    .message = "Failed to export metrics",
                    .context = null,
                });
            }
        }
        // Arena cleans up all the memory.
    }

    pub fn forceFlush(self: *ManualReader, timeout_ms: ?u64) api.common.ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = if (self.exporter) |*exporter| exporter.forceFlush(timeout_ms) else .success;
        return result.asProcessResult();
    }

    pub fn shutdown(self: *ManualReader, timeout_ms: ?u64) api.common.ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;

        // Shutdown the exporter
        const result = if (self.exporter) |*exporter| exporter.shutdown(timeout_ms) else .success;
        return result.asProcessResult();
    }

    pub fn registerMeter(self: *ManualReader, meter: *sdk.Meter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return;

        self.registered_meters.append(self.allocator, meter) catch {
            // Handle allocation failure silently for now
            return;
        };
    }

    pub fn unregisterMeter(self: *ManualReader, meter: *sdk.Meter) void {
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

    pub fn reader(self: *ManualReader) sdk.Reader {
        return .{ .bridge = sdk.BridgeMetricReader.init(self) };
    }
};
