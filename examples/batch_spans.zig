//! Example: Batch Span Processor
//!
//! This example demonstrates using the BatchSpanProcessor to batch spans
//! and export them at regular intervals, rather than exporting immediately
//! on span end like SimpleSpanProcessor.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Batch Span Processor Example ===\n", .{});

    // Create resource with service information
    const resource = try otel_sdk.resource.ResourceBuilder.init(allocator)
        .withDefaults()
        .addKeyValue(.{
            .key = "service.name",
            .value = .{ .string = "batch-example" },
        })
        .addKeyValue(.{
            .key = "service.version",
            .value = .{ .string = "1.0.0" },
        })
        .addSchemaUrl("https://opentelemetry.io/schemas/1.24.0")
        .finish(allocator);
    errdefer resource.deinitOwned(allocator);

    // Create console exporter
    var console_exporter = otel_exporters.console.createTraceExporter(allocator);
    defer console_exporter.deinit();
    const exporter = console_exporter.spanExporter();

    // Create batch processor with short interval for demo
    const batch_processor = try otel_sdk.trace.BatchSpanProcessor.init(
        allocator,
        exporter,
        resource,
        2000, // Export every 2 seconds
        100, // Queue up to 100 spans
    );

    // Start the background export thread
    try batch_processor.start();

    // Create processor bridge for use with SDK
    const processor_bridge = otel_sdk.trace.BridgeSpanProcessor.init(batch_processor);
    const processor = otel_sdk.trace.SpanProcessor{ .bridge = processor_bridge };

    // Create tracer provider with batch processor
    const id_generator = otel_sdk.trace.createDefaultIdGenerator();
    const sampler = otel_api.trace.Sampler{ .keep = {} }; // Sample all spans

    const tracer_provider = try otel_sdk.trace.StandardTracerProvider.init(
        allocator,
        resource,
        id_generator,
        sampler,
        processor,
        null, // Use default span limits
    );
    defer tracer_provider.deinit();

    // Get the tracer provider interface
    var tp = tracer_provider.tracerProvider();

    // Get a tracer
    var tracer = try tp.getTracerWithScope(.{
        .name = "batch-example",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &.{},
    });

    // Create a root context
    const ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    std.debug.print("Creating spans rapidly - they will be batched...\n", .{});

    // Create multiple spans rapidly to demonstrate batching
    for (0..8) |i| {
        const span_name = try std.fmt.allocPrint(allocator, "batch-span-{d}", .{i});
        defer allocator.free(span_name);

        // Define attributes before using them
        const span_attrs = [_]otel_api.common.AttributeKeyValue{
            .{
                .key = "span.number",
                .value = otel_api.common.AttributeValue{ .int = @intCast(i) },
            },
            .{
                .key = "span.type",
                .value = otel_api.common.AttributeValue{ .string = "batch-demo" },
            },
        };

        const span_result = try tracer.startSpan(span_name, .{
            .attributes = &span_attrs,
        }, ctx);
        var span = span_result;

        // Add an event
        const event_name = try std.fmt.allocPrint(allocator, "Event {d}", .{i});
        defer allocator.free(event_name);

        try span.addEvent(otel_api.trace.Event{ .name = event_name, .timestamp_ns = 0, .attributes = null });

        // End span immediately - it will be queued for batching
        span.end(.{});
        span.deinit();

        std.debug.print("Created and ended span {d}\n", .{i});

        // Small delay to show they're created faster than export interval
        std.time.sleep(100 * std.time.ns_per_ms); // 100ms
    }

    std.debug.print("All spans created. Waiting for batch export...\n", .{});

    // Wait for batch export to happen
    std.time.sleep(3 * std.time.ns_per_s); // 3 seconds

    std.debug.print("Creating a few more spans...\n", .{});

    // Create a few more spans to show multiple batches
    for (8..12) |i| {
        const span_name = try std.fmt.allocPrint(allocator, "batch-span-{d}", .{i});
        defer allocator.free(span_name);

        const span_attrs2 = [_]otel_api.common.AttributeKeyValue{
            .{
                .key = "span.number",
                .value = otel_api.common.AttributeValue{ .int = @intCast(i) },
            },
            .{
                .key = "span.type",
                .value = otel_api.common.AttributeValue{ .string = "batch-demo-2" },
            },
        };

        const span_result = try tracer.startSpan(span_name, .{
            .attributes = &span_attrs2,
        }, ctx);
        var span = span_result;

        span.end(.{});
        span.deinit();

        std.debug.print("Created and ended span {d}\n", .{i});
    }

    std.debug.print("Forcing flush to export remaining spans...\n", .{});

    // Force flush to export any remaining spans
    const flush_result = batch_processor.forceFlush(5000); // 5 second timeout
    if (flush_result == .success) {
        std.debug.print("Force flush completed successfully\n", .{});
    } else {
        std.debug.print("Force flush failed\n", .{});
    }

    std.debug.print("Shutting down...\n", .{});

    // Shutdown will export any remaining spans
    const shutdown_result = batch_processor.shutdown(5000);
    if (shutdown_result == .success) {
        std.debug.print("Shutdown completed successfully\n", .{});
    } else {
        std.debug.print("Shutdown failed\n", .{});
    }

    std.debug.print("=== Batch Span Processor Example Complete ===\n", .{});
}
