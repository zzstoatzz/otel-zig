//! OpenTelemetry SDK Samplers
//!
//! This module provides concrete sampler implementations for the OpenTelemetry SDK.
//! Samplers make decisions about whether spans should be sampled, recorded, or dropped.

const std = @import("std");
const otel_api = @import("otel-api");
const TraceId = otel_api.common.TraceId;

const Sampler = otel_api.trace.Sampler;
const SamplerBridge = otel_api.trace.SamplerBridge;

// Import concrete sampler implementations
pub const TraceIdRatioBasedSampler = @import("trace_id_ratio_based.zig").TraceIdRatioBasedSampler;
pub const ParentBasedSampler = @import("parent_based.zig").ParentBasedSampler;

// Re-export create functions
pub const createTraceIdRatioBased = @import("trace_id_ratio_based.zig").create;
pub const createParentBased = @import("parent_based.zig").create;

/// Create a TraceIdRatioBasedSampler wrapped in the Sampler interface
pub fn traceIdRatioBased(ratio: f64) Sampler {
    const sampler = std.heap.page_allocator.create(TraceIdRatioBasedSampler) catch unreachable;
    sampler.* = createTraceIdRatioBased(ratio);
    return Sampler{ .bridge = SamplerBridge.init(sampler) };
}

/// Create a ParentBasedSampler wrapped in the Sampler interface
pub fn parentBased(root_sampler: Sampler) Sampler {
    const sampler = std.heap.page_allocator.create(ParentBasedSampler) catch unreachable;
    sampler.* = createParentBased(root_sampler);
    return Sampler{ .bridge = SamplerBridge.init(sampler) };
}

pub const always_on: Sampler = .{ .keep = {} };
pub const always_off: Sampler = .{ .drop = {} };

// Tests
const testing = std.testing;

test "always_on sampler creation" {
    const sampler = always_on;

    const params = otel_api.trace.SampleParams{
        .context = otel_api.Context.init(testing.allocator),
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
        .attributes = &.{},
        .links = &.{},
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .record_and_sample);
}

test "traceIdRatioBased sampler creation" {
    const sampler = traceIdRatioBased(1.0);

    const params = otel_api.trace.SampleParams{
        .context = otel_api.Context.init(testing.allocator),
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
        .attributes = &.{},
        .links = &.{},
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .record_and_sample);
}

test "always_off creation" {
    const sampler = always_off;

    const params = otel_api.trace.SampleParams{
        .context = otel_api.Context.init(testing.allocator),
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
        .attributes = &.{},
        .links = &.{},
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .drop);
}

test "parentBased sampler creation" {
    const root_sampler = always_on;
    const sampler = parentBased(root_sampler);

    const params = otel_api.trace.SampleParams{
        .context = otel_api.Context.init(testing.allocator),
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
        .attributes = &.{},
        .links = &.{},
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .record_and_sample);
}
