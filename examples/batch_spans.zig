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

    // Set up trace provider using the new setupGlobalProvider pattern with batch processor
    const concrete_provider = try otel_sdk.trace.setupGlobalProvider(
        allocator,
        .{otel_sdk.trace.BatchSpanProcessor.PipelineStep.init(.{
            .export_interval_ms = 2000,
            .max_queue_size = 100,
        }).flowTo(otel_exporters.console.ConsoleTraceExporter.PipelineStep.init(.{}))},
    );
    defer {
        concrete_provider.deinit();
        concrete_provider.destroy();
    }

    // Get the global tracer provider interface
    var tp = otel_api.getGlobalTracerProvider();

    // Get a tracer
    const scope = try otel_api.InstrumentationScope.initSimple("batch-example", "1.0.0");
    var tracer = try tp.getTracerWithScope(scope);

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

    std.debug.print("Final cleanup will be handled by destroyProvider()...\n", .{});

    std.debug.print("=== Batch Span Processor Example Complete ===\n", .{});
}
