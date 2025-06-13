//! OpenTelemetry Metrics Demo
//!
//! This example demonstrates the basic usage of OpenTelemetry metrics in Zig.
//! It shows how to create a meter provider, obtain meters, create instruments,
//! and record measurements.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var console_exporter = otel_exporters.console.ConsoleMetricExporter.init(allocator, .{});
    var exporter = otel_sdk.metrics.MetricExporter{
        .bridge = otel_sdk.metrics.BridgeMetricExporter.init(&console_exporter),
    };
    errdefer exporter.deinit();

    var provider = try otel_sdk.metrics.createSimpleSyncMetrics(
        allocator,
        "metrics_demo",
        exporter,
    );
    defer {
        provider.deinit();
        _ = otel_api.provider_registry.setGlobalMeterProvider(null);
    }
    _ = otel_api.provider_registry.setGlobalMeterProvider(&provider);

    // Get a meter for our application
    //     // Get application logger from global registry (now backed by SDK)
    const scope = try otel_api.InstrumentationScope.initSimple("dns.query.example", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    // Create a counter for counting requests
    const request_counter = try meter.createCounter(
        i64,
        "http.requests.total",
        "Total number of HTTP requests",
        "1", // unit: count
    );

    // Create an up-down counter for tracking active connections
    const connections_counter = try meter.createUpDownCounter(
        i64,
        "connections.active",
        "Number of active connections",
        "1", // unit: count
    );

    // Create a gauge for temperature readings
    const temperature_gauge = try meter.createGauge(
        f64,
        "room.temperature",
        "Current room temperature",
        "°C", // unit: Celsius
    );

    // Create a context for recording
    const ctx = otel_api.Context.empty(allocator);

    // Simulate some HTTP requests
    std.debug.print("Simulating HTTP requests...\n", .{});

    // Record some requests with different attributes
    const get_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add("method", .{ .string = "GET" })
        .add("status", .{ .int = 200 })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, get_attrs);
    request_counter.add(ctx, 5, get_attrs);

    const post_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add("method", .{ .string = "POST" })
        .add("status", .{ .int = 201 })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, post_attrs);
    request_counter.add(ctx, 3, post_attrs);

    // Some failed requests
    const error_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add("method", .{ .string = "GET" })
        .add("status", .{ .int = 500 })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, error_attrs);
    request_counter.add(ctx, 2, error_attrs);

    std.debug.print("Total requests recorded: 10\n", .{});

    // Simulate connection changes
    std.debug.print("\nSimulating connection changes...\n", .{});

    const conn_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add("server", .{ .string = "api-1" })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, conn_attrs);

    // Connections opened
    connections_counter.add(ctx, 10, conn_attrs);
    std.debug.print("  +10 connections opened\n", .{});

    // Some connections closed
    connections_counter.add(ctx, -3, conn_attrs);
    std.debug.print("  -3 connections closed\n", .{});

    // More opened
    connections_counter.add(ctx, 5, conn_attrs);
    std.debug.print("  +5 connections opened\n", .{});

    // More closed
    connections_counter.add(ctx, -7, conn_attrs);
    std.debug.print("  -7 connections closed\n", .{});

    std.debug.print("Net active connections: 5\n", .{});

    // Simulate temperature readings
    std.debug.print("\nSimulating temperature readings...\n", .{});

    const temp_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add("location", .{ .string = "server_room" })
        .add("sensor", .{ .string = "temp_01" })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, temp_attrs);

    // Record temperature over time
    temperature_gauge.record(ctx, 22.5, temp_attrs);
    std.debug.print("  Temperature: 22.5°C\n", .{});

    temperature_gauge.record(ctx, 23.1, temp_attrs);
    std.debug.print("  Temperature: 23.1°C\n", .{});

    temperature_gauge.record(ctx, 24.3, temp_attrs);
    std.debug.print("  Temperature: 24.3°C\n", .{});

    temperature_gauge.record(ctx, 23.8, temp_attrs);
    std.debug.print("  Temperature: 23.8°C (latest)\n", .{});

    // Force flush to trigger export of collected metrics
    std.debug.print("\n=== Forcing Metrics Export ===\n", .{});
    const flush_result = provider.forceFlush(5000); // 5 second timeout
    if (flush_result == .success) {
        std.debug.print("✅ Metrics exported successfully!\n", .{});
    } else {
        std.debug.print("❌ Failed to export metrics\n", .{});
    }

    std.debug.print("\n=== Metrics Collection Complete ===\n", .{});

    std.debug.print("\nMetrics demo completed!\n", .{});
}
