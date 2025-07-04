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

// Observable instrument exports
const observable_instrument_zig = @import("observable_instrument.zig");
pub const ObservableCounter = observable_instrument_zig.ObservableCounter;
pub const ObservableGauge = observable_instrument_zig.ObservableGauge;
pub const ObservableUpDownCounter = observable_instrument_zig.ObservableUpDownCounter;
pub const ObservableResult = observable_instrument_zig.ObservableResult;
pub const ObservableCallback = observable_instrument_zig.ObservableCallback;
pub const ObservableCallbackNoState = observable_instrument_zig.ObservableCallbackNoState;
pub const CallbackHandle = observable_instrument_zig.CallbackHandle;
pub const TypeErasedCallback = observable_instrument_zig.TypeErasedCallback;
pub const AsyncInstrumentBridge = observable_instrument_zig.AsyncInstrumentBridge;
pub const createTypeErasedCallback = observable_instrument_zig.createTypeErasedCallback;
pub const createTypeErasedCallbackNoState = observable_instrument_zig.createTypeErasedCallbackNoState;

// Validation functions for SDK use
pub const validateInstrumentName = meter_zig.validateInstrumentName;
pub const validateInstrumentDescription = meter_zig.validateInstrumentDescription;
pub const validateInstrumentUnit = meter_zig.validateInstrumentUnit;
pub const validateCounterValue = meter_zig.validateCounterValue;
pub const validateHistogramValue = meter_zig.validateHistogramValue;

test {
    std.testing.refAllDecls(@This());
}
