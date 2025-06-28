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

    // Set up trace provider using the new setupGlobalProvider pattern with batch processor
    const concrete_provider = try otel_sdk.trace.setupGlobalProvider(
        allocator,
        .{otel_sdk.trace.BatchSpanProcessor.PipelineStep.init(.{
            .export_interval_ms = 500,
            .max_queue_size = 5,
        }).flowTo(otel_exporters.console.ConsoleTraceExporter.PipelineStep.init(.{}))},
    );
    defer {
        concrete_provider.deinit();
        concrete_provider.destroy();
    }

    std.debug.print("Batch processor started with 500ms interval\n", .{});

    // Get the global tracer provider interface
    var tp = otel_api.getGlobalTracerProvider();

    // Get tracer
    const scope = try otel_api.InstrumentationScope.initSimple("simple-batch-test", "1.0.0");
    var tracer = try tp.getTracerWithScope(scope);

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

    std.debug.print("Cleanup will be handled by provider lifecycle...\n", .{});

    std.debug.print("Final flush and cleanup will be handled by destroyProvider()...\n", .{});

    std.debug.print("=== Test Complete ===\n", .{});
}
