//! OpenTelemetry Metrics SDK
//!
//! This module provides the SDK implementation for OpenTelemetry metrics.
//! It includes concrete implementations of meters, instruments, and providers
//! that can be used to collect and export metrics.
//!
//!
const std = @import("std");

// MeterProvider exports
pub const StandardMeterProvider = @import("meter_provider.zig").StandardMeterProvider;

// Meter exports
pub const StandardMeter = @import("meter.zig").StandardMeter;

// Instrument exports
pub const StandardCounter = @import("instruments.zig").StandardCounter;
pub const StandardUpDownCounter = @import("instruments.zig").StandardUpDownCounter;
pub const StandardGauge = @import("instruments.zig").StandardGauge;

// Aggregation exports (for advanced use)
pub const SumAggregation = @import("instruments.zig").SumAggregation;
pub const LastValueAggregation = @import("instruments.zig").LastValueAggregation;

// Processor and exporter types
pub const processor = @import("processor.zig");
pub const MetricProcessor = processor.MetricProcessor;
pub const SimpleMetricProcessor = processor.SimpleMetricProcessor;
pub const BridgeMetricProcessor = processor.BridgeMetricProcessor;

const data_zig = @import("data.zig");
pub const MetricData = data_zig.MetricData;
pub const MetricDataPoint = data_zig.MetricDataPoint;
pub const MetricType = data_zig.MetricType;
pub const MetricValue = data_zig.MetricValue;

const exporter_zig = @import("exporter.zig");
pub const MetricExporter = exporter_zig.MetricExporter;
pub const BridgeMetricExporter = exporter_zig.BridgeMetricExporter;

// Re-export the setup helper functions
pub const createSimpleSyncMetrics = @import("setup.zig").createSimpleSyncMetrics;

test {
    std.testing.refAllDecls(@This());
}
