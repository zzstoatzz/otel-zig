//! OpenTelemetry Metrics Demo
//!
//! This example demonstrates the basic usage of OpenTelemetry metrics in Zig.
//! It shows how to create a meter provider, obtain meters, create instruments,
//! and record measurements.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

// State structures for stateful callbacks
const MemoryState = struct {
    base_used: i64 = 1024 * 1024 * 512, // 512 MB base
    base_total: i64 = 1024 * 1024 * 1024 * 8, // 8 GB total
};

const RequestState = struct {
    total_requests: i64 = 0,
    start_time: i64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try basicProcessorDemo(allocator);
    try advancedProcessorDemo(allocator);
}

// Callback for observable counter (stateful) - total requests served
fn totalRequestsCallback(allocator: std.mem.Allocator, result: *otel_api.metrics.ObservableResult(i64), state: *anyopaque) void {
    const request_state: *RequestState = @ptrCast(@alignCast(state));

    // Simulate increasing total requests
    request_state.total_requests += std.crypto.random.intRangeAtMost(i64, 10, 100);

    const attrs = otel_api.common.AttributeBuilder.init(allocator)
        .add("server.name", .{ .string = "api-server-1" })
        .add("server.region", .{ .string = "us-east-1" })
        .add("protocol", .{ .string = "http/2" })
        .finish(allocator) catch |err| {
        std.log.err("Unable to build Total Request attributes. {}", .{err});
        return;
    };

    result.observe(request_state.total_requests, attrs);
}

// Callback for observable gauge (stateless) - CPU utilization
fn cpuUtilizationCallback(allocator: std.mem.Allocator, result: *otel_api.metrics.ObservableResult(f64)) void {
    // Simulate CPU utilization between 20% and 85%
    const cpu_percent = 20.0 + @as(f64, @floatFromInt(std.crypto.random.intRangeAtMost(u32, 0, 65)));

    const attrs = otel_api.common.AttributeBuilder.init(allocator)
        .add("server.name", .{ .string = "api-server-1" })
        .add("cpu.core", .{ .string = "all" })
        .add("measurement.type", .{ .string = "percentage" })
        .finish(allocator) catch |err| {
        std.log.err("Unable to build CPU Utilization attributes. {}", .{err});
        return;
    };

    result.observe(cpu_percent, attrs);
}

// Callback for observable up-down counter (stateful) - memory usage
fn memoryUsageCallback(allocator: std.mem.Allocator, result: *otel_api.metrics.ObservableResult(i64), state: *anyopaque) void {
    const memory_state: *MemoryState = @ptrCast(@alignCast(state));

    // Simulate memory fluctuations (can go up or down)
    const change = std.crypto.random.intRangeAtMost(i64, -50 * 1024 * 1024, 100 * 1024 * 1024); // -50MB to +100MB
    memory_state.base_used = @max(1024 * 1024 * 100, @min(memory_state.base_used + change, memory_state.base_total - 1024 * 1024 * 500)); // Keep within bounds

    const attrs = otel_api.common.AttributeBuilder.init(allocator)
        .add("server.name", .{ .string = "api-server-1" })
        .add("memory.type", .{ .string = "heap" })
        .add("unit", .{ .string = "bytes" })
        .finish(allocator) catch |err| {
        std.log.err("Unable to build memory usage attributes. {}", .{err});
        return;
    };

    result.observe(memory_state.base_used, attrs);
}

