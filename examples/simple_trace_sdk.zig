//! Simple Trace SDK Example
//!
//! This example demonstrates basic usage of the OpenTelemetry Trace SDK
//! implementation in Zig, including span creation, attributes, and console export.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up trace provider using the new builder pattern
    try otel_sdk.trace.buildProvider(allocator)
        .withExporterClosure(otel_exporters.console.ConsoleExporterConfig{}, otel_exporters.console.createTraceExporterWithConfig)
        .withBasicProcessor()
        .withDefaultResource()
        .withBasicProvider()
        .finish();
    defer otel_sdk.trace.destroyProvider();

    // Get the global tracer provider interface
    var tp = otel_api.getGlobalTracerProvider();

    // Get a tracer
    const scope = try otel_api.InstrumentationScope.initSimple("example-component", "1.0.0");
    var tracer = try tp.getTracerWithScope(scope);

    // Create a root context
    const ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    // Start a parent span
    std.debug.print("Starting parent span...\n", .{});
    const parent_result = try tracer.startSpan("parent-operation", .{
        .kind = .server,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{
                .key = "http.method",
                .value = otel_api.common.AttributeValue{ .string = "GET" },
            },
            .{
                .key = "http.url",
                .value = otel_api.common.AttributeValue{ .string = "/api/example" },
            },
        },
    }, ctx);
    var parent_span = parent_result;
    defer parent_span.deinit();

    // Add an event to the parent span
    try parent_span.addEvent(otel_api.trace.Event{
        .name = "request.started",
        .timestamp_ns = 0,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{
                .key = "client.ip",
                .value = otel_api.common.AttributeValue{ .string = "192.168.1.100" },
            },
        },
    });

    // Start a child span
    std.debug.print("Starting child span...\n", .{});
    const child_ctx = try otel_api.trace.trace_context.withActiveSpanContext(ctx, parent_span.getSpanContext());
    defer child_ctx.deinit();
    const child_result = try tracer.startSpan("database-query", .{
        .kind = .client,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{
                .key = "db.system",
                .value = otel_api.common.AttributeValue{ .string = "postgresql" },
            },
            .{
                .key = "db.statement",
                .value = otel_api.common.AttributeValue{ .string = "SELECT * FROM users WHERE id = ?" },
            },
        },
    }, child_ctx);
    var child_span = child_result;
    defer child_span.deinit();

    // Simulate some work
    std.time.sleep(10 * std.time.ns_per_ms);

    // Add result attribute to child span
    try child_span.setAttribute("db.rows_affected", otel_api.common.AttributeValue{ .int = 1 });

    // End child span
    std.debug.print("Ending child span...\n", .{});
    child_span.end(null);

    // Add response attributes to parent span
    try parent_span.setAttribute("http.status_code", otel_api.common.AttributeValue{ .int = 200 });
    try parent_span.setAttribute("http.response.size", otel_api.common.AttributeValue{ .int = 1024 });

    // Set status
    try parent_span.setStatus(otel_api.trace.Status.ok("Request completed successfully"));

    // End parent span
    std.debug.print("Ending parent span...\n", .{});
    parent_span.end(null);

    std.debug.print("\nSpans exported to console in OTLP JSON format.\n", .{});

    // Force flush to ensure all spans are exported
    _ = tp.forceFlush(null);
}
