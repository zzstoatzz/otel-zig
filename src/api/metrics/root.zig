//! OpenTelemetry Metrics API
//!
//! This module provides the public API for OpenTelemetry metrics.
//! It includes the MeterProvider for creating Meters, and Meters for creating
//! metric instruments like Counters, UpDownCounters, and Gauges.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/api.md

const std = @import("std");

// MeterProvider exports
const meter_provider_zig = @import("meter_provider.zig");
pub const MeterProvider = meter_provider_zig.MeterProvider;
pub const MeterProviderBridge = meter_provider_zig.MeterProviderBridge;

// Meter exports
const meter_zig = @import("meter.zig");
pub const Meter = meter_zig.Meter;
pub const MeterBridge = meter_zig.MeterBridge;

// Instrument exports
const instrument_zig = @import("instrument.zig");
pub const Counter = instrument_zig.Counter;
pub const UpDownCounter = instrument_zig.UpDownCounter;
pub const Gauge = instrument_zig.Gauge;
pub const Histogram = instrument_zig.Histogram;
pub const InstrumentBridge = instrument_zig.InstrumentBridge;

test {
    std.testing.refAllDecls(@This());
}