/// Example that sets up a very simple meter provider with a console exporter.
pub fn basicProcessorDemo(allocator: std.mem.Allocator) !void {
    const concrete_provider = try otel_sdk.metrics.setupGlobalProviderWithViews(
        allocator,
        .{otel_sdk.metrics.ManualReader.PipelineStep.init({})
            .flowTo(otel_exporters.otlp.OtlpMetricExporter.PipelineStep.init(.{}))},
        .{},
    );
    defer {
        concrete_provider.deinit();
        concrete_provider.destroy();
    }

    // Get a meter for our application
    const scope = try otel_api.InstrumentationScope.initSimple("dns.query.example", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    // Create a counter for counting requests
    const request_counter = try meter.createCounter(
        i64,
        "http.requests.total",
        "Total number of HTTP requests",
        "requests",
        null,
    );

    // Create an up-down counter for tracking active connections
    const connections_counter = try meter.createUpDownCounter(
        i64,
        "connections.active",
        "Number of active connections",
        "connections",
        null,
    );

    // Create a gauge for temperature readings
    const temperature_gauge = try meter.createGauge(
        f64,
        "room.temperature",
        "Current room temperature",
        "celsius",
        null,
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

    // Create observable instruments
    std.debug.print("\n=== Creating Observable Instruments ===\n", .{});

    // Observable counter for total requests served (stateful)
    var request_state = RequestState{ .start_time = std.time.timestamp() };
    const obs_counter = try meter.createObservableCounter(
        i64,
        "quic.server.total_requests",
        "Total number of requests served since server start",
        "requests",
        null,
        &[_]otel_api.metrics.TypeErasedCallback(i64){},
    );
    const counter_handle = try obs_counter.registerCallback(
        RequestState,
        totalRequestsCallback,
        &request_state,
    );
    defer counter_handle.unregister();
    std.debug.print("  ✓ Created observable counter: http.server.total_requests\n", .{});

    // Observable gauge for CPU utilization (stateless)
    const obs_gauge = try meter.createObservableGauge(
        f64,
        "system.cpu.utilization",
        "Current CPU utilization percentage",
        "percent",
        null,
        &[_]otel_api.metrics.TypeErasedCallback(f64){},
    );
    const gauge_handle = try obs_gauge.registerCallbackNoState(cpuUtilizationCallback);
    defer gauge_handle.unregister();
    std.debug.print("  ✓ Created observable gauge: system.cpu.utilization\n", .{});

    // Observable up-down counter for memory usage (stateful)
    var memory_state = MemoryState{};
    const obs_updown = try meter.createObservableUpDownCounter(
        i64,
        "process.runtime.memory_usage",
        "Current memory usage in bytes",
        "bytes",
        null,
        &[_]otel_api.metrics.TypeErasedCallback(i64){},
    );
    const updown_handle = try obs_updown.registerCallback(
        MemoryState,
        memoryUsageCallback,
        &memory_state,
    );
    defer updown_handle.unregister();
    std.debug.print("  ✓ Created observable up-down counter: process.memory.usage\n", .{});

    // Force flush to trigger export of collected metrics
    std.debug.print("\n=== Forcing Metrics Export ===\n", .{});
    const flush_result = concrete_provider.forceFlush(5000); // 5 second timeout
    if (flush_result == .success) {
        std.debug.print("✅ Metrics exported successfully!\n", .{});
    } else {
        std.debug.print("❌ Failed to export metrics\n", .{});
    }

    std.debug.print("\n=== Metrics Collection Complete ===\n", .{});

    std.debug.print("\nMetrics demo completed!\n", .{});
}

pub fn advancedProcessorDemo(allocator: std.mem.Allocator) !void {
    const concrete_provider = try otel_sdk.metrics.setupGlobalProviderWithViews(
        allocator,
        .{otel_sdk.metrics.PeriodicReader.PipelineStep.init(5000) // ms
            .flowTo(otel_exporters.otlp.OtlpMetricExporter.PipelineStep.init(.{}))},
        .{},
    );
    defer {
        concrete_provider.deinit();
        concrete_provider.destroy();
    }

    // Get a meter for our application
    const scope = try otel_api.InstrumentationScope.initSimple("periodic_metrics_demo", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    // Create various instruments
    const request_counter = try meter.createCounter(
        i64,
        "http.requests.total",
        "Total number of HTTP requests",
        "requests",
        null,
    );

    const active_connections = try meter.createUpDownCounter(
        i64,
        "connections.active",
        "Number of active connections",
        "connections",
        null,
    );

    const cpu_usage = try meter.createGauge(
        f64,
        "cpu.usage",
        "Current CPU usage percentage",
        "%",
        null,
    );

    const response_time = try meter.createHistogram(
        f64,
        "http.response_time",
        "HTTP response time",
        "ms",
        null,
    );

    const response_nonce = try meter.createHistogram(i64, "foo.bar.baz.thoughts", "random thoughts", "thought", null);

    std.log.info("Created instruments, starting metric recording...", .{});
    std.log.info("Metrics will be exported every 5 seconds by the background thread", .{});

    // Create observable instruments
    std.log.info("Creating observable instruments...", .{});

    // Observable counter for total requests served (stateful)
    var request_state = RequestState{ .start_time = std.time.timestamp() };
    const obs_counter = try meter.createObservableCounter(
        i64,
        "http.server.total_requests",
        "Total number of requests served since server start",
        "requests",
        null,
        &[_]otel_api.metrics.TypeErasedCallback(i64){},
    );
    const counter_handle = try obs_counter.registerCallback(
        RequestState,
        totalRequestsCallback,
        &request_state,
    );
    defer counter_handle.unregister();

    // Observable gauge for CPU utilization (stateless)
    const obs_gauge = try meter.createObservableGauge(
        f64,
        "system.cpu.utilization",
        "Current CPU utilization percentage",
        "percent",
        null,
        &[_]otel_api.metrics.TypeErasedCallback(f64){},
    );
    const gauge_handle = try obs_gauge.registerCallbackNoState(cpuUtilizationCallback);
    defer gauge_handle.unregister();

    // Observable up-down counter for memory usage (stateful)
    var memory_state = MemoryState{};
    const obs_updown = try meter.createObservableUpDownCounter(
        i64,
        "process.runtime.memory_usage",
        "Current memory usage in bytes",
        "bytes",
        null,
        &[_]otel_api.metrics.TypeErasedCallback(i64){},
    );
    const updown_handle = try obs_updown.registerCallback(
        MemoryState,
        memoryUsageCallback,
        &memory_state,
    );
    defer updown_handle.unregister();

    std.log.info("Observable instruments created and callbacks registered", .{});

    // Create a context for recording
    const ctx = otel_api.Context.empty(allocator);

    // Simulate activity for 5 minutes (300 seconds)
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
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

        const thoughts = 20 + @as(i64, std.crypto.random.intRangeAtMost(u32, 0, 2000));
        response_nonce.record(ctx, thoughts, &[_]otel_api.AttributeKeyValue{});

        std.log.info("Iteration {}: recorded metrics", .{i + 1});
        std.time.sleep(std.time.ns_per_s); // Sleep for 1 second
    }

    std.log.info("Demo completed. Shutting down...", .{});

    // Force a final flush before shutdown
    _ = concrete_provider.forceFlush(5000);

    std.log.info("Final flush completed. Exiting.", .{});
}
