//! Sampling Test Example
//!
//! This example demonstrates the different sampling behaviors available in the
//! OpenTelemetry Zig SDK, including AlwaysOn, TraceIdRatioBased, and default (noop) samplers.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a console trace exporter
    var console_exporter = otel_exporters.console.createTraceExporter(allocator);
    defer console_exporter.deinit();

    // Create resource with service information
    const resource = try otel_sdk.resource.ResourceBuilder.init(allocator)
        .withDefaults()
        .addKeyValue(.{
            .key = "service.name",
            .value = .{ .string = "sampling-test" },
        })
        .addKeyValue(.{
            .key = "service.version",
            .value = .{ .string = "1.0.0" },
        })
        .finish(allocator);
    errdefer resource.deinitOwned(allocator);

    std.debug.print("=== OpenTelemetry Sampling Test ===\n\n", .{});

    // Test 1: Default sampler (noop - should drop all spans)
    std.debug.print("1. Testing Default Sampler (should drop all spans):\n", .{});
    try testSampler(allocator, resource, console_exporter.spanExporter(), otel_sdk.trace.samplers.always_off, "default-test");

    // Test 2: AlwaysOn sampler (should sample all spans)
    std.debug.print("\n2. Testing AlwaysOn Sampler (should sample all spans):\n", .{});
    try testSampler(allocator, resource, console_exporter.spanExporter(), otel_sdk.trace.samplers.always_on, "alwayson-test");

    // Test 3: TraceIdRatioBased sampler with 100% ratio (should sample all spans)
    std.debug.print("\n3. Testing TraceIdRatioBased Sampler with 100%% ratio:\n", .{});
    try testSampler(allocator, resource, console_exporter.spanExporter(), otel_sdk.trace.samplers.traceIdRatioBased(1.0), "ratio-100-test");

    // Test 4: TraceIdRatioBased sampler with 0% ratio (should drop all spans)
    std.debug.print("\n4. Testing TraceIdRatioBased Sampler with 0%% ratio:\n", .{});
    try testSampler(allocator, resource, console_exporter.spanExporter(), otel_sdk.trace.samplers.traceIdRatioBased(0.0), "ratio-0-test");

    // Test 5: TraceIdRatioBased sampler with 50% ratio (should sample some spans)
    std.debug.print("\n5. Testing TraceIdRatioBased Sampler with 50%% ratio (creating multiple spans):\n", .{});
    try testMultipleSpans(allocator, resource, console_exporter.spanExporter(), otel_sdk.trace.samplers.traceIdRatioBased(0.5));

    // Test 6: ParentBased sampler with AlwaysOn root (should sample root spans and follow parent decisions)
    std.debug.print("\n6. Testing ParentBased Sampler with AlwaysOn root sampler:\n", .{});
    try testParentBased(allocator, resource, console_exporter.spanExporter(), otel_sdk.trace.samplers.parentBased(otel_sdk.trace.samplers.always_on));

    // Test 7: ParentBased sampler with AlwaysOff root (should not sample root spans but follow parent decisions)
    std.debug.print("\n7. Testing ParentBased Sampler with Drop root sampler:\n", .{});
    try testParentBased(allocator, resource, console_exporter.spanExporter(), otel_sdk.trace.samplers.parentBased(otel_sdk.trace.samplers.always_off));

    std.debug.print("\n=== Sampling Test Complete ===\n", .{});
}

fn testSampler(
    allocator: std.mem.Allocator,
    base_resource: otel_sdk.resource.Resource,
    exporter: otel_sdk.trace.SpanExporter,
    sampler: otel_api.trace.Sampler,
    test_name: []const u8,
) !void {
    // Create test-specific resource
    const resource = try otel_sdk.resource.ResourceBuilder.init(allocator)
        .addResource(base_resource)
        .addKeyValue(.{
            .key = "test.name",
            .value = .{ .string = test_name },
        })
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    // Create a simple span processor
    const processor = try otel_sdk.trace.createSimpleSpanProcessor(
        allocator,
        exporter,
        resource,
    );

    // Create a tracer provider with the given sampler
    const provider = try otel_sdk.trace.createTracerProvider(
        allocator,
        resource,
        processor.spanProcessor(),
        sampler,
    );
    defer provider.deinit();

    // Get the tracer provider interface
    var tp = provider.tracerProvider();

    // Get a tracer
    var tracer = try tp.getTracerWithScope(.{
        .name = "sampling-test-tracer",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &.{},
    });

    // Create a root context
    const ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    // Create a span
    var span_result = try tracer.startSpan(test_name, .{
        .kind = .server,
        .attributes = &.{
            .{
                .key = "test.type",
                .value = otel_api.common.AttributeValue{ .string = "sampling" },
            },
        },
    }, ctx);
    defer span_result.deinit();

    // Add some attributes and events
    try span_result.setAttribute("test.iteration", otel_api.common.AttributeValue{ .int = 1 });
    try span_result.addEvent(otel_api.trace.Event{
        .name = "test.event",
        .timestamp_ns = 0,
        .attributes = &.{
            .{
                .key = "event.type",
                .value = otel_api.common.AttributeValue{ .string = "sampling_test" },
            },
        },
    });

    // End the span
    span_result.end(.{});

    // Clean up context
}

