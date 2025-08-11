//! Observable Metrics Demo
//!
//! This example demonstrates the basic usage of observable/async instruments in OpenTelemetry.
//! Observable instruments use callbacks to collect measurements at collection time,
//! which is ideal for metrics that represent current state rather than events.
//!
//! Run with: zig build example-observable-metrics

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

// System metrics simulation
const SystemMetrics = struct {
    memory_usage_bytes: i64 = 256 * 1024 * 1024, // 256MB
    cpu_usage_percent: f64 = 25.5,
    disk_free_bytes: i64 = 50 * 1024 * 1024 * 1024, // 50GB

    pub fn update(self: *SystemMetrics) void {
        // Simulate changing values
        const time_ms = std.time.milliTimestamp();

        // Memory fluctuates
        self.memory_usage_bytes += (@mod(time_ms, 1000) - 500) * 1024;
        if (self.memory_usage_bytes < 100 * 1024 * 1024) {
            self.memory_usage_bytes = 100 * 1024 * 1024; // Min 100MB
        }

        // CPU varies between 10-90%
        self.cpu_usage_percent = 10.0 + @mod(@as(f64, @floatFromInt(@abs(time_ms))), 80.0);

        // Disk free decreases slowly
        self.disk_free_bytes -= @mod(time_ms, 1024 * 1024);
        if (self.disk_free_bytes < 1024 * 1024 * 1024) {
            self.disk_free_bytes = 50 * 1024 * 1024 * 1024; // Reset to 50GB
        }
    }
};

var system_metrics = SystemMetrics{};

// Callback functions for observable instruments
fn memoryCallback(result: *otel_api.metrics.ObservableResult(i64), state: *SystemMetrics) void {
    const attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "component", .value = .{ .string = "system" } },
    };
    result.observe(state.memory_usage_bytes, &attrs, null) catch |err| {
        std.log.err("Failed to observe memory: {}", .{err});
    };
}

fn cpuCallback(result: *otel_api.metrics.ObservableResult(f64), state: *SystemMetrics) void {
    result.observeValue(state.cpu_usage_percent) catch |err| {
        std.log.err("Failed to observe CPU: {}", .{err});
    };
}

fn diskCallback(result: *otel_api.metrics.ObservableResult(i64), state: *SystemMetrics) void {
    // Multiple measurements from one callback
    const root_attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "mount", .value = .{ .string = "/" } },
    };
    const home_attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "mount", .value = .{ .string = "/home" } },
    };

    result.observe(state.disk_free_bytes, &root_attrs, null) catch {};
    result.observe(@divTrunc(state.disk_free_bytes, 2), &home_attrs, null) catch {};
}

