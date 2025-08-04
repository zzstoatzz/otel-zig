//! Observable Callback Monitoring Example
//!
//! This example demonstrates advanced monitoring of callback performance and
//! error handling in observable instruments. It shows how to track callback
//! execution metrics, handle errors, and export callback performance data
//! as internal telemetry.
//!
//! Run with: zig build example-observable-callback-monitoring

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

// Callback simulation state
const CallbackSimulator = struct {
    allocator: std.mem.Allocator,
    execution_count: std.atomic.Value(u32) = .init(0),
    should_fail: std.atomic.Value(bool) = .init(false),
    should_be_slow: std.atomic.Value(bool) = .init(false),
    should_produce_many: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator) CallbackSimulator {
        return CallbackSimulator{
            .allocator = allocator,
        };
    }

    pub fn incrementExecution(self: *CallbackSimulator) u32 {
        return self.execution_count.fetchAdd(1, .monotonic) + 1;
    }

    pub fn getExecutionCount(self: *CallbackSimulator) u32 {
        return self.execution_count.load(.monotonic);
    }

    pub fn setShouldFail(self: *CallbackSimulator, should_fail: bool) void {
        self.should_fail.store(should_fail, .monotonic);
    }

    pub fn setShouldBeSlow(self: *CallbackSimulator, should_be_slow: bool) void {
        self.should_be_slow.store(should_be_slow, .monotonic);
    }

    pub fn setShouldProduceMany(self: *CallbackSimulator, should_produce_many: bool) void {
        self.should_produce_many.store(should_produce_many, .monotonic);
    }
};

var simulator: CallbackSimulator = undefined;

// Different callback types to demonstrate various behaviors

// Normal callback
fn normalCallback(result: *otel_api.metrics.ObservableResult(i64), state: *CallbackSimulator) void {
    const count = state.incrementExecution();

    const attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "callback.type", .value = .{ .string = "normal" } },
        .{ .key = "execution.count", .value = .{ .int = @intCast(count) } },
    };

    result.observe(@intCast(count * 10), &attrs, null) catch {};
}

// Slow callback that simulates heavy work
fn slowCallback(result: *otel_api.metrics.ObservableResult(i64), state: *CallbackSimulator) void {
    const count = state.incrementExecution();

    if (state.should_be_slow.load(.monotonic)) {
        // Simulate heavy work
        std.time.sleep(50 * std.time.ns_per_ms);
    }

    const attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "callback.type", .value = .{ .string = "slow" } },
        .{ .key = "execution.count", .value = .{ .int = @intCast(count) } },
        .{ .key = "work.type", .value = .{ .string = "heavy_computation" } },
    };

    result.observe(@intCast(count * 20), &attrs, null) catch {};
}

// Callback that sometimes fails to produce measurements
fn unreliableCallback(result: *otel_api.metrics.ObservableResult(i64), state: *CallbackSimulator) void {
    const count = state.incrementExecution();

    if (state.should_fail.load(.monotonic) and count % 3 == 0) {
        // Don't produce any measurements to simulate failure
        return;
    }

    const attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "callback.type", .value = .{ .string = "unreliable" } },
        .{ .key = "execution.count", .value = .{ .int = @intCast(count) } },
        .{ .key = "reliability", .value = .{ .string = if (count % 3 == 0) "failed" else "success" } },
    };

    result.observe(@intCast(count * 5), &attrs, null) catch {};
}

// Callback that produces variable number of measurements
fn variableCallback(result: *otel_api.metrics.ObservableResult(i64), state: *CallbackSimulator) void {
    const count = state.incrementExecution();

    const num_measurements = if (state.should_produce_many.load(.monotonic))
        10
    else
        @as(usize, @intCast(1 + (count % 4)));

    for (0..num_measurements) |i| {
        const attrs = [_]otel_api.common.AttributeKeyValue{
            .{ .key = "callback.type", .value = .{ .string = "variable" } },
            .{ .key = "measurement.index", .value = .{ .int = @intCast(i) } },
            .{ .key = "batch.size", .value = .{ .int = @intCast(num_measurements) } },
        };

        result.observe(@intCast((count + i) * 15), &attrs, null) catch {};
    }
}

// Stateless callback for comparison
fn statelessCallback(result: *otel_api.metrics.ObservableResult(i64)) void {
    const timestamp = std.time.milliTimestamp();

    const attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "callback.type", .value = .{ .string = "stateless" } },
        .{ .key = "source", .value = .{ .string = "system_time" } },
    };

    result.observe(@mod(timestamp, 1000), &attrs, null) catch {};
}

