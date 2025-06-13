//! TraceIdRatioBasedSampler - Samples spans based on trace ID hash ratio
//!
//! This sampler makes sampling decisions based on a configured ratio by
//! hashing the trace ID and comparing the result against the ratio threshold.

const std = @import("std");
const otel_api = @import("otel-api");

const SampleParams = otel_api.trace.SampleParams;
const SamplingResult = otel_api.trace.SamplingResult;
const SamplingDecision = otel_api.trace.SamplingDecision;
const TraceId = otel_api.common.TraceId;

/// Sampler that samples spans based on trace ID hash and a configured ratio
pub const TraceIdRatioBasedSampler = struct {
    /// Sampling ratio (0.0 to 1.0)
    ratio: f64,

    /// Threshold value for comparison (derived from ratio)
    threshold: u32,

    /// Create a new TraceIdRatioBasedSampler
    pub fn init(ratio: f64) TraceIdRatioBasedSampler {
        // Clamp ratio to valid range
        const clamped_ratio = std.math.clamp(ratio, 0.0, 1.0);

        // Convert ratio to threshold (0 to max_u32)
        const threshold = @as(u32, @intFromFloat(clamped_ratio * @as(f64, @floatFromInt(std.math.maxInt(u32)))));

        return TraceIdRatioBasedSampler{
            .ratio = clamped_ratio,
            .threshold = threshold,
        };
    }

    /// Make sampling decision based on trace ID hash
    pub fn shouldSample(self: *const TraceIdRatioBasedSampler, params: SampleParams) SamplingResult {
        // Always sample if ratio is 1.0
        if (self.ratio >= 1.0) {
            return SamplingResult.simple(.record_and_sample);
        }

        // Never sample if ratio is 0.0
        if (self.ratio <= 0.0) {
            return SamplingResult.simple(.drop);
        }

        // Hash the trace ID using CRC32
        const hash = std.hash.Crc32.hash(params.trace_id.bytes[0..]);

        // Sample if hash is below threshold
        if (hash < self.threshold) {
            return SamplingResult.simple(.record_and_sample);
        } else {
            return SamplingResult.simple(.drop);
        }
    }

    /// Get description of this sampler
    pub fn getDescription(self: *const TraceIdRatioBasedSampler) []const u8 {
        _ = self;
        return "TraceIdRatioBasedSampler";
    }
};

/// Create a new TraceIdRatioBasedSampler with the given ratio
pub fn create(ratio: f64) TraceIdRatioBasedSampler {
    return TraceIdRatioBasedSampler.init(ratio);
}

// Tests
const testing = std.testing;

test "TraceIdRatioBasedSampler - ratio 1.0 always samples" {
    const sampler = create(1.0);

    const params = SampleParams{
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

test "TraceIdRatioBasedSampler - ratio 0.0 never samples" {
    const sampler = create(0.0);

    const params = SampleParams{
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

test "TraceIdRatioBasedSampler - ratio clamping" {
    // Test ratio > 1.0 gets clamped
    const sampler1 = create(1.5);
    try testing.expect(sampler1.ratio == 1.0);

    // Test ratio < 0.0 gets clamped
    const sampler2 = create(-0.5);
    try testing.expect(sampler2.ratio == 0.0);
}

test "TraceIdRatioBasedSampler - deterministic behavior" {
    const sampler = create(0.5);

    const params = SampleParams{
        .context = otel_api.Context.init(testing.allocator),
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
        .attributes = &.{},
        .links = &.{},
    };

    // Same trace ID should always produce same result
    const result1 = sampler.shouldSample(params);
    const result2 = sampler.shouldSample(params);
    try testing.expect(result1.decision == result2.decision);
}

test "TraceIdRatioBasedSampler - different trace IDs" {
    const sampler = create(0.5);

    // Test with different trace IDs to ensure we get some variation
    var sampled_count: u32 = 0;
    var total_count: u32 = 0;

    var i: u8 = 0;
    while (i < 100) : (i += 1) {
        const trace_id = TraceId.fromBytes([_]u8{i} ** 16);
        const params = SampleParams{
            .context = otel_api.Context.init(testing.allocator),
            .trace_id = trace_id,
            .span_name = "test-span",
            .span_kind = .internal,
            .attributes = &.{},
            .links = &.{},
        };

        const result = sampler.shouldSample(params);
        if (result.decision == .record_and_sample) {
            sampled_count += 1;
        }
        total_count += 1;
    }

    // With 100 samples and 50% ratio, we should get some sampling
    // (not exactly 50 due to hash distribution, but should be > 0 and < 100)
    try testing.expect(sampled_count > 0);
    try testing.expect(sampled_count < total_count);
}

test "TraceIdRatioBasedSampler - description" {
    const sampler = create(0.5);
    const description = sampler.getDescription();
    try testing.expectEqualStrings("TraceIdRatioBasedSampler", description);
}
