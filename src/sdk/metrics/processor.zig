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
const AttributeKeyValue = otel_api.AttributeKeyValue;
const InstrumentationScope = otel_api.InstrumentationScope;

const MetricDataPoint = @import("data.zig").MetricDataPoint;
const MetricData = @import("data.zig").MetricData;
const ProcessResult = @import("otel-api").common.ProcessResult;
const MetricExporter = @import("exporter.zig").MetricExporter;
const StandardMeter = @import("meter.zig").StandardMeter;

/// Metric processor interface
pub const MetricProcessor = union(enum) {
    noop: void,
    simple: *SimpleMetricProcessor,
    bridge: BridgeMetricProcessor,

    pub fn collect(self: *MetricProcessor) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.collect(),
            .bridge => |processor| processor.collectFn(processor.processor_ptr),
        }
    }

    pub fn registerMeter(self: *MetricProcessor, meter: *StandardMeter) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.registerMeter(meter),
            .bridge => |processor| processor.registerMeterFn(processor.processor_ptr, meter),
        }
    }

    pub fn unregisterMeter(self: *MetricProcessor, meter: *StandardMeter) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.unregisterMeter(meter),
            .bridge => |processor| processor.unregisterMeterFn(processor.processor_ptr, meter),
        }
    }

    pub fn forceFlush(self: *MetricProcessor, timeout_ms: ?u64) ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .simple => |processor| processor.forceFlush(timeout_ms),
            .bridge => |processor| processor.forceFlushFn(processor.processor_ptr, timeout_ms),
        };
    }

    pub fn shutdown(self: *MetricProcessor, timeout_ms: ?u64) void {
        return switch (self.*) {
            .noop => .success,
            .simple => |processor| processor.shutdown(timeout_ms),
            .bridge => |processor| processor.shutdownFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Clean up processor resources
    pub fn deinit(self: *MetricProcessor) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.deinit(),
            .bridge => |processor| processor.deinitFn(processor.processor_ptr),
        }
    }
};

/// Simple processor that exports metrics immediately
pub const SimpleMetricProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: MetricExporter,
    mutex: std.Thread.Mutex,
    is_shutdown: bool,
    registered_meters: std.ArrayListUnmanaged(*StandardMeter),

    pub fn init(allocator: std.mem.Allocator, exporter: MetricExporter) !*SimpleMetricProcessor {
        const self = try allocator.create(SimpleMetricProcessor);
        self.* = .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .is_shutdown = false,
            .registered_meters = .{},
        };
        return self;
    }

    pub fn deinit(self: *SimpleMetricProcessor) void {
        self.registered_meters.deinit(self.allocator);
        self.exporter.deinit();
        self.allocator.destroy(self);
    }

    pub fn collect(self: *SimpleMetricProcessor) void {
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
        _ = self.exporter.exportMetrics(collected_metrics.items);
        // Arena cleans up all the memory.
    }

    pub fn forceFlush(self: *SimpleMetricProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = self.exporter.forceFlush(timeout_ms);
        return if (result == .success) .success else .failure;
    }

    pub fn shutdown(self: *SimpleMetricProcessor, timeout_ms: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;

        // Shutdown the exporter
        const result = self.exporter.shutdown(timeout_ms);
        return if (result == .success) .success else .failure;
    }

    pub fn registerMeter(self: *SimpleMetricProcessor, meter: *StandardMeter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return;

        self.registered_meters.append(self.allocator, meter) catch {
            // Handle allocation failure silently for now
            return;
        };
    }

    pub fn unregisterMeter(self: *SimpleMetricProcessor, meter: *StandardMeter) void {
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

    pub fn metricProcessor(self: *SimpleMetricProcessor) MetricProcessor {
        return MetricProcessor{ .simple = self };
    }
};

/// Interface for bridging to a more complex processor.
pub const BridgeMetricProcessor = struct {
    processor_ptr: *anyopaque,
    collectFn: *const fn (processor_ptr: *anyopaque) void,
    forceFlushFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    shutdownFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    deinitFn: *const fn (processor_ptr: *anyopaque) void,
    registerMeterFn: *const fn (processor_ptr: *anyopaque, meter: *StandardMeter) void,
    unregisterMeterFn: *const fn (processor_ptr: *anyopaque, meter: *StandardMeter) void,

    pub fn init(ptr: anytype) BridgeMetricProcessor {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn collect(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.collect(self);
            }
            pub fn forceFlush(pointer: *anyopaque, timeout_ms: ?u64) ProcessResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.forceFlush(self, timeout_ms);
            }
            pub fn shutdown(pointer: *anyopaque, timeout_ms: ?u64) ProcessResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.shutdown(self, timeout_ms);
            }
            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.deinit(self);
            }
            pub fn registerMeter(pointer: *anyopaque, meter: *StandardMeter) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.registerMeter(self, meter);
            }
            pub fn unregisterMeter(pointer: *anyopaque, meter: *StandardMeter) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.unregisterMeter(self, meter);
            }
        };

        return .{
            .processor_ptr = ptr,
            .collectFn = VTable.collect,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
            .registerMeterFn = VTable.registerMeter,
            .unregisterMeterFn = VTable.unregisterMeter,
        };
    }
};