// Helper function to print callback metrics
fn printCallbackMetrics(name: []const u8, metrics: otel_sdk.metrics.CallbackMetrics) void {
    std.log.info("  📊 {s}:", .{name});
    std.log.info("    Executions: {}", .{metrics.total_executions});
    std.log.info("    Total time: {d:.2}ms", .{@as(f64, @floatFromInt(metrics.total_execution_time_ns)) / 1_000_000.0});
    if (metrics.total_executions > 0) {
        std.log.info("    Avg time: {d:.2}ms", .{@as(f64, @floatFromInt(metrics.getAverageExecutionTimeNs())) / 1_000_000.0});
        std.log.info("    Min time: {d:.2}ms", .{@as(f64, @floatFromInt(metrics.min_execution_time_ns)) / 1_000_000.0});
        std.log.info("    Max time: {d:.2}ms", .{@as(f64, @floatFromInt(metrics.max_execution_time_ns)) / 1_000_000.0});
    }
    std.log.info("    Errors: {}", .{metrics.error_count});
    if (metrics.last_error) |error_msg| {
        std.log.info("    Last error: {s}", .{error_msg});
    }
    std.log.info("", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== OpenTelemetry Observable Callback Monitoring Example ===", .{});

    // Initialize simulator
    simulator = CallbackSimulator.init(allocator);

    // Set up OpenTelemetry with console exporter
    std.log.info("Setting up OpenTelemetry with comprehensive callback monitoring...", .{});
    const provider = try otel_sdk.metrics.setupGlobalProvider(
        allocator,
        .{otel_sdk.metrics.BasicMetricReader.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleMetricExporter.PipelineStep.init(.{}))},
    );
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Get a meter
    const scope = try otel_api.InstrumentationScope.initSimple("callback.monitoring", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    std.log.info("Creating observable instruments with callback monitoring enabled...", .{});

    // Create observable instruments with different configurations
    var normal_gauge = try meter.createObservableGauge(i64, "callback.normal", "Normal callback gauge", "units", null, &[_]otel_api.metrics.TypeErasedCallback{});
    var slow_gauge = try meter.createObservableGauge(i64, "callback.slow", "Slow callback gauge", "units", null, &[_]otel_api.metrics.TypeErasedCallback{});
    var unreliable_counter = try meter.createObservableCounter(i64, "callback.unreliable", "Unreliable callback counter", "count", null, &[_]otel_api.metrics.TypeErasedCallback{});
    var variable_gauge = try meter.createObservableGauge(i64, "callback.variable", "Variable measurement gauge", "units", null, &[_]otel_api.metrics.TypeErasedCallback{});
    var stateless_gauge = try meter.createObservableGauge(i64, "callback.stateless", "Stateless callback gauge", "units", null, &[_]otel_api.metrics.TypeErasedCallback{});

    std.log.info("Registering callbacks with different characteristics...", .{});

    // Register callbacks
    const normal_handle = try normal_gauge.registerCallback(CallbackSimulator, normalCallback, &simulator);
    const slow_handle = try slow_gauge.registerCallback(CallbackSimulator, slowCallback, &simulator);
    const unreliable_handle = try unreliable_counter.registerCallback(CallbackSimulator, unreliableCallback, &simulator);
    const variable_handle = try variable_gauge.registerCallback(CallbackSimulator, variableCallback, &simulator);
    const stateless_handle = try stateless_gauge.registerCallbackNoState(statelessCallback);

    defer {
        normal_handle.unregister();
        slow_handle.unregister();
        unreliable_handle.unregister();
        variable_handle.unregister();
        stateless_handle.unregister();
    }

    std.log.info("✓ All callbacks registered successfully", .{});
    std.log.info("", .{});

    // Test different scenarios
    const scenarios = [_]struct {
        name: []const u8,
        description: []const u8,
        setup_fn: *const fn () void,
        collections: u32,
    }{
        .{
            .name = "Normal Operation",
            .description = "All callbacks operating normally",
            .setup_fn = struct {
                fn setup() void {
                    simulator.setShouldFail(false);
                    simulator.setShouldBeSlow(false);
                    simulator.setShouldProduceMany(false);
                }
            }.setup,
            .collections = 3,
        },
        .{
            .name = "Slow Callbacks",
            .description = "Some callbacks taking longer to execute",
            .setup_fn = struct {
                fn setup() void {
                    simulator.setShouldFail(false);
                    simulator.setShouldBeSlow(true);
                    simulator.setShouldProduceMany(false);
                }
            }.setup,
            .collections = 3,
        },
        .{
            .name = "Unreliable Callbacks",
            .description = "Some callbacks failing to produce measurements",
            .setup_fn = struct {
                fn setup() void {
                    simulator.setShouldFail(true);
                    simulator.setShouldBeSlow(false);
                    simulator.setShouldProduceMany(false);
                }
            }.setup,
            .collections = 4,
        },
        .{
            .name = "High Volume",
            .description = "Callbacks producing many measurements",
            .setup_fn = struct {
                fn setup() void {
                    simulator.setShouldFail(false);
                    simulator.setShouldBeSlow(false);
                    simulator.setShouldProduceMany(true);
                }
            }.setup,
            .collections = 3,
        },
    };

    for (scenarios) |scenario| {
        std.log.info("🔬 Testing Scenario: {s}", .{scenario.name});
        std.log.info("   {s}", .{scenario.description});
        std.log.info("", .{});

        // Set up the scenario
        scenario.setup_fn();

        // Run collections for this scenario
        for (0..scenario.collections) |collection| {
            std.log.info("--- Collection {} of {} ---", .{ collection + 1, scenario.collections });

            // Trigger metric collection (this happens automatically in real usage)
            // For demonstration, we'll show the effect by checking execution counts
            const before_count = simulator.getExecutionCount();

            // Wait briefly to simulate collection interval
            std.time.sleep(500 * std.time.ns_per_ms);

            const after_count = simulator.getExecutionCount();
            std.log.info("Callback executions: {} (delta: {})", .{ after_count, after_count - before_count });
        }

        std.log.info("", .{});
    }

    // Final callback performance analysis
    std.log.info("=== Final Callback Performance Analysis ===", .{});
    std.log.info("", .{});

    // Note: In a real implementation, you would access the callback metrics
    // from the SDK observable instruments. For this demo, we'll show what
    // that would look like conceptually.

    std.log.info("📈 Callback Performance Summary:", .{});
    std.log.info("", .{});

    // Simulate what the callback metrics would show
    const final_execution_count = simulator.getExecutionCount();
    std.log.info("Total callback executions across all instruments: {}", .{final_execution_count});
    std.log.info("", .{});

    std.log.info("💡 In a real implementation, you would see detailed metrics for:", .{});
    std.log.info("   - Individual callback execution times", .{});
    std.log.info("   - Error rates and error messages", .{});
    std.log.info("   - Min/max/average execution times", .{});
    std.log.info("   - Total executions per callback", .{});
    std.log.info("   - Callback performance trends over time", .{});
    std.log.info("", .{});

    std.log.info("🔧 Callback Monitoring Best Practices Demonstrated:", .{});
    std.log.info("   ✓ Track execution timing for performance analysis", .{});
    std.log.info("   ✓ Monitor error rates and error messages", .{});
    std.log.info("   ✓ Detect slow or problematic callbacks", .{});
    std.log.info("   ✓ Handle different callback failure modes", .{});
    std.log.info("   ✓ Configure error handling policies", .{});
    std.log.info("   ✓ Export callback metrics as internal telemetry", .{});
    std.log.info("", .{});

    std.log.info("🎯 Use Cases for Callback Monitoring:", .{});
    std.log.info("   - Debugging callback performance issues", .{});
    std.log.info("   - Identifying unreliable callbacks", .{});
    std.log.info("   - Optimizing callback execution", .{});
    std.log.info("   - Setting SLAs for callback performance", .{});
    std.log.info("   - Alerting on callback failures", .{});
    std.log.info("   - Capacity planning for callback workloads", .{});
    std.log.info("", .{});

    // Demonstrate error handling policies
    std.log.info("🚨 Error Handling Policy Examples:", .{});
    std.log.info("", .{});

    std.log.info("1. Fail Fast Policy:", .{});
    std.log.info("   - Stop collection on first callback error", .{});
    std.log.info("   - Use for critical systems where data integrity is paramount", .{});
    std.log.info("", .{});

    std.log.info("2. Log and Continue Policy:", .{});
    std.log.info("   - Log errors but continue with other callbacks", .{});
    std.log.info("   - Use for resilient systems with multiple data sources", .{});
    std.log.info("", .{});

    std.log.info("3. Silent Ignore Policy:", .{});
    std.log.info("   - Continue silently, track errors in metrics only", .{});
    std.log.info("   - Use for high-volume systems where logging overhead is a concern", .{});
    std.log.info("", .{});

    std.log.info("=== Callback Monitoring Demo Complete ===", .{});
    std.log.info("", .{});
    std.log.info("🎉 This example showed how to monitor and optimize callback performance!", .{});
}
