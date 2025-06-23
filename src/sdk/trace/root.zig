//! OpenTelemetry SDK Trace
//!
//! This module provides concrete implementations of the OpenTelemetry Trace API.
//! The SDK includes span processors, exporters, and configurable tracing pipelines.
//!
//! ## Components
//! - `RecordingSpan` - Concrete span implementation with full functionality
//! - `StandardTracer` - Concrete tracer that creates spans
//! - `StandardTracerProvider` - Provider with configuration and span processors
//! - `SpanProcessor` - Interface for processing spans
//! - `SimpleSpanProcessor` - Immediately exports each span
//! - `SpanExporter` - Interface for exporting spans
//!
//! ## Usage
//! ```zig
//! const otel_sdk = @import("otel-sdk");
//!
//! // Create a tracing pipeline
//! const exporter = otel_sdk.exporters.console.createTraceExporter(allocator);
//! const processor = try otel_sdk.trace.createSimpleSpanProcessor(allocator, exporter.spanExporter(), resource);
//!
//! const provider = try otel_sdk.trace.createTracerProvider(allocator, resource, processor.spanProcessor());
//! ```

const std = @import("std");
const otel_api = @import("otel-api");

// Core types
pub const RecordingSpan = @import("data.zig").RecordingSpan;
pub const StandardTracer = @import("tracer.zig").StandardTracer;
pub const StandardTracerProvider = @import("tracer_provider.zig").StandardTracerProvider;

// Processor types
pub const SpanProcessor = @import("processor.zig").SpanProcessor;
pub const SimpleSpanProcessor = @import("processor.zig").SimpleSpanProcessor;
pub const BatchSpanProcessor = @import("batch_span_processor.zig").BatchSpanProcessor;
pub const BridgeSpanProcessor = @import("processor.zig").BridgeSpanProcessor;

// Exporter types
pub const SpanExporter = @import("exporter.zig").SpanExporter;
pub const createSpanExporter = @import("exporter.zig").createSpanExporter;

// Samplers
pub const samplers = @import("samplers/root.zig");

// ID generation
pub const IdGenerator = @import("id_generator.zig").IdGenerator;
pub const RandomIdGenerator = @import("id_generator.zig").RandomIdGenerator;
pub const createDefaultIdGenerator = @import("id_generator.zig").createDefaultIdGenerator;
pub const generateTraceId = @import("id_generator.zig").generateTraceId;
pub const generateSpanId = @import("id_generator.zig").generateSpanId;

// Resource type
const Resource = @import("../resource/resource.zig").Resource;

// Re-export the setup helper functions
pub const buildProvider = @import("setup.zig").buildProvider;
pub const destroyProvider = @import("setup.zig").destroyProvider;

/// Create a tracer provider with the given configuration
pub fn createTracerProvider(
    allocator: std.mem.Allocator,
    resource: Resource,
    processor: SpanProcessor,
    sampler: otel_api.trace.Sampler,
) !*StandardTracerProvider {
    return StandardTracerProvider.init(
        allocator,
        resource,
        createDefaultIdGenerator(),
        sampler,
        processor,
        otel_api.trace.SpanLimits.default,
    );
}

/// Create a simple span processor that exports spans immediately
pub fn createSimpleSpanProcessor(
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    resource: Resource,
) !*SimpleSpanProcessor {
    return SimpleSpanProcessor.init(allocator, exporter, resource);
}

/// Create a batch span processor that exports spans at regular intervals
pub fn createBatchSpanProcessor(
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    resource: Resource,
    export_interval_ms: ?u32,
    max_queue_size: ?usize,
) !*BatchSpanProcessor {
    const processor = try BatchSpanProcessor.init(
        allocator,
        exporter,
        resource,
        export_interval_ms,
        max_queue_size,
    );
    try processor.start();
    return processor;
}

/// Helper function to create a simple synchronous tracing setup
pub fn createSimpleSyncTracing(
    allocator: std.mem.Allocator,
    service_name: []const u8,
    exporter: SpanExporter,
) !otel_api.trace.TracerProvider {
    // Create resource with service name
    const attributes = try allocator.alloc(otel_api.common.AttributeKeyValue, 1);
    attributes[0] = .{
        .key = "service.name",
        .value = otel_api.common.AttributeValue.string(service_name),
    };

    const resource = Resource{
        .attributes = attributes,
        .schema_url = null,
    };

    // Create processor
    const processor = try createSimpleSpanProcessor(allocator, exporter, resource);

    // Create provider with default sampler
    const provider = try createTracerProvider(allocator, resource, processor.spanProcessor(), samplers.always_on);

    return provider.tracerProvider();
}

test "trace sdk module compilation" {
    const testing = std.testing;
    _ = testing;

    // Test that all types are properly imported
    _ = RecordingSpan;
    _ = StandardTracer;
    _ = StandardTracerProvider;
    _ = SpanProcessor;
    _ = SimpleSpanProcessor;
    _ = BridgeSpanProcessor;
    _ = SpanExporter;
}

test {
    _ = @import("test_phase6_sdk.zig");
}
