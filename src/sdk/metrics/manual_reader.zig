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
        self.* = init(allocator, null);
    }

    allocator: std.mem.Allocator,
    exporter: ?sdk.MetricExporter,
    mutex: std.Thread.Mutex,
    is_shutdown: bool,
    registered_meters: std.ArrayListUnmanaged(*sdk.Meter),

    pub fn init(allocator: std.mem.Allocator, exporter: ?sdk.MetricExporter) ManualReader {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .is_shutdown = false,
            .registered_meters = .{},
        };
    }

    pub fn deinit(self: *ManualReader) void {
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

    pub fn collect(self: *ManualReader) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Initialize collection data structure
        var collected_metrics = std.ArrayList(sdk.MetricData).init(arena_allocator);

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
