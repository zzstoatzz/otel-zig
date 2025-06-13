//! Example demonstrating OpenTelemetry histogram usage
//!
//! This example shows how to use histograms to track the distribution
//! of values, such as request latencies or response sizes.

const std = @import("std");
const otel = @import("otel");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create a console exporter for metrics
    var console_exporter = otel.exporters.console.ConsoleMetricExporter.init(allocator, .{});
    const exporter = otel.sdk.metrics.MetricExporter{
        .bridge = otel.sdk.metrics.BridgeMetricExporter.init(&console_exporter),
    };

    // Set up metrics with simple synchronous configuration
    var meter_provider = try otel.sdk.metrics.createSimpleSyncMetrics(
        allocator,
        "histogram-example",
        exporter,
    );

    // Set as global provider
    _ = otel.api.provider_registry.setGlobalMeterProvider(&meter_provider);

    // Get a meter
    const scope = try otel.api.InstrumentationScope.initSimple("example.histogram", "1.0.0");
    var meter = try meter_provider.getMeterWithScope(scope);

    // Create a histogram to track request latencies
    const latency_histogram = try meter.createHistogram(
        f64,
        "http.request.duration",
        "Duration of HTTP requests",
        "ms",
    );

    // Create a histogram to track response sizes
    const size_histogram = try meter.createHistogram(
        i64,
        "http.response.size",
        "Size of HTTP responses",
        "bytes",
    );

    const ctx = otel.api.Context.empty(allocator);

    // Simulate recording some request latencies (in milliseconds)
    const latencies = [_]f64{
        2.5,   4.3,  12.7,  8.9, 45.2, 3.1,  7.8,   15.3,
        125.6, 89.4, 234.5, 5.6, 9.2,  18.7, 156.3, 302.1,
        67.8,  23.4, 11.2,  6.7, 95.3, 42.1,
    };

    std.debug.print("Recording request latencies...\n", .{});
    for (latencies) |latency| {
        latency_histogram.record(ctx, latency, &[_]otel.api.AttributeKeyValue{});
    }

    // Simulate recording some response sizes (in bytes)
    const sizes = [_]i64{
        1024,  2048,  512, 8192, 16384, 256,  4096,
        32768, 65536, 128, 1536, 3072,  6144, 12288,
    };

    std.debug.print("Recording response sizes...\n", .{});
    for (sizes) |size| {
        size_histogram.record(ctx, @intCast(size), &[_]otel.api.AttributeKeyValue{});
    }

    // In a real application, the metrics would be exported periodically by the configured exporter
    // For this example, we'll force a flush to ensure metrics are processed
    std.debug.print("\n--- Flushing Metrics ---\n", .{});
    _ = meter_provider.forceFlush(5000);

    std.debug.print("\n--- Summary Statistics (Application-side) ---\n", .{});

    // Calculate some statistics from the recorded values
    var latency_sum: f64 = 0;
    var latency_min: f64 = latencies[0];
    var latency_max: f64 = latencies[0];

    for (latencies) |latency| {
        latency_sum += latency;
        latency_min = @min(latency_min, latency);
        latency_max = @max(latency_max, latency);
    }

    const latency_avg = latency_sum / @as(f64, @floatFromInt(latencies.len));

    std.debug.print("Request Latencies:\n", .{});
    std.debug.print("  Count: {d}\n", .{latencies.len});
    std.debug.print("  Min: {d:.2} ms\n", .{latency_min});
    std.debug.print("  Max: {d:.2} ms\n", .{latency_max});
    std.debug.print("  Average: {d:.2} ms\n", .{latency_avg});

    var size_sum: i64 = 0;
    var size_min: i64 = sizes[0];
    var size_max: i64 = sizes[0];

    for (sizes) |size| {
        size_sum += size;
        size_min = @min(size_min, size);
        size_max = @max(size_max, size);
    }

    const size_avg = @divTrunc(size_sum, @as(i64, @intCast(sizes.len)));

    std.debug.print("\nResponse Sizes:\n", .{});
    std.debug.print("  Count: {d}\n", .{sizes.len});
    std.debug.print("  Min: {d} bytes\n", .{size_min});
    std.debug.print("  Max: {d} bytes\n", .{size_max});
    std.debug.print("  Average: {d} bytes\n", .{size_avg});

    std.debug.print("\n=== Metrics Collection Complete ===\n", .{});
    std.debug.print("The histogram data has been recorded and would be exported by the configured exporter.\n", .{});
    std.debug.print("With the console exporter, metrics are displayed when flushed.\n", .{});
}
