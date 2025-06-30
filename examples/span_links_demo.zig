//! Span Links Demonstration
//!
//! This example demonstrates the OpenTelemetry specification-compliant span links functionality:
//! 1. Links with valid trace/span IDs
//! 2. Links with zero IDs but with attributes (spec-compliant)
//! 3. Links with zero IDs but with trace_state (spec-compliant)
//! 4. Bulk link addition using addLinks()
//! 5. Integration with sampling and export pipeline

const std = @import("std");
const otel = @import("otel");

const TraceId = otel.api.common.TraceId;
const SpanId = otel.api.common.SpanId;
const SpanContext = otel.api.trace.SpanContext;
const Link = otel.api.trace.Link;
const AttributeKeyValue = otel.api.common.AttributeKeyValue;
const AttributeValue = otel.api.common.AttributeValue;
const InstrumentationScope = otel.api.InstrumentationScope;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup trace provider with console exporter
    const trace_provider = try otel.sdk.trace.setupGlobalProvider(
        allocator,
        .{otel.sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel.exporters.console.ConsoleTraceExporter.PipelineStep.init(.{}))},
    );
    defer {
        trace_provider.deinit();
        trace_provider.destroy();
    }

    // Get tracer
    const scope = try InstrumentationScope.initSimple("span-links-demo", "1.0.0");
    var tracer = try otel.api.getGlobalTracerProvider().getTracerWithScope(scope);

    std.log.info("=== Span Links Demonstration ===\n", .{});

    // Demo 1: Traditional links with valid IDs
    try demoTraditionalLinks(allocator, &tracer);

    // Demo 2: Links with zero trace_id but with attributes (spec-compliant)
    try demoZeroTraceIdWithAttributes(allocator, &tracer);

    // Demo 3: Links with zero span_id but with attributes (spec-compliant)
    try demoZeroSpanIdWithAttributes(allocator, &tracer);

    // Demo 4: Links with zero IDs but with trace_state (spec-compliant)
    try demoZeroIdsWithTraceState(allocator, &tracer);

    // Demo 5: Bulk link addition
    try demoBulkLinkAddition(allocator, &tracer);

    // Demo 6: Integration with batch operations
    try demoBatchOperationLinks(allocator, &tracer);

    std.log.info("=== Demo Complete ===\n", .{});
}

fn demoTraditionalLinks(allocator: std.mem.Allocator, tracer: *otel.api.trace.Tracer) !void {
    std.log.info("Demo 1: Traditional Links with Valid IDs", .{});

    var span = try tracer.startSpan("traditional-links-demo", .{}, otel.api.Context.init(allocator));
    defer span.deinit();

    // Create links to other spans with valid IDs
    const link1 = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
            .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
            .trace_flags = 1,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "link.type", .value = AttributeValue{ .string = "parent" } },
            .{ .key = "service.name", .value = AttributeValue{ .string = "user-service" } },
        },
    };

    const link2 = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 10, 11, 12, 13, 14, 15, 16 }),
            .span_id = SpanId.fromBytes(.{ 9, 8, 7, 6, 5, 4, 3, 2 }),
            .trace_flags = 1,
            .trace_state = "vendor=example",
            .is_remote = true,
        },
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "link.type", .value = AttributeValue{ .string = "sibling" } },
            .{ .key = "service.name", .value = AttributeValue{ .string = "payment-service" } },
        },
    };

    try span.addLink(link1);
    try span.addLink(link2);

    try span.setStatus(.{ .code = .ok, .description = "Links added successfully" });
    span.end(null);

    std.log.info("✓ Added 2 traditional links with valid IDs\n", .{});
}

fn demoZeroTraceIdWithAttributes(allocator: std.mem.Allocator, tracer: *otel.api.trace.Tracer) !void {
    std.log.info("Demo 2: Links with Zero Trace ID + Attributes (Spec Compliant)", .{});

    var span = try tracer.startSpan("zero-trace-id-demo", .{}, otel.api.Context.init(allocator));
    defer span.deinit();

    // Link with zero trace_id but with attributes - should be accepted per spec
    const zero_trace_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
            .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
            .trace_flags = 0,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "external.system", .value = AttributeValue{ .string = "legacy-database" } },
            .{ .key = "operation.type", .value = AttributeValue{ .string = "query" } },
            .{ .key = "external.reason", .value = AttributeValue{ .string = "no-tracing-support" } },
        },
    };

    try span.addLink(zero_trace_link);

    try span.setStatus(.{ .code = .ok, .description = "Zero trace ID link added successfully" });
    span.end(null);

    std.log.info("✓ Added link with zero trace_id but with attributes\n", .{});
}

fn demoZeroSpanIdWithAttributes(allocator: std.mem.Allocator, tracer: *otel.api.trace.Tracer) !void {
    std.log.info("Demo 3: Links with Zero Span ID + Attributes (Spec Compliant)", .{});

    var span = try tracer.startSpan("zero-span-id-demo", .{}, otel.api.Context.init(allocator));
    defer span.deinit();

    // Link with zero span_id but with attributes - should be accepted per spec
    const zero_span_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
            .span_id = SpanId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0 }),
            .trace_flags = 0,
            .trace_state = null,
            .is_remote = true,
        },
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "external.service", .value = AttributeValue{ .string = "third-party-api" } },
            .{ .key = "link.reason", .value = AttributeValue{ .string = "causality-without-span-id" } },
        },
    };

    try span.addLink(zero_span_link);

    try span.setStatus(.{ .code = .ok, .description = "Zero span ID link added successfully" });
    span.end(null);

    std.log.info("✓ Added link with zero span_id but with attributes\n", .{});
}