fn testMultipleSpans(
    allocator: std.mem.Allocator,
    base_resource: otel_sdk.resource.Resource,
    exporter: otel_sdk.trace.SpanExporter,
    sampler: otel_api.trace.Sampler,
) !void {
    // Create test-specific resource
    const resource = try otel_sdk.resource.ResourceBuilder.init(allocator)
        .addResource(base_resource)
        .addKeyValue(.{
            .key = "test.name",
            .value = .{ .string = "multiple-spans-test" },
        })
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    // Create a simple span processor
    const processor = try otel_sdk.trace.createSimpleSpanProcessor(
        allocator,
        exporter,
        resource,
    );

    // Create a tracer provider with the given sampler
    const provider = try otel_sdk.trace.createTracerProvider(
        allocator,
        resource,
        processor.spanProcessor(),
        sampler,
    );
    defer provider.deinit();

    // Get the tracer provider interface
    var tp = provider.tracerProvider();

    // Get a tracer
    var tracer = try tp.getTracerWithScope(.{
        .name = "sampling-test-tracer",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &.{},
    });

    // Create a root context
    const ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    // Create multiple spans to test the ratio-based sampling
    var sampled_count: u32 = 0;
    var total_count: u32 = 0;

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var span_name_buf: [64]u8 = undefined;
        const span_name = try std.fmt.bufPrint(&span_name_buf, "ratio-test-span-{}", .{i});

        var span_result = try tracer.startSpan(span_name, .{
            .kind = .internal,
            .attributes = &.{
                .{
                    .key = "test.iteration",
                    .value = otel_api.common.AttributeValue{ .int = @intCast(i) },
                },
            },
        }, ctx);

        // Check if this span is being sampled by looking at the trace flags
        const span_context = span_result.getSpanContext();
        if (span_context.trace_flags & otel_api.trace.SpanContext.SAMPLED_FLAG != 0) {
            sampled_count += 1;
        }
        total_count += 1;

        // End the span
        span_result.deinit();

        // Clean up context
    }

    std.debug.print("   Sampled {} out of {} spans ({}%)\n", .{ sampled_count, total_count, (sampled_count * 100) / total_count });
}

fn testParentBased(
    allocator: std.mem.Allocator,
    base_resource: otel_sdk.resource.Resource,
    exporter: otel_sdk.trace.SpanExporter,
    sampler: otel_api.trace.Sampler,
) !void {
    // Create test-specific resource
    const resource = try otel_sdk.resource.ResourceBuilder.init(allocator)
        .addResource(base_resource)
        .addKeyValue(.{
            .key = "test.name",
            .value = .{ .string = "parent-based-test" },
        })
        .finish(allocator);
    defer resource.deinitOwned(allocator);

    // Create a simple span processor
    const processor = try otel_sdk.trace.createSimpleSpanProcessor(
        allocator,
        exporter,
        resource,
    );

    // Create a tracer provider with the given sampler
    const provider = try otel_sdk.trace.createTracerProvider(
        allocator,
        resource,
        processor.spanProcessor(),
        sampler,
    );
    defer provider.deinit();

    // Get the tracer provider interface
    var tp = provider.tracerProvider();

    // Get a tracer
    var tracer = try tp.getTracerWithScope(.{
        .name = "parent-based-test-tracer",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &.{},
    });

    // Create a root context
    const ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    std.debug.print("   Creating root span (no parent):\n", .{});

    // Create a root span (should use root sampler)
    var root_span_result = try tracer.startSpan("parent-based-root", .{
        .kind = .server,
        .attributes = &.{
            .{
                .key = "span.type",
                .value = otel_api.common.AttributeValue{ .string = "root" },
            },
        },
    }, ctx);
    defer root_span_result.deinit();

    // Check if root span was sampled
    const root_span_context = root_span_result.getSpanContext();
    const root_sampled = root_span_context.trace_flags & otel_api.trace.SpanContext.SAMPLED_FLAG != 0;

    std.debug.print("   Root span sampled: {}\n", .{root_sampled});

    // Create child span (should follow parent decision)
    std.debug.print("   Creating child span (should follow parent):\n", .{});

    const child_ctx = try otel_api.trace.trace_context.withActiveSpanContext(ctx, root_span_result.getSpanContext());
    defer child_ctx.deinit();
    var child_span_result = try tracer.startSpan("parent-based-child", .{
        .kind = .internal,
        .attributes = &.{
            .{
                .key = "span.type",
                .value = otel_api.common.AttributeValue{ .string = "child" },
            },
        },
    }, child_ctx);
    defer child_span_result.deinit();

    // Check if child span was sampled
    const child_span_context = child_span_result.getSpanContext();
    const child_sampled = child_span_context.trace_flags & otel_api.trace.SpanContext.SAMPLED_FLAG != 0;

    std.debug.print("   Child span sampled: {} (should match parent: {})\n", .{ child_sampled, root_sampled });

    // Create grandchild span (should also follow parent decision)
    const grandchild_ctx = try otel_api.trace.trace_context.withActiveSpanContext(ctx, child_span_result.getSpanContext());
    defer grandchild_ctx.deinit();
    var grandchild_span_result = try tracer.startSpan("parent-based-grandchild", .{
        .kind = .internal,
        .attributes = &.{
            .{
                .key = "span.type",
                .value = otel_api.common.AttributeValue{ .string = "grandchild" },
            },
        },
    }, grandchild_ctx);
    defer grandchild_span_result.deinit();

    // End spans in reverse order
    grandchild_span_result.end(.{});
    child_span_result.end(.{});
    root_span_result.end(.{});

    // Clean up contexts
}
