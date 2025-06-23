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
const BasicMeter = @import("basic_provider.zig").BasicMeter;

/// Metric processor interface
pub const MetricProcessor = union(enum) {
    noop: void,
    bridge: BridgeMetricProcessor,

    pub fn collect(self: *MetricProcessor) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.collectFn(processor.processor_ptr),
        }
    }

    pub fn registerMeter(self: *MetricProcessor, meter: *BasicMeter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.registerMeterFn(processor.processor_ptr, meter),
        }
    }

    pub fn unregisterMeter(self: *MetricProcessor, meter: *BasicMeter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.unregisterMeterFn(processor.processor_ptr, meter),
        }
    }

    pub fn forceFlush(self: *MetricProcessor, timeout_ms: ?u64) ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |processor| processor.forceFlushFn(processor.processor_ptr, timeout_ms),
        };
    }

    pub fn shutdown(self: *MetricProcessor, timeout_ms: ?u64) ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |processor| processor.shutdownFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Clean up processor resources
    pub fn deinit(self: *const MetricProcessor) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.deinitFn(processor.processor_ptr),
        }
    }

    /// Destroy processor memory
    pub fn destroy(self: *const MetricProcessor) void {
        switch (self.*) {
            .noop => {},
            .bridge => |processor| processor.destroyFn(processor.processor_ptr),
        }
    }
};

/// Interface for bridging to a more complex processor.
pub const BridgeMetricProcessor = struct {
    processor_ptr: *anyopaque,
    collectFn: *const fn (processor_ptr: *anyopaque) void,
    forceFlushFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    shutdownFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    deinitFn: *const fn (processor_ptr: *anyopaque) void,
    destroyFn: *const fn (processor_ptr: *anyopaque) void,
    registerMeterFn: *const fn (processor_ptr: *anyopaque, meter: *BasicMeter) void,
    unregisterMeterFn: *const fn (processor_ptr: *anyopaque, meter: *BasicMeter) void,

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
            pub fn destroy(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.destroy(self);
            }
            pub fn registerMeter(pointer: *anyopaque, meter: *BasicMeter) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.registerMeter(self, meter);
            }
            pub fn unregisterMeter(pointer: *anyopaque, meter: *BasicMeter) void {
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
            .destroyFn = VTable.destroy,
            .registerMeterFn = VTable.registerMeter,
            .unregisterMeterFn = VTable.unregisterMeter,
        };
    }
};
