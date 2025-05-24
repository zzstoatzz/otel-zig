//! OpenTelemetry Metrics SDK
//!
//! This module provides the SDK implementation for OpenTelemetry metrics.
//! It includes concrete implementations of meters, instruments, and providers
//! that can be used to collect and export metrics.
//!
//! ## Components
//! - `MeterProvider` - Creates and manages meters
//! - `Meter` - Creates metric instruments
//! - `Counter` - Monotonic sum instrument
//! - `UpDownCounter` - Non-monotonic sum instrument
//! - `Gauge` - Last value instrument
//!
//! ## Usage
//! ```zig
//! const otel_sdk = @import("otel-sdk");
//! const metrics = otel_sdk.metrics;
//!
//! // Create a meter provider
//! var provider = try metrics.createProvider(allocator);
//! defer provider.deinit();
//!
//! // Get a meter
//! const meter = try provider.getMeterWithName("my.service");
//!
//! // Create instruments
//! const counter = try meter.createCounterI64("requests.total", "Total requests", "1");
//! counter.add(ctx, 1, &attributes);
//! ```
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md

const std = @import("std");

// MeterProvider exports
pub const MeterProvider = @import("meter_provider.zig").MeterProvider;
pub const StandardMeterProvider = @import("meter_provider.zig").StandardMeterProvider;
pub const createProvider = @import("meter_provider.zig").createProvider;
pub const createProviderWithResource = @import("meter_provider.zig").createProviderWithResource;

// Meter exports
pub const StandardMeter = @import("meter.zig").StandardMeter;
pub const createStandardMeter = @import("meter.zig").createStandardMeter;

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
pub const PeriodicMetricProcessor = processor.PeriodicMetricProcessor;
pub const MetricExporter = processor.MetricExporter;
pub const MetricData = processor.MetricData;
pub const MetricDataPoint = processor.MetricDataPoint;
pub const MetricType = processor.MetricType;
pub const MetricValue = processor.MetricValue;
pub const createSimpleProcessor = processor.createSimpleProcessor;
pub const createPeriodicProcessor = processor.createPeriodicProcessor;

test {
    @import("std").testing.refAllDecls(@This());
}