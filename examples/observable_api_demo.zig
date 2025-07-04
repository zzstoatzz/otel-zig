//! Observable Instruments API Demo
//!
//! This example demonstrates the new API methods for creating observable instruments
//! using the standard OpenTelemetry API flow (MeterProvider -> Meter -> Observable Instruments).
//! This shows that the API integration is working correctly.
//!
//! Run with: zig build example-observable-api

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

// Simple state for callbacks
const AppMetrics = struct {
    cpu_usage: f64 = 45.5,
    memory_bytes: i64 = 1024 * 1024 * 512, // 512 MB
    connections: i64 = 150,
};

var app_metrics = AppMetrics{};

// Callback functions
fn cpuCallback(result: *otel_api.metrics.ObservableResult(f64), state: *AppMetrics) void {
    const attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "component", .value = .{ .string = "system" } },
    };
    result.observe(state.cpu_usage, &attrs, null) catch {};
}

fn memoryCallback(result: *otel_api.metrics.ObservableResult(i64), state: *AppMetrics) void {
    const attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "type", .value = .{ .string = "heap" } },
    };
    result.observe(state.memory_bytes, &attrs, null) catch {};
}

fn connectionsCallback(result: *otel_api.metrics.ObservableResult(i64), state: *AppMetrics) void {
    result.observeValue(state.connections) catch {};
}

// Stateless callback
fn uptimeCallback(result: *otel_api.metrics.ObservableResult(f64)) void {
    const uptime_seconds = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0;
    result.observeValue(@mod(uptime_seconds, 3600.0)) catch {}; // Reset every hour for demo
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== OpenTelemetry Observable Instruments API Demo ===", .{});

    // Set up the OpenTelemetry SDK with console exporter
    std.log.info("Setting up OpenTelemetry with console exporter...", .{});
    const provider = try otel_sdk.metrics.setupGlobalProvider(
        allocator,
        .{otel_sdk.metrics.BasicMetricProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleMetricExporter.PipelineStep.init(.{}))},
    );
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Get a meter using the standard API flow
    std.log.info("Creating meter using API...", .{});
    const scope = try otel_api.InstrumentationScope.initSimple("observable.api.demo", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    // Create observable instruments using the NEW API methods
    std.log.info("Creating observable instruments using NEW API methods...", .{});

    // Create observable gauge for CPU usage (f64)
    var cpu_gauge = try meter.createObservableGauge(f64, "system.cpu.usage", "CPU usage percentage", "percent");
    std.log.info("✓ Created observable gauge: {s}", .{cpu_gauge.getName()});

    // Create observable gauge for memory usage (i64)
    var memory_gauge = try meter.createObservableGauge(i64, "system.memory.usage", "Memory usage in bytes", "bytes");
    std.log.info("✓ Created observable gauge: {s}", .{memory_gauge.getName()});

    // Create observable up-down counter for connections (i64)
    var connections_counter = try meter.createObservableUpDownCounter(i64, "system.connections.active", "Active connections", "connections");
    std.log.info("✓ Created observable up-down counter: {s}", .{connections_counter.getName()});

    // Create observable counter for uptime (f64)
    var uptime_counter = try meter.createObservableCounter(f64, "system.uptime", "System uptime", "seconds");
    std.log.info("✓ Created observable counter: {s}", .{uptime_counter.getName()});

    // Register callbacks using the API
    std.log.info("Registering callbacks using API...", .{});

    const cpu_handle = try cpu_gauge.registerCallback(AppMetrics, cpuCallback, &app_metrics);
    const memory_handle = try memory_gauge.registerCallback(AppMetrics, memoryCallback, &app_metrics);
    const connections_handle = try connections_counter.registerCallback(AppMetrics, connectionsCallback, &app_metrics);
    const uptime_handle = try uptime_counter.registerCallbackNoState(uptimeCallback);

    defer {
        cpu_handle.unregister();
        memory_handle.unregister();
        connections_handle.unregister();
        uptime_handle.unregister();
    }

    std.log.info("✓ All callbacks registered successfully", .{});
    std.log.info("", .{});

    // Verify instruments are enabled
    std.log.info("Verifying instrument states:", .{});
    std.log.info("  CPU gauge enabled: {}", .{cpu_gauge.enabled()});
    std.log.info("  Memory gauge enabled: {}", .{memory_gauge.enabled()});
    std.log.info("  Connections counter enabled: {}", .{connections_counter.enabled()});
    std.log.info("  Uptime counter enabled: {}", .{uptime_counter.enabled()});
    std.log.info("", .{});

    // Simulate metric collection cycles
    std.log.info("Starting metric collection simulation...", .{});
    std.log.info("(Metrics will be exported to console by the exporter)", .{});
    std.log.info("", .{});

    for (0..3) |cycle| {
        std.log.info("--- Collection Cycle {} ---", .{cycle + 1});

        // Update app metrics to simulate changes
        app_metrics.cpu_usage = 20.0 + @as(f64, @floatFromInt(cycle * 15));
        app_metrics.memory_bytes += @as(i64, @intCast(cycle)) * 50 * 1024 * 1024; // Add 50MB each cycle
        app_metrics.connections = 100 + @as(i64, @intCast(cycle)) * 25;

        std.log.info("Current metrics state:", .{});
        std.log.info("  CPU: {d:.1}%", .{app_metrics.cpu_usage});
        std.log.info("  Memory: {d:.1} MB", .{@as(f64, @floatFromInt(app_metrics.memory_bytes)) / (1024.0 * 1024.0)});
        std.log.info("  Connections: {}", .{app_metrics.connections});

        // Wait a bit before next collection
        std.time.sleep(1000 * std.time.ns_per_ms);
    }

    std.log.info("", .{});
    std.log.info("=== Demo Complete ===", .{});
    std.log.info("Successfully demonstrated:", .{});
    std.log.info("  ✓ Creating observable instruments using API methods", .{});
    std.log.info("  ✓ meter.createObservableGauge()", .{});
    std.log.info("  ✓ meter.createObservableCounter()", .{});
    std.log.info("  ✓ meter.createObservableUpDownCounter()", .{});
    std.log.info("  ✓ Stateful and stateless callback registration", .{});
    std.log.info("  ✓ Automatic metric collection and export", .{});
    std.log.info("  ✓ Full API to SDK integration", .{});
    std.log.info("", .{});
    std.log.info("🎉 Observable Instruments API implementation is working!", .{});
}
