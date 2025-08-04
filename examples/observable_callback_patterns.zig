//! Example demonstrating both callback patterns for observable instruments
//!
//! This example shows:
//! 1. Creation-time callbacks (MUST requirement from spec)
//! 2. Post-creation registration (SHOULD requirement from spec)
//! 3. Mixed approach (some callbacks at creation, some after)
//!
//! To run: zig build example-observable-callback-patterns

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

// Application state for callbacks
const AppMetrics = struct {
    request_count: std.atomic.Value(i64),
    cpu_usage: std.atomic.Value(f64),
    memory_usage: std.atomic.Value(i64),
    active_connections: std.atomic.Value(i64),

    pub fn init() AppMetrics {
        return AppMetrics{
            .request_count = std.atomic.Value(i64).init(0),
            .cpu_usage = std.atomic.Value(f64).init(0.0),
            .memory_usage = std.atomic.Value(i64).init(1024 * 1024 * 100), // 100MB
            .active_connections = std.atomic.Value(i64).init(0),
        };
    }

    pub fn incrementRequests(self: *AppMetrics) void {
        _ = self.request_count.fetchAdd(1, .monotonic);
    }

    pub fn updateCpuUsage(self: *AppMetrics, usage: f64) void {
        self.cpu_usage.store(usage, .monotonic);
    }

    pub fn updateMemoryUsage(self: *AppMetrics, usage: i64) void {
        self.memory_usage.store(usage, .monotonic);
    }

    pub fn changeConnections(self: *AppMetrics, delta: i64) void {
        _ = self.active_connections.fetchAdd(delta, .monotonic);
    }
};

// Callback functions for different instruments
fn requestCountCallback(result: *otel_api.metrics.ObservableResult(i64), state: *AppMetrics) void {
    const count = state.request_count.load(.monotonic);
    result.observeValue(count) catch |err| {
        std.log.err("Failed to observe request count: {}", .{err});
    };
}

fn cpuUsageCallback(result: *otel_api.metrics.ObservableResult(f64), state: *AppMetrics) void {
    const usage = state.cpu_usage.load(.monotonic);
    result.observeValue(usage) catch |err| {
        std.log.err("Failed to observe CPU usage: {}", .{err});
    };
}

fn memoryUsageCallback(result: *otel_api.metrics.ObservableResult(i64), state: *AppMetrics) void {
    const usage = state.memory_usage.load(.monotonic);
    result.observeValue(usage) catch |err| {
        std.log.err("Failed to observe memory usage: {}", .{err});
    };
}

fn connectionsCallback(result: *otel_api.metrics.ObservableResult(i64), state: *AppMetrics) void {
    const connections = state.active_connections.load(.monotonic);
    result.observeValue(connections) catch |err| {
        std.log.err("Failed to observe connections: {}", .{err});
    };
}

