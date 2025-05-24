//! OpenTelemetry Metrics API
//!
//! This module provides the public API for OpenTelemetry metrics.
//! It includes the MeterProvider for creating Meters, and Meters for creating
//! metric instruments like Counters, UpDownCounters, and Gauges.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/api.md

const std = @import("std");

// MeterProvider exports
pub const MeterProvider = @import("meter_provider.zig").MeterProvider;
pub const NoopMeterProvider = @import("meter_provider.zig").NoopMeterProvider;
pub const createNoopProvider = @import("meter_provider.zig").createNoopProvider;
pub const SdkProviderVTable = @import("meter_provider.zig").SdkProviderVTable;
pub const SdkProviderBridge = @import("meter_provider.zig").SdkProviderBridge;

// Meter exports
pub const Meter = @import("meter.zig").Meter;
pub const NoopMeter = @import("meter.zig").NoopMeter;
pub const createNoopMeter = @import("meter.zig").createNoopMeter;
pub const SdkMeterVTable = @import("meter.zig").SdkMeterVTable;
pub const SdkMeterBridge = @import("meter.zig").SdkMeterBridge;

// Instrument exports
pub const Counter = @import("instrument.zig").Counter;
pub const UpDownCounter = @import("instrument.zig").UpDownCounter;
pub const Gauge = @import("instrument.zig").Gauge;
pub const createNoopCounter = @import("instrument.zig").createNoopCounter;
pub const createNoopUpDownCounter = @import("instrument.zig").createNoopUpDownCounter;
pub const createNoopGauge = @import("instrument.zig").createNoopGauge;
pub const SdkInstrumentVTable = @import("instrument.zig").SdkInstrumentVTable;
pub const SdkInstrumentBridge = @import("instrument.zig").SdkInstrumentBridge;

test {
    @import("std").testing.refAllDecls(@This());
}