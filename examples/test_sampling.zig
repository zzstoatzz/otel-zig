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

    std.debug.print("=== OpenTelemetry Sampling Test ===\n\n", .{});

    try testAlwaysOffSampler(allocator);
    try testAlwaysOnSampler(allocator);
    try testRatioBased100Sampler(allocator);
    try testRatioBased0Sampler(allocator);
    try testRatioBased50Sampler(allocator);
    try testParentBasedAlwaysOn(allocator);
    try testParentBasedAlwaysOff(allocator);

    std.debug.print("\n=== Sampling Test Complete ===\n", .{});
}

fn testAlwaysOffSampler(allocator: std.mem.Allocator) !void {
    std.debug.print("1. Testing AlwaysOff Sampler (should drop all spans):\n", .{});

    try otel_sdk.trace.buildProvider(allocator)
        .withExporterClosure(otel_exporters.console.ConsoleExporterConfig{}, otel_exporters.console.createTraceExporterWithConfig)
        .withBasicProcessor()
        .withDefaultResource()
        .withConfigurableProvider(otel_sdk.trace.samplers.always_off, null, null)
        .finish();
    defer otel_sdk.trace.destroyProvider();

    try runSingleSpanTest("always-off-test");
}

fn testAlwaysOnSampler(allocator: std.mem.Allocator) !void {
    std.debug.print("\n2. Testing AlwaysOn Sampler (should sample all spans):\n", .{});

    try otel_sdk.trace.buildProvider(allocator)
        .withExporterClosure(otel_exporters.console.ConsoleExporterConfig{}, otel_exporters.console.createTraceExporterWithConfig)
        .withBasicProcessor()
        .withDefaultResource()
        .withConfigurableProvider(otel_sdk.trace.samplers.always_on, null, null)
        .finish();
    defer otel_sdk.trace.destroyProvider();

    try runSingleSpanTest("always-on-test");
}

fn testRatioBased100Sampler(allocator: std.mem.Allocator) !void {
    std.debug.print("\n3. Testing TraceIdRatioBased Sampler with 100%% ratio:\n", .{});

    try otel_sdk.trace.buildProvider(allocator)
        .withExporterClosure(otel_exporters.console.ConsoleExporterConfig{}, otel_exporters.console.createTraceExporterWithConfig)
        .withBasicProcessor()
        .withDefaultResource()
        .withConfigurableProvider(otel_sdk.trace.samplers.traceIdRatioBased(1.0), null, null)
        .finish();
    defer otel_sdk.trace.destroyProvider();

    try runSingleSpanTest("ratio-100-test");
}

fn testRatioBased0Sampler(allocator: std.mem.Allocator) !void {
    std.debug.print("\n4. Testing TraceIdRatioBased Sampler with 0%% ratio:\n", .{});

    try otel_sdk.trace.buildProvider(allocator)
        .withExporterClosure(otel_exporters.console.ConsoleExporterConfig{}, otel_exporters.console.createTraceExporterWithConfig)
        .withBasicProcessor()
        .withDefaultResource()
        .withConfigurableProvider(otel_sdk.trace.samplers.traceIdRatioBased(0.0), null, null)
        .finish();
    defer otel_sdk.trace.destroyProvider();

    try runSingleSpanTest("ratio-0-test");
}

fn testRatioBased50Sampler(allocator: std.mem.Allocator) !void {
    std.debug.print("\n5. Testing TraceIdRatioBased Sampler with 50%% ratio (creating multiple spans):\n", .{});

    try otel_sdk.trace.buildProvider(allocator)
        .withExporterClosure(otel_exporters.console.ConsoleExporterConfig{}, otel_exporters.console.createTraceExporterWithConfig)
        .withBasicProcessor()
        .withDefaultResource()
        .withConfigurableProvider(otel_sdk.trace.samplers.traceIdRatioBased(0.5), null, null)
        .finish();
    defer otel_sdk.trace.destroyProvider();

    try runMultipleSpansTest();
}

fn testParentBasedAlwaysOn(allocator: std.mem.Allocator) !void {
    std.debug.print("\n6. Testing ParentBased Sampler with AlwaysOn root sampler:\n", .{});

    try otel_sdk.trace.buildProvider(allocator)
        .withExporterClosure(otel_exporters.console.ConsoleExporterConfig{}, otel_exporters.console.createTraceExporterWithConfig)
        .withBasicProcessor()
        .withDefaultResource()
        .withConfigurableProvider(otel_sdk.trace.samplers.parentBased(otel_sdk.trace.samplers.always_on), null, null)
        .finish();
    defer otel_sdk.trace.destroyProvider();

    try runParentChildTest();
}

fn testParentBasedAlwaysOff(allocator: std.mem.Allocator) !void {
    std.debug.print("\n7. Testing ParentBased Sampler with AlwaysOff root sampler:\n", .{});

    try otel_sdk.trace.buildProvider(allocator)
        .withExporterClosure(otel_exporters.console.ConsoleExporterConfig{}, otel_exporters.console.createTraceExporterWithConfig)
        .withBasicProcessor()
        .withDefaultResource()
        .withConfigurableProvider(otel_sdk.trace.samplers.parentBased(otel_sdk.trace.samplers.always_off), null, null)
        .finish();
    defer otel_sdk.trace.destroyProvider();

    try runParentChildTest();
}

fn runSingleSpanTest(test_name: []const u8) !void {
    var tp = otel_api.getGlobalTracerProvider();
    const scope = try otel_api.InstrumentationScope.initSimple("sampling-test-tracer", "1.0.0");
    var tracer = try tp.getTracerWithScope(scope);

    const ctx = otel_api.Context.empty(std.heap.page_allocator);
    defer ctx.deinit();

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

    span_result.end(.{});
}

fn runMultipleSpansTest() !void {
    var tp = otel_api.getGlobalTracerProvider();
    const scope = try otel_api.InstrumentationScope.initSimple("sampling-test-tracer", "1.0.0");
    var tracer = try tp.getTracerWithScope(scope);

    const ctx = otel_api.Context.empty(std.heap.page_allocator);
    defer ctx.deinit();

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

        const span_context = span_result.getSpanContext();
        if (span_context.trace_flags & otel_api.trace.SpanContext.SAMPLED_FLAG != 0) {
            sampled_count += 1;
        }
        total_count += 1;

        span_result.end(.{});
        span_result.deinit();
    }

    std.debug.print("   Sampled {} out of {} spans ({}%)\n", .{ sampled_count, total_count, (sampled_count * 100) / total_count });
}

fn runParentChildTest() !void {
    var tp = otel_api.getGlobalTracerProvider();
    const scope = try otel_api.InstrumentationScope.initSimple("parent-based-test-tracer", "1.0.0");
    var tracer = try tp.getTracerWithScope(scope);

    const ctx = otel_api.Context.empty(std.heap.page_allocator);
    defer ctx.deinit();

    std.debug.print("   Creating root span (no parent):\n", .{});

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

    const root_span_context = root_span_result.getSpanContext();
    const root_sampled = root_span_context.trace_flags & otel_api.trace.SpanContext.SAMPLED_FLAG != 0;

    std.debug.print("   Root span sampled: {}\n", .{root_sampled});

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

    const child_span_context = child_span_result.getSpanContext();
    const child_sampled = child_span_context.trace_flags & otel_api.trace.SpanContext.SAMPLED_FLAG != 0;

    std.debug.print("   Child span sampled: {} (should match parent: {})\n", .{ child_sampled, root_sampled });

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

    grandchild_span_result.end(.{});
    child_span_result.end(.{});
    root_span_result.end(.{});
}