fn demoZeroIdsWithTraceState(allocator: std.mem.Allocator, tracer: *otel.api.trace.Tracer) !void {
    std.log.info("Demo 4: Links with Zero IDs + TraceState (Spec Compliant)", .{});

    var span = try tracer.startSpan("zero-ids-tracestate-demo", .{}, otel.api.Context.init(allocator));
    defer span.deinit();

    // Link with zero IDs but with trace_state - should be accepted per spec
    const zero_ids_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
            .span_id = SpanId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0 }),
            .trace_flags = 0,
            .trace_state = "vendor=custom,priority=high,baggage=important-data",
            .is_remote = true,
        },
        .attributes = null,
    };

    try span.addLink(zero_ids_link);

    try span.setStatus(.{ .code = .ok, .description = "Zero IDs with trace_state link added successfully" });
    span.end(null);

    std.log.info("✓ Added link with zero IDs but with trace_state\n", .{});
}

fn demoBulkLinkAddition(allocator: std.mem.Allocator, tracer: *otel.api.trace.Tracer) !void {
    std.log.info("Demo 5: Bulk Link Addition using addLinks()", .{});

    var span = try tracer.startSpan("bulk-links-demo", .{}, otel.api.Context.init(allocator));
    defer span.deinit();

    // Create multiple links to add at once
    const bulk_links = [_]Link{
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }),
                .span_id = SpanId.fromBytes(.{ 1, 1, 1, 1, 1, 1, 1, 1 }),
                .trace_flags = 1,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "batch.item", .value = AttributeValue{ .int = 1 } },
                .{ .key = "service.name", .value = AttributeValue{ .string = "inventory-service" } },
            },
        },
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 }),
                .span_id = SpanId.fromBytes(.{ 2, 2, 2, 2, 2, 2, 2, 2 }),
                .trace_flags = 1,
                .trace_state = "priority=high",
                .is_remote = true,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "batch.item", .value = AttributeValue{ .int = 2 } },
                .{ .key = "service.name", .value = AttributeValue{ .string = "shipping-service" } },
            },
        },
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
                .span_id = SpanId.fromBytes(.{ 3, 3, 3, 3, 3, 3, 3, 3 }),
                .trace_flags = 0,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "batch.item", .value = AttributeValue{ .int = 3 } },
                .{ .key = "service.name", .value = AttributeValue{ .string = "legacy-billing" } },
                .{ .key = "external.reason", .value = AttributeValue{ .string = "no-trace-id-support" } },
            },
        },
    };

    // Add all links at once
    try span.addLinks(&bulk_links);

    try span.setStatus(.{ .code = .ok, .description = "Bulk links added successfully" });
    span.end(null);

    std.log.info("✓ Added 3 links using bulk addLinks() API\n", .{});
}

fn demoBatchOperationLinks(allocator: std.mem.Allocator, tracer: *otel.api.trace.Tracer) !void {
    std.log.info("Demo 6: Batch Operation with Links", .{});

    // Create links to represent a batch operation scenario
    const batch_links = [_]Link{
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10 }),
                .span_id = SpanId.fromBytes(.{ 10, 10, 10, 10, 10, 10, 10, 10 }),
                .trace_flags = 1,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "batch.operation", .value = AttributeValue{ .string = "user-registration" } },
                .{ .key = "batch.sequence", .value = AttributeValue{ .int = 1 } },
            },
        },
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11 }),
                .span_id = SpanId.fromBytes(.{ 11, 11, 11, 11, 11, 11, 11, 11 }),
                .trace_flags = 1,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "batch.operation", .value = AttributeValue{ .string = "user-registration" } },
                .{ .key = "batch.sequence", .value = AttributeValue{ .int = 2 } },
            },
        },
    };

    // Create span with initial links
    var span = try tracer.startSpan("batch-operation", .{
        .links = &batch_links,
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "operation.type", .value = AttributeValue{ .string = "batch" } },
            .{ .key = "batch.size", .value = AttributeValue{ .int = 2 } },
        },
    }, otel.api.Context.init(allocator));
    defer span.deinit();

    // Add more links after span creation (these won't affect sampling)
    const additional_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12 }),
            .span_id = SpanId.fromBytes(.{ 12, 12, 12, 12, 12, 12, 12, 12 }),
            .trace_flags = 1,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "batch.operation", .value = AttributeValue{ .string = "user-registration" } },
            .{ .key = "batch.sequence", .value = AttributeValue{ .int = 3 } },
            .{ .key = "added.after.creation", .value = AttributeValue{ .bool = true } },
        },
    };

    try span.addLink(additional_link);

    try span.setStatus(.{ .code = .ok, .description = "Batch operation completed with links" });
    span.end(null);

    std.log.info("✓ Created span with initial links and added additional link after creation\n", .{});
}