// Stateless callback
fn uptimeCallback(result: *otel_api.metrics.ObservableResult(f64)) void {
    const uptime_hours = @as(f64, @floatFromInt(std.time.milliTimestamp())) / (1000.0 * 60.0 * 60.0);
    result.observeValue(@mod(uptime_hours, 24.0)) catch {}; // Reset daily for demo
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== OpenTelemetry Observable Instruments Demo ===", .{});

    std.log.info("Creating observable instruments using SDK directly...", .{});

    // Create observable instruments directly using SDK implementation
    // This bypasses the meter provider and uses the SDK types directly
    const async_config = otel_sdk.metrics.AsyncInstrumentConfig.default();

    var memory_gauge = otel_sdk.metrics.SdkObservableGauge(i64).init(
        allocator,
        "system.memory.usage",
        "System memory usage",
        "bytes",
        async_config,
    );
    defer memory_gauge.deinit();

    var cpu_gauge = otel_sdk.metrics.SdkObservableGauge(f64).init(
        allocator,
        "system.cpu.usage",
        "CPU usage",
        "percent",
        async_config,
    );
    defer cpu_gauge.deinit();

    var disk_gauge = otel_sdk.metrics.SdkObservableGauge(i64).init(
        allocator,
        "system.disk.free",
        "Free disk space",
        "bytes",
        async_config,
    );
    defer disk_gauge.deinit();

    var uptime_gauge = otel_sdk.metrics.SdkObservableGauge(f64).init(
        allocator,
        "system.uptime",
        "System uptime",
        "hours",
        async_config,
    );
    defer uptime_gauge.deinit();

    std.log.info("Registering callbacks...", .{});

    // Create type-erased callbacks and register them
    const memory_callback = otel_api.metrics.createTypeErasedCallback(i64, SystemMetrics, memoryCallback, &system_metrics);
    const memory_handle = memory_gauge.registerCallback(memory_callback);
    defer memory_handle.unregister();

    const cpu_callback_erased = otel_api.metrics.createTypeErasedCallback(f64, SystemMetrics, cpuCallback, &system_metrics);
    const cpu_handle = cpu_gauge.registerCallback(cpu_callback_erased);
    defer cpu_handle.unregister();

    const disk_callback_erased = otel_api.metrics.createTypeErasedCallback(i64, SystemMetrics, diskCallback, &system_metrics);
    const disk_handle = disk_gauge.registerCallback(disk_callback_erased);
    defer disk_handle.unregister();

    const uptime_callback_erased = otel_api.metrics.TypeErasedCallback(f64){ .stateless = .{ .callback_fn = uptimeCallback } };
    const uptime_handle = uptime_gauge.registerCallback(uptime_callback_erased);
    defer uptime_handle.unregister();

    std.log.info("Starting metric collection simulation...", .{});

    // Simulate several collection cycles
    for (0..5) |cycle| {
        std.log.info("\n--- Collection Cycle {} ---", .{cycle + 1});

        // Update system state
        system_metrics.update();

        std.log.info("Current system state:", .{});
        std.log.info("  Memory: {d:.1} MB", .{@as(f64, @floatFromInt(system_metrics.memory_usage_bytes)) / (1024.0 * 1024.0)});
        std.log.info("  CPU: {d:.1}%", .{system_metrics.cpu_usage_percent});
        std.log.info("  Disk Free: {d:.1} GB", .{@as(f64, @floatFromInt(system_metrics.disk_free_bytes)) / (1024.0 * 1024.0 * 1024.0)});

        // Collect metrics from each instrument
        var total_data_points: usize = 0;

        // Collect from memory gauge
        const memory_data = try memory_gauge.collect(allocator);
        defer allocator.free(memory_data);
        std.log.info("  📊 Memory gauge: {} measurements", .{memory_data.len});
        for (memory_data) |point| {
            const memory_value = switch (point.value) {
                .i64_gauge => |v| v,
                .i64_sum => |v| v,
                else => 0,
            };
            std.log.info("    Memory: {} bytes", .{memory_value});
        }
        total_data_points += memory_data.len;

        // Collect from CPU gauge
        const cpu_data = try cpu_gauge.collect(allocator);
        defer allocator.free(cpu_data);
        std.log.info("  📊 CPU gauge: {} measurements", .{cpu_data.len});
        for (cpu_data) |point| {
            const cpu_value = switch (point.value) {
                .f64_gauge => |v| v,
                .f64_sum => |v| v,
                else => 0.0,
            };
            std.log.info("    CPU: {d:.1}%", .{cpu_value});
        }
        total_data_points += cpu_data.len;

        // Collect from disk gauge
        const disk_data = try disk_gauge.collect(allocator);
        defer allocator.free(disk_data);
        std.log.info("  📊 Disk gauge: {} measurements", .{disk_data.len});
        for (disk_data) |point| {
            const disk_value = switch (point.value) {
                .i64_gauge => |v| v,
                .i64_sum => |v| v,
                else => 0,
            };
            const gb = @as(f64, @floatFromInt(disk_value)) / (1024.0 * 1024.0 * 1024.0);
            std.log.info("    Disk free: {d:.1} GB", .{gb});
        }
        total_data_points += disk_data.len;

        // Collect from uptime gauge
        const uptime_data = try uptime_gauge.collect(allocator);
        defer allocator.free(uptime_data);
        std.log.info("  📊 Uptime gauge: {} measurements", .{uptime_data.len});
        for (uptime_data) |point| {
            const uptime_value = switch (point.value) {
                .f64_gauge => |v| v,
                .f64_sum => |v| v,
                else => 0.0,
            };
            std.log.info("    Uptime: {d:.1} hours", .{uptime_value});
        }
        total_data_points += uptime_data.len;

        std.log.info("Total data points collected: {}", .{total_data_points});

        // Wait between collections
        std.time.sleep(500 * std.time.ns_per_ms);
    }

    std.log.info("\n=== Demo Complete ===", .{});
    std.log.info("Observable instruments demonstrated:", .{});
    std.log.info("  ✓ Stateful callbacks with custom state", .{});
    std.log.info("  ✓ Stateless callbacks", .{});
    std.log.info("  ✓ Multiple measurements per callback", .{});
    std.log.info("  ✓ Attributes on measurements", .{});
    std.log.info("  ✓ Automatic callback execution during collection", .{});
    std.log.info("  ✓ Proper callback handle management", .{});
}
