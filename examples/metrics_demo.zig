//! OpenTelemetry Metrics Demo
//!
//! This example demonstrates the basic usage of OpenTelemetry metrics in Zig.
//! It shows how to create a meter provider, obtain meters, create instruments,
//! and record measurements.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a meter provider
    var sdk_provider = try otel_sdk.metrics.createProvider(allocator);
    defer sdk_provider.deinit();

    // Wrap it for API use
    var provider = otel_sdk.bridge.wrapStandardMeterProvider(&sdk_provider);

    // Get a meter for our application
    const meter = try provider.getMeterWithName("metrics.demo");

    // Create a counter for counting requests
    const request_counter = try meter.createCounterI64(
        "http.requests.total",
        "Total number of HTTP requests",
        "1", // unit: count
    );

    // Create an up-down counter for tracking active connections
    const connections_counter = try meter.createUpDownCounterI64(
        "connections.active",
        "Number of active connections",
        "1", // unit: count
    );

    // Create a gauge for temperature readings
    const temperature_gauge = try meter.createGaugeF64(
        "room.temperature",
        "Current room temperature",
        "°C", // unit: Celsius
    );

    // Create a context for recording
    const ctx = otel_api.Context.empty(allocator);

    // Simulate some HTTP requests
    std.debug.print("Simulating HTTP requests...\n", .{});
    
    // Record some requests with different attributes
    const get_attrs = [_]otel_api.KeyValue{
        otel_api.KeyValue.init("method", .{ .string = "GET" }),
        otel_api.KeyValue.init("status", .{ .int = 200 }),
    };
    request_counter.add(ctx, 5, &get_attrs);

    const post_attrs = [_]otel_api.KeyValue{
        otel_api.KeyValue.init("method", .{ .string = "POST" }),
        otel_api.KeyValue.init("status", .{ .int = 201 }),
    };
    request_counter.add(ctx, 3, &post_attrs);

    // Some failed requests
    const error_attrs = [_]otel_api.KeyValue{
        otel_api.KeyValue.init("method", .{ .string = "GET" }),
        otel_api.KeyValue.init("status", .{ .int = 500 }),
    };
    request_counter.add(ctx, 2, &error_attrs);

    std.debug.print("Total requests recorded: 10\n", .{});

    // Simulate connection changes
    std.debug.print("\nSimulating connection changes...\n", .{});
    
    const conn_attrs = [_]otel_api.KeyValue{
        otel_api.KeyValue.init("server", .{ .string = "api-1" }),
    };
    
    // Connections opened
    connections_counter.add(ctx, 10, &conn_attrs);
    std.debug.print("  +10 connections opened\n", .{});
    
    // Some connections closed
    connections_counter.add(ctx, -3, &conn_attrs);
    std.debug.print("  -3 connections closed\n", .{});
    
    // More opened
    connections_counter.add(ctx, 5, &conn_attrs);
    std.debug.print("  +5 connections opened\n", .{});
    
    // More closed
    connections_counter.add(ctx, -7, &conn_attrs);
    std.debug.print("  -7 connections closed\n", .{});
    
    std.debug.print("Net active connections: 5\n", .{});

    // Simulate temperature readings
    std.debug.print("\nSimulating temperature readings...\n", .{});
    
    const temp_attrs = [_]otel_api.KeyValue{
        otel_api.KeyValue.init("location", .{ .string = "server_room" }),
        otel_api.KeyValue.init("sensor", .{ .string = "temp_01" }),
    };
    
    // Record temperature over time
    temperature_gauge.record(ctx, 22.5, &temp_attrs);
    std.debug.print("  Temperature: 22.5°C\n", .{});
    
    temperature_gauge.record(ctx, 23.1, &temp_attrs);
    std.debug.print("  Temperature: 23.1°C\n", .{});
    
    temperature_gauge.record(ctx, 24.3, &temp_attrs);
    std.debug.print("  Temperature: 24.3°C\n", .{});
    
    temperature_gauge.record(ctx, 23.8, &temp_attrs);
    std.debug.print("  Temperature: 23.8°C (latest)\n", .{});

    // In a real application, the aggregated values would be exported by a metrics exporter
    // (e.g., ConsoleExporter, OTLPExporter, PrometheusExporter)
    // For this MVP demo, the values are stored internally in the SDK but not exported
    std.debug.print("\n=== Metrics Collection Complete ===\n", .{});
    std.debug.print("In a production setup, an exporter would read and send these metrics.\n", .{});

    std.debug.print("\nMetrics demo completed!\n", .{});
}