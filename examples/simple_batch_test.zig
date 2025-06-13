//! Simple Batch Processor Test
//!
//! This test validates the core BatchSpanProcessor functionality
//! without complex resource management.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Simple Batch Processor Test ===\n", .{});

    const resource = try otel_sdk.resource.ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    errdefer resource.deinitOwned(allocator);

    // Create console exporter
    var console_exporter = otel_exporters.console.createTraceExporter(allocator);
    defer console_exporter.deinit();
    const exporter = console_exporter.spanExporter();

    // Create batch processor with very short interval for testing
    const batch_processor = try otel_sdk.trace.BatchSpanProcessor.init(
        allocator,
        exporter,
        resource,
        500, // Export every 500ms
        5, // Small queue for testing
    );

    // Start the processor
    try batch_processor.start();

    std.debug.print("Batch processor started with 500ms interval\n", .{});

    // Create processor bridge
    const processor_bridge = otel_sdk.trace.BridgeSpanProcessor.init(batch_processor);
    const processor = otel_sdk.trace.SpanProcessor{ .bridge = processor_bridge };

    // Create tracer provider
    const id_generator = otel_sdk.trace.createDefaultIdGenerator();
    const sampler = otel_api.trace.Sampler{ .keep = {} };

    const tracer_provider = try otel_sdk.trace.StandardTracerProvider.init(
        allocator,
        resource,
        id_generator,
        sampler,
        processor,
        null,
    );
    defer tracer_provider.deinit();

    // Get tracer
    var tp = tracer_provider.tracerProvider();
    var tracer = try tp.getTracerWithScope(.{
        .name = "simple-batch-test",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &.{},
    });

    // Create context
    const ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    std.debug.print("Creating 3 spans quickly...\n", .{});

    // Create 3 spans quickly
    for (0..3) |i| {
        const span_name = try std.fmt.allocPrint(allocator, "test-span-{d}", .{i});
        defer allocator.free(span_name);

        const span_attrs = [_]otel_api.common.AttributeKeyValue{
            .{
                .key = "test.number",
                .value = otel_api.common.AttributeValue{ .int = @intCast(i) },
            },
        };

        const span_result = try tracer.startSpan(span_name, .{
            .attributes = &span_attrs,
        }, ctx);
        var span = span_result;

        std.debug.print("Created span {d}\n", .{i});

        // End span - it will be queued for batching
        span.end(.{});
        span.deinit();
    }

    std.debug.print("All spans created. Waiting for batch export...\n", .{});

    // Wait for batch export
    std.time.sleep(1 * std.time.ns_per_s);

    std.debug.print("Creating 2 more spans...\n", .{});

    // Create 2 more spans
    for (3..5) |i| {
        const span_name = try std.fmt.allocPrint(allocator, "test-span-{d}", .{i});
        defer allocator.free(span_name);

        const span_attrs = [_]otel_api.common.AttributeKeyValue{
            .{
                .key = "test.number",
                .value = otel_api.common.AttributeValue{ .int = @intCast(i) },
            },
        };

        const span_result = try tracer.startSpan(span_name, .{
            .attributes = &span_attrs,
        }, ctx);
        var span = span_result;

        span.end(.{});
        span.deinit();
    }

    std.debug.print("Force flushing remaining spans...\n", .{});

    // Force flush
    const flush_result = tp.forceFlush(1000);
    if (flush_result == .success) {
        std.debug.print("Force flush successful\n", .{});
    } else {
        std.debug.print("Force flush failed\n", .{});
    }

    std.debug.print("Shutting down...\n", .{});

    // Shutdown
    const shutdown_result = batch_processor.shutdown(1000);
    if (shutdown_result == .success) {
        std.debug.print("Shutdown successful\n", .{});
    } else {
        std.debug.print("Shutdown failed\n", .{});
    }

    std.debug.print("=== Test Complete ===\n", .{});
}
