//! OpenTelemetry Metrics SDK
//!
//! This module provides the SDK implementation for OpenTelemetry metrics.
//! It includes concrete implementations of meters, instruments, and providers
//! that can be used to collect and export metrics.
//!
//!
const std = @import("std");

// MeterProvider exports
pub const BasicMeterProvider = @import("basic_provider.zig").BasicMeterProvider;

// Processor and exporter types
pub const processor = @import("processor.zig");
pub const MetricProcessor = processor.MetricProcessor;
pub const BasicMetricProcessor = @import("basic_processor.zig").BasicMetricProcessor;
pub const BridgeMetricProcessor = processor.BridgeMetricProcessor;

const basic_periodic_processor_zig = @import("basic_periodic_processor.zig");
pub const BasicPeriodicProcessor = basic_periodic_processor_zig.BasicPeriodicProcessor;

const data_zig = @import("data.zig");
pub const MetricData = data_zig.MetricData;
pub const MetricDataPoint = data_zig.MetricDataPoint;
pub const MetricType = data_zig.MetricType;
pub const MetricValue = data_zig.MetricValue;
pub const I64HistogramData = data_zig.I64HistogramData;
pub const F64HistogramData = data_zig.F64HistogramData;

const exporter_zig = @import("exporter.zig");
pub const MetricExporter = exporter_zig.MetricExporter;
pub const BridgeMetricExporter = exporter_zig.BridgeMetricExporter;

// Re-export the setup helper functions
pub const setupGlobalProvider = @import("setup.zig").setupGlobalProvider;

test {
    std.testing.refAllDecls(@This());
}
