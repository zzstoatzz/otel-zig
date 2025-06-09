//! OpenTelemetry Metrics OTLP Export Demo
//!
//! This example demonstrates exporting metrics using the OpenTelemetry Protocol (OTLP).
//! It shows how to:
//! - Create a meter provider and instruments
//! - Record measurements
//! - Set up an OTLP exporter
//! - Export metrics to an OTLP-compatible backend
//!
//! To run this example, you'll need an OTLP receiver running, such as:
//! - OpenTelemetry Collector: docker run -p 4318:4318 otel/opentelemetry-collector:latest
//! - Jaeger with OTLP support: docker run -p 4318:4318 jaegertracing/all-in-one:latest

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var otlp_exporter = otel_exporters.otlp.OtlpMetricExporter.init(allocator, .{
        .endpoint = "http://localhost:4318",
        .transport = .http_json,
    });
    var exporter = otel_sdk.metrics.MetricExporter{
        .bridge = otel_sdk.metrics.BridgeMetricExporter.init(&otlp_exporter),
    };
    errdefer exporter.deinit();

    var provider = try otel_sdk.metrics.createSimpleSyncMetrics(
        allocator,
        "metrics_demo_otlp",
        exporter,
    );
    defer {
        provider.deinit();
        _ = otel_api.provider_registry.setGlobalMeterProvider(null);
    }
    _ = otel_api.provider_registry.setGlobalMeterProvider(&provider);

    // Create arena allocator for meter/instrument operations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    std.debug.print("=== OpenTelemetry Metrics OTLP Export Demo ===\n\n", .{});

    // Get a meter for our application (using arena allocator)
    const scope = try otel_api.InstrumentationScope.initSimple("otlp.metrics.demo", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    // Create various instruments
    const request_counter = try meter.createCounter(
        i64,
        "http.server.request_count",
        "Total number of HTTP requests",
        "1",
    );

    const request_duration = try meter.createCounter(
        f64,
        "http.server.request_duration",
        "Total time spent processing requests",
        "ms",
    );

    const active_requests = try meter.createUpDownCounter(
        i64,
        "http.server.active_requests",
        "Number of active HTTP requests",
        "1",
    );

    const memory_max = try meter.createGauge(
        f64,
        "process.runtime.memory_max",
        "max memory available",
        "MiB",
    );

    const cpu_usage = try meter.createGauge(
        f64,
        "process.runtime.cpu_usage",
        "Current CPU usage percentage",
        "%",
    );

    // Create a context for recording (using main allocator for context)
    var ctx = otel_api.Context.empty(arena_allocator);
    defer ctx.deinit();

    // Simulate some application activity
    std.debug.print("Recording metrics...\n", .{});

    // Simulate HTTP requests
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        // Request starts
        const start_attrs = try otel_api.common.AttributeBuilder.init(arena_allocator)
            .add("http.method", .{ .string = "GET" })
            .add("http.route", .{ .string = "/api/users" })
            .finish(arena_allocator);
        active_requests.add(ctx, 1, start_attrs);

        // Simulate processing time
        const duration = 50.0 + @as(f64, @floatFromInt(i)) * 10.0;
        const duration_attrs = try otel_api.common.AttributeBuilder.init(arena_allocator)
            .add("http.method", .{ .string = "GET" })
            .add("http.status_code", .{ .int = 200 })
            .finish(arena_allocator);
        request_duration.add(ctx, duration, duration_attrs);

        // Request completes
        const counter_attrs = try otel_api.common.AttributeBuilder.init(arena_allocator)
            .add("http.method", .{ .string = "GET" })
            .add("http.status_code", .{ .int = 200 })
            .finish(arena_allocator);
        request_counter.add(ctx, 1, counter_attrs);

        const end_attrs = try otel_api.common.AttributeBuilder.init(arena_allocator)
            .add("http.method", .{ .string = "GET" })
            .add("http.route", .{ .string = "/api/users" })
            .finish(arena_allocator);
        active_requests.add(ctx, -1, end_attrs);

        std.debug.print("  Processed request {}: {}ms\n", .{ i + 1, duration });
    }

    // Record some system metrics

    var mem_size: u64 = 0;
    {
        var mib = [_]c_int{ 6, 24 };
        var size: usize = @sizeOf(@TypeOf(mem_size));

        const result = std.posix.system.sysctl(&mib, mib.len, @ptrCast(&mem_size), &size, null, 0);
        if (result != 0) {
            std.debug.print("unable to read memory.", .{});
        }
    }
    const mem_max: f64 = @as(f64, @floatFromInt(mem_size)) / 1048576.0;
    const memory_attrs = try otel_api.common.AttributeBuilder.init(arena_allocator)
        .add("memory.type", .{ .string = "heap" })
        .finish(arena_allocator);
    memory_max.record(ctx, mem_max, memory_attrs);
    std.debug.print("  Memory Max: {d:.2} MiB\n", .{mem_max});

    const cpu_attrs = try otel_api.common.AttributeBuilder.init(arena_allocator)
        .add("cpu.core", .{ .string = "all" })
        .finish(arena_allocator);
    cpu_usage.record(ctx, 45.2, cpu_attrs);
    std.debug.print("  CPU usage: 45.2%\n", .{});

    // Now collect and export metrics
    std.debug.print("\nCollecting metrics from provider...\n", .{});
    if (otel_api.getGlobalMeterProvider().forceFlush(null).isSuccess()) {
        std.debug.print("flushed metrics.\n", .{});
    } else {
        std.debug.print("failed.\n", .{});
    }
}
