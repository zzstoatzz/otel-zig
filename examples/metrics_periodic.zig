//! OpenTelemetry Periodic Metrics Demo
//!
//! This example demonstrates the usage of the PeriodicProcessor for OpenTelemetry
//! metrics in Zig. It shows how to set up periodic collection of metrics that runs
//! in a background thread and automatically exports metrics at regular intervals.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting periodic metrics demo...", .{});

    // Create an OTLP exporter for metrics
    // Default endpoint is http://localhost:4318/v1/metrics
    var otlp_exporter = otel_exporters.otlp.OtlpMetricExporter.init(allocator, .{});
    defer otlp_exporter.deinit();

    const exporter = otel_sdk.metrics.MetricExporter{
        .bridge = otel_sdk.metrics.BridgeMetricExporter.init(&otlp_exporter),
    };
    errdefer exporter.deinit();

    // Create periodic processor with 5-second interval (faster than default for demo)
    const periodic_processor = try otel_sdk.metrics.createPeriodicProcessor(
        allocator,
        exporter,
        60000, // 5 seconds for demo purposes
    );
    errdefer periodic_processor.deinit();

    // Create meter provider with periodic processor
    const resource = try otel_sdk.resource.ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);
    errdefer resource.deinitOwned(allocator);
    const meter_provider = try otel_sdk.metrics.StandardMeterProvider.init(
        allocator,
        resource,
        periodic_processor.metricProcessor(),
    );
    defer meter_provider.deinit();

    // Set as global provider
    var global_provider = meter_provider.meterProvider();
    _ = otel_api.provider_registry.setGlobalMeterProvider(&global_provider);
    defer _ = otel_api.provider_registry.setGlobalMeterProvider(null);

    // Get a meter for our application
    const scope = try otel_api.InstrumentationScope.initSimple("periodic_metrics_demo", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    // Create various instruments
    const request_counter = try meter.createCounter(
        i64,
        "http.requests.total",
        "Total number of HTTP requests",
        "1", // unit: count
    );

    const active_connections = try meter.createUpDownCounter(
        i64,
        "connections.active",
        "Number of active connections",
        "1",
    );

    const cpu_usage = try meter.createGauge(
        f64,
        "cpu.usage",
        "Current CPU usage percentage",
        "%",
    );

    const response_time = try meter.createHistogram(
        f64,
        "http.response_time",
        "HTTP response time in milliseconds",
        "ms",
    );

    std.log.info("Created instruments, starting metric recording...", .{});
    std.log.info("Metrics will be exported every 5 seconds by the background thread", .{});

    // Create a context for recording
    const ctx = otel_api.Context.empty(allocator);

    // Simulate activity for 5 minutes (300 seconds)
    var i: u32 = 0;
    while (i < 130) : (i += 1) {
        // Simulate HTTP requests
        request_counter.add(ctx, std.crypto.random.intRangeAtMost(i64, 1, 10), &[_]otel_api.AttributeKeyValue{});

        // Simulate connection changes
        const conn_change = std.crypto.random.intRangeAtMost(i64, -3, 5);
        active_connections.add(ctx, conn_change, &[_]otel_api.AttributeKeyValue{});

        // Simulate CPU usage
        const cpu_val = 20.0 + @as(f64, @floatFromInt(std.crypto.random.intRangeAtMost(u32, 0, 60)));
        cpu_usage.record(ctx, cpu_val, &[_]otel_api.AttributeKeyValue{});

        // Simulate response times
        const response_ms = 50.0 + @as(f64, @floatFromInt(std.crypto.random.intRangeAtMost(u32, 0, 200)));
        response_time.record(ctx, response_ms, &[_]otel_api.AttributeKeyValue{});

        std.log.info("Iteration {}: recorded metrics", .{i + 1});
        std.time.sleep(std.time.ns_per_s); // Sleep for 1 second
    }

    std.log.info("Demo completed. Shutting down...", .{});

    // Force a final flush before shutdown
    _ = meter_provider.forceFlush(5000);

    std.log.info("Final flush completed. Exiting.", .{});
}
