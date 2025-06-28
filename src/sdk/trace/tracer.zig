//! OpenTelemetry SDK Standard Tracer Implementation
//!
//! This module provides the concrete implementation of the Tracer interface
//! for the SDK. StandardTracer creates spans and manages their lifecycle.

const std = @import("std");
const otel_api = @import("otel-api");

const Span = otel_api.trace.Span;
const SpanContext = otel_api.trace.SpanContext;
const SpanKind = otel_api.trace.SpanKind;
const SpanStartOptions = otel_api.trace.SpanStartOptions;
const Link = otel_api.trace.Link;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const Context = otel_api.Context;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const SampleParams = otel_api.trace.SampleParams;
const SamplingDecision = otel_api.trace.SamplingDecision;
const TraceId = otel_api.common.TraceId;
const SpanId = otel_api.common.SpanId;

const RecordingSpan = @import("data.zig").RecordingSpan;
const IdGenerator = @import("id_generator.zig").IdGenerator;
const getTimestamp = @import("../common/clock.zig").getTimestamp;
const trace_context = otel_api.trace.trace_context;
const SpanProcessor = @import("processor.zig").SpanProcessor;
const SpanLimits = otel_api.trace.SpanLimits;

/// Forward declaration of BasicTracerProvider
const BasicTracerProvider = @import("basic_provider.zig").BasicTracerProvider;

/// Standard implementation of the Tracer interface
pub const StandardTracer = struct {
    /// Allocator for span creation
    allocator: std.mem.Allocator,
    scope: InstrumentationScope,
    provider: *BasicTracerProvider, // Is this necessary?

    /// Create a new standard tracer
    pub fn init(
        allocator: std.mem.Allocator,
        instrumentation_scope: InstrumentationScope,
        provider: *BasicTracerProvider,
    ) StandardTracer {
        return .{
            .allocator = allocator,
            .scope = instrumentation_scope,
            .provider = provider,
        };
    }

    /// Create a Tracer interface for this standard tracer
    pub fn tracer(self: *StandardTracer) otel_api.trace.Tracer {
        return otel_api.trace.Tracer{
            .bridge = otel_api.trace.TracerBridge.init(self),
        };
    }

    // Tracer interface implementation

    pub fn startSpan(
        self: *StandardTracer,
        name: []const u8,
        options: ?SpanStartOptions,
        ctx: Context,
    ) !otel_api.trace.Span {
        // Get options or use defaults
        const opts = options orelse SpanStartOptions.default;

        // Get timestamp
        const start_time = opts.start_time_ns orelse getTimestamp();

        // Extract parent context if present
        const parent_span_context = trace_context.getSpanContext(ctx);

        // Generate IDs
        var trace_id: TraceId = undefined;
        var span_id: SpanId = undefined;

        if (parent_span_context) |parent| {
            // Use parent's trace ID
            trace_id = parent.trace_id;
            span_id = SpanId.fromBytes(self.provider.id_generator.generateSpanId());
        } else {
            // Generate new trace ID
            trace_id = TraceId.fromBytes(self.provider.id_generator.generateTraceId());
            span_id = SpanId.fromBytes(self.provider.id_generator.generateSpanId());
        }

        // Extract links from options
        const links = opts.links orelse &.{};

        // Extract attributes from options
        const attributes = opts.attributes orelse &.{};

        // Create sample parameters for sampling decision
        const sample_params = SampleParams{
            .context = ctx,
            .trace_id = trace_id,
            .span_name = name,
            .span_kind = opts.kind,
            .attributes = attributes,
            .links = links,
        };

        // Get sampling decision
        const sampling_result = self.provider.sampler.shouldSample(sample_params);

        // Determine trace flags based on sampling decision
        const trace_flags: u8 = switch (sampling_result.decision) {
            .drop => 0,
            .record_only => 0,
            .record_and_sample => SpanContext.SAMPLED_FLAG,
        };

        // Create span context
        const span_context = SpanContext{
            .trace_id = trace_id,
            .span_id = span_id,
            .trace_flags = trace_flags,
            .trace_state = sampling_result.trace_state,
            .is_remote = false,
        };

        // Handle sampling decision
        switch (sampling_result.decision) {
            .drop => {
                // Return noop span for dropped spans
                return Span{ .noop = span_context };
            },
            .record_only, .record_and_sample => {
                // Create recording span for sampled or record-only spans
                const recording = try RecordingSpan.init(
                    self.allocator,
                    name,
                    span_context,
                    parent_span_context,
                    opts.kind,
                    start_time,
                    attributes,
                    links,
                    self.provider.span_limits,
                    self.provider,
                    spanProcessorOnEnd,
                );

                return recording.span();
            },
        }
    }

    pub fn getInstrumentationScope(self: *StandardTracer) InstrumentationScope {
        return self.scope;
    }

    pub fn deinit(self: *StandardTracer) void {
        _ = self;
    }

    /// Callback for span processor notification
    fn spanProcessorOnEnd(processor: *anyopaque, span: *RecordingSpan) void {
        const provider = @as(*BasicTracerProvider, @ptrCast(@alignCast(processor)));
        for (provider.processors.items) |*proc| {
            proc.onEnd(span);
        }
    }
};
