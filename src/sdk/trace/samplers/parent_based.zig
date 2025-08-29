//! ParentBasedSampler - Follows parent span sampling decisions
//!
//! This sampler implements the OpenTelemetry ParentBased sampling strategy:
//! - If parent span exists and is sampled -> sample child span
//! - If parent span exists and is not sampled -> don't sample child span
//! - If no parent span (root span) -> delegate to root sampler

const std = @import("std");
const otel_api = @import("otel-api");
const SampleParams = otel_api.trace.Sampler.Params;
const SamplingResult = otel_api.trace.Sampler.Result;
const SamplingDecision = otel_api.trace.Sampler.Decision;
const Sampler = otel_api.trace.Sampler;
const TraceId = otel_api.common.TraceId;
const SpanId = otel_api.common.SpanId;
const trace_context = otel_api.trace.trace_context;

/// Sampler that follows parent span sampling decisions with root sampler fallback
pub const ParentBasedSampler = struct {
    /// Sampler to use for root spans (when no parent exists)
    root_sampler: Sampler,

    /// Create a new ParentBasedSampler
    pub fn init(root_sampler: Sampler) ParentBasedSampler {
        return ParentBasedSampler{
            .root_sampler = root_sampler,
        };
    }

    /// Make sampling decision based on parent span context
    pub fn shouldSample(self: *const ParentBasedSampler, params: SampleParams) SamplingResult {
        // Extract parent span context from incoming context
        const parent_span_context = trace_context.getSpanContext(params.context);

        if (parent_span_context) |parent| {
            // Parent exists - follow parent's sampling decision
            if (parent.trace_flags & otel_api.trace.Span.Context.SAMPLED_FLAG != 0) {
                // Parent was sampled -> sample child
                var result = Sampler.Result{ .decision = .record_and_sample };
                // Preserve parent's trace state if it exists
                result.trace_state = parent.trace_state;
                return result;
            } else {
                // Parent was not sampled -> don't sample child
                var result = Sampler.Result{ .decision = .drop };
                // Preserve parent's trace state if it exists
                result.trace_state = parent.trace_state;
                return result;
            }
        } else {
            // No parent (root span) -> delegate to root sampler
            return self.root_sampler.shouldSample(params);
        }
    }

    /// Get description of this sampler
    pub fn getDescription(self: *const ParentBasedSampler) []const u8 {
        _ = self;
        return "ParentBasedSampler";
    }
};

// Tests
const testing = std.testing;

test "ParentBasedSampler - no parent delegates to root sampler" {
    // Test with root sampler that always samples
    const root_sampler = Sampler{ .keep = {} };
    const sampler = ParentBasedSampler.init(root_sampler);

    const params = SampleParams{
        .allocator = testing.allocator,
        .context = &.{}, // Empty context (no parent)
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "root-span",
        .span_kind = .server,
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .record_and_sample);
}

test "ParentBasedSampler - sampled parent produces sampled child" {
    const root_sampler = Sampler{ .drop = {} }; // Root would drop, but parent overrides
    const sampler = ParentBasedSampler.init(root_sampler);

    // Create context with sampled parent span context
    const ctx = try otel_api.ContextKeyValue.initOwnedSlice(testing.allocator, &.{});
    defer otel_api.ContextKeyValue.deinitOwnedSlice(testing.allocator, ctx);

    const parent_span_context = otel_api.trace.Span.Context{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = otel_api.trace.Span.Context.SAMPLED_FLAG, // Parent is sampled
        .trace_state = "parent=sampled",
        .is_remote = false,
    };

    const ctx_with_parent = try trace_context.withActiveSpanContext(testing.allocator, ctx, parent_span_context);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(testing.allocator, ctx_with_parent);

    const params = SampleParams{
        .allocator = testing.allocator,
        .context = ctx_with_parent,
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16), // Same trace as parent
        .span_name = "child-span",
        .span_kind = .internal,
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .record_and_sample);
    try testing.expect(result.trace_state != null);
    try testing.expectEqualStrings("parent=sampled", result.trace_state.?);
}

test "ParentBasedSampler - unsampled parent produces unsampled child" {
    const root_sampler = Sampler{ .keep = {} }; // Root would sample, but parent overrides
    const sampler = ParentBasedSampler.init(root_sampler);

    // Create context with unsampled parent span context
    const ctx = try otel_api.ContextKeyValue.initOwnedSlice(testing.allocator, &.{});
    defer otel_api.ContextKeyValue.deinitOwnedSlice(testing.allocator, &.{});

    const parent_span_context = otel_api.trace.Span.Context{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = 0, // Parent is NOT sampled
        .trace_state = "parent=not_sampled",
        .is_remote = true,
    };

    const ctx_with_parent = try trace_context.withActiveSpanContext(testing.allocator, ctx, parent_span_context);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(testing.allocator, ctx_with_parent);

    const params = SampleParams{
        .allocator = testing.allocator,
        .context = ctx_with_parent,
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16), // Same trace as parent
        .span_name = "child-span",
        .span_kind = .client,
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .drop);
    try testing.expect(result.trace_state != null);
    try testing.expectEqualStrings("parent=not_sampled", result.trace_state.?);
}

test "ParentBasedSampler - description" {
    const root_sampler = Sampler{ .drop = {} };
    const sampler = ParentBasedSampler.init(root_sampler);
    const description = sampler.getDescription();
    try testing.expectEqualStrings("ParentBasedSampler", description);
}