// Stateless callback example
fn systemUptimeCallback(result: *otel_api.metrics.ObservableResult(f64)) void {
    // Simulate uptime calculation
    const uptime = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0;
    result.observeValue(uptime) catch |err| {
        std.log.err("Failed to observe uptime: {}", .{err});
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 Observable Callback Patterns Example", .{});
    std.log.info("=====================================", .{});

    // Setup global metric provider
    const metric_provider = try otel_sdk.metrics.setupGlobalProvider(
        allocator,
        .{otel_sdk.metrics.BasicMetricReader.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleMetricExporter.PipelineStep.init(.{}))},
    );
    defer {
        metric_provider.deinit();
        metric_provider.destroy();
    }

    // Get a meter
    const scope = try otel_api.InstrumentationScope.initSimple("example.callback.patterns", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    // Initialize application state
    var app_metrics = AppMetrics.init();

    std.log.info("📊 Creating observable instruments with different callback patterns...", .{});

    // ========================================================================
    // PATTERN 1: Callbacks at Creation Time (MUST requirement)
    // ========================================================================
    std.log.info("\n🎯 Pattern 1: Creation-time callbacks", .{});

    // Create observable counter with callback at creation
    const request_counter = try meter.createObservableCounter(
        i64,
        "http.requests.total",
        "Total number of HTTP requests processed",
        "requests",
        null, // no advisory params
        &[_]otel_api.metrics.TypeErasedCallback{
            otel_api.metrics.createTypeErasedCallback(i64, AppMetrics, requestCountCallback, &app_metrics),
        },
    );
    std.log.info("✓ Created observable counter with creation-time callback: {s}", .{request_counter.getName()});

    // Create observable gauge with callback at creation
    const cpu_gauge = try meter.createObservableGauge(
        f64,
        "system.cpu.usage",
        "Current CPU usage percentage",
        "percent",
        null,
        &[_]otel_api.metrics.TypeErasedCallback{
            otel_api.metrics.createTypeErasedCallback(f64, AppMetrics, cpuUsageCallback, &app_metrics),
        },
    );
    std.log.info("✓ Created observable gauge with creation-time callback: {s}", .{cpu_gauge.getName()});

    // ========================================================================
    // PATTERN 2: Post-Creation Registration (SHOULD requirement)
    // ========================================================================
    std.log.info("\n🔧 Pattern 2: Post-creation registration", .{});

    // Create observable gauge without callbacks, register later
    var memory_gauge = try meter.createObservableGauge(
        i64,
        "system.memory.usage",
        "Current memory usage in bytes",
        "bytes",
        null,
        &[_]otel_api.metrics.TypeErasedCallback{}, // empty callbacks at creation
    );
    std.log.info("✓ Created observable gauge without callbacks: {s}", .{memory_gauge.getName()});

    // Register callback after creation
    const memory_handle = try memory_gauge.registerCallback(AppMetrics, memoryUsageCallback, &app_metrics);
    std.log.info("✓ Registered callback for memory gauge", .{});

    // ========================================================================
    // PATTERN 3: Mixed Approach
    // ========================================================================
    std.log.info("\n🔀 Pattern 3: Mixed approach", .{});

    // Create with one callback at creation, add more later
    var connections_counter = try meter.createObservableUpDownCounter(
        i64,
        "system.connections.active",
        "Number of active connections",
        "connections",
        null,
        &[_]otel_api.metrics.TypeErasedCallback{
            otel_api.metrics.createTypeErasedCallback(i64, AppMetrics, connectionsCallback, &app_metrics),
        },
    );
    std.log.info("✓ Created observable up-down counter with initial callback: {s}", .{connections_counter.getName()});

    // Create another instrument with no callbacks, add stateless callback later
    var uptime_gauge = try meter.createObservableGauge(
        f64,
        "system.uptime",
        "System uptime in seconds",
        "seconds",
        null,
        &[_]otel_api.metrics.TypeErasedCallback{}, // empty at creation
    );
    const uptime_handle = try uptime_gauge.registerCallbackNoState(systemUptimeCallback);
    std.log.info("✓ Created uptime gauge and registered stateless callback: {s}", .{uptime_gauge.getName()});

    // ========================================================================
    // Simulate Application Activity
    // ========================================================================
    std.log.info("\n🏃‍♂️ Simulating application activity...", .{});

    for (0..10) |i| {
        std.log.info("📈 Iteration {}", .{i + 1});

        // Simulate some requests
        const requests_this_iteration = (i % 5) + 1;
        for (0..requests_this_iteration) |_| {
            app_metrics.incrementRequests();
        }

        // Update CPU usage (simulate varying load)
        const cpu_usage = 20.0 + @as(f64, @floatFromInt(i * 5)) + (@as(f64, @floatFromInt(@rem(std.time.milliTimestamp(), 100))) / 10.0);
        app_metrics.updateCpuUsage(cpu_usage);

        // Update memory usage (simulate memory growth/cleanup)
        const base_memory: i64 = 1024 * 1024 * 100; // 100MB base
        const variable_part: i64 = @intCast(@rem(std.time.milliTimestamp(), (1024 * 1024 * 50)));
        const variable_memory: i64 = @as(i64, @intCast(i)) * 1024 * 1024 * 10 + variable_part;
        app_metrics.updateMemoryUsage(base_memory + variable_memory);

        // Simulate connection changes
        if (i % 3 == 0) {
            app_metrics.changeConnections(2); // Add connections
            std.log.info("  📞 +2 connections", .{});
        } else if (i % 4 == 0) {
            app_metrics.changeConnections(-1); // Remove connection
            std.log.info("  📞 -1 connection", .{});
        }

        // Wait between iterations
        std.time.sleep(500_000_000); // 500ms

        // Force metric collection every few iterations
        if (i % 3 == 2) {
            std.log.info("  📊 Forcing metric collection...", .{});
            // Note: In a real app, this would trigger metric reader collection
            std.time.sleep(100_000_000); // 100ms for collection
        }
    }

    // ========================================================================
    // Demonstrate Callback Unregistration
    // ========================================================================
    std.log.info("\n🔓 Demonstrating callback unregistration...", .{});

    // Unregister the memory callback
    memory_handle.unregister();
    std.log.info("✓ Unregistered memory gauge callback", .{});

    // Unregister the uptime callback
    uptime_handle.unregister();
    std.log.info("✓ Unregistered uptime gauge callback", .{});

    // Final metrics collection after unregistration
    std.log.info("\n📊 Final metrics collection (some callbacks unregistered)...", .{});
    std.time.sleep(1_000_000_000); // 1 second

    // ========================================================================
    // Summary
    // ========================================================================
    std.log.info("\n📋 Summary of callback patterns demonstrated:", .{});
    std.log.info("", .{});
    std.log.info("  ✅ PATTERN 1: Creation-time callbacks (MUST requirement)", .{});
    std.log.info("    - Observable counter with callback at creation", .{});
    std.log.info("    - Observable gauge with callback at creation", .{});
    std.log.info("", .{});
    std.log.info("  ✅ PATTERN 2: Post-creation registration (SHOULD requirement)", .{});
    std.log.info("    - Observable gauge created without callbacks", .{});
    std.log.info("    - Callback registered after creation", .{});
    std.log.info("    - Callback unregistered during runtime", .{});
    std.log.info("", .{});
    std.log.info("  ✅ PATTERN 3: Mixed approach", .{});
    std.log.info("    - Observable up-down counter with initial callback", .{});
    std.log.info("    - Stateless callback registration", .{});
    std.log.info("    - Runtime callback management", .{});
    std.log.info("", .{});
    std.log.info("🎉 All OpenTelemetry specification requirements demonstrated!", .{});

    // Final cleanup will happen via defer statements
}
