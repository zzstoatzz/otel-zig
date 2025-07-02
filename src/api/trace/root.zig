//! OpenTelemetry Trace API
//!
//! This module provides the tracing API according to the OpenTelemetry specification.
//! The API contains only interfaces and no-op implementations, allowing libraries to
//! instrument their code without depending on a specific SDK implementation.
//!
//! ## Components
//! - `Span` - Represents a unit of work within a trace
//! - `Tracer` - Creates spans
//! - `TracerProvider` - Factory for creating tracers
//! - `SpanContext` - Immutable span identifier
//! - `SpanKind` - Type of span (client, server, etc.)
//! - `StatusCode` - Span completion status
//!
//! ## Status
//! This is a placeholder implementation. Full trace support is planned for a future release.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md

const std = @import("std");

pub const SpanContext = @import("span_context.zig").SpanContext;
pub const Event = @import("event.zig").Event;

// Context integration (Phase 2 - Implemented)
pub const context_keys = @import("context_keys.zig");
pub const W3cPropagator = @import("w3c_propagator.zig").W3cPropagator;
pub const createW3cPropagator = @import("w3c_propagator.zig").createW3cPropagator;

// Spans
const span = @import("span.zig");
pub const Span = span.Span;
pub const SpanBridge = span.SpanBridge;
pub const SpanKind = span.SpanKind;
pub const SpanStartOptions = span.SpanStartOptions;
pub const SpanEndOptions = span.SpanEndOptions;
pub const Status = span.Status;
pub const StatusCode = span.StatusCode;
pub const Link = span.Link;

pub const SpanLimits = @import("span_limits.zig").SpanLimits;
pub const sampling_config = @import("sampling_config.zig");
pub const SamplingDecision = sampling_config.SamplingDecision;
pub const SamplingResult = sampling_config.SamplingResult;
pub const SampleParams = sampling_config.SampleParams;
pub const Sampler = sampling_config.Sampler;
pub const SamplerBridge = sampling_config.SamplerBridge;

// Re-export commonly used context utilities for convenience
pub const trace_context = @import("context_utils.zig");

// Core interfaces (Phase 4 - Implemented)
pub const Tracer = @import("tracer.zig").Tracer;

pub const TracerBridge = @import("tracer.zig").TracerBridge;
pub const TracerProvider = @import("tracer_provider.zig").TracerProvider;
pub const TracerProviderBridge = @import("tracer_provider.zig").TracerProviderBridge;

// Validation functions for SDK use
pub const validateAttributeKey = span.validateAttributeKey;
pub const validateSpanName = span.validateSpanName;
pub const validateAttributeValue = @import("tracer.zig").validateAttributeValue;
pub const validateAttributes = @import("tracer.zig").validateAttributes;

// Tests
test "trace api module compilation" {
    std.testing.refAllDecls(@This());
}
