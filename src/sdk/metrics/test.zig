const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const ManualReader = @import("manual_reader.zig").ManualReader;
    const Meter = @import("meter.zig").Meter;
    const MeterProvider = @import("meter_provider.zig").MeterProvider;
    const MetricData = @import("data.zig").MetricData;
    const MetricType = @import("data.zig").MetricType;
    const MetricDataPoint = @import("data.zig").MetricDataPoint;
    const PeriodicReader = @import("periodic_reader.zig").PeriodicReader;
    const Resource = @import("../resource/resource.zig").Resource;
    const aggregations = @import("aggregations.zig");
};

// Import test dependencies
const MockMetricExporter = @import("exporter.zig").MockMetricExporter;

// Helper function to cleanup MetricData memory
fn cleanupMetrics(allocator: std.mem.Allocator, metrics: []sdk.MetricData) void {
    for (metrics) |metric| {
        // Free histogram bucket_counts if present (must do this before freeing data_points)
        for (metric.data_points) |data_point| {
            switch (data_point.value) {
                .i64_histogram => |hist| allocator.free(hist.bucket_counts),
                .f64_histogram => |hist| allocator.free(hist.bucket_counts),
                else => {},
            }
        }

        // Free data_points array
        allocator.free(metric.data_points);
    }
    allocator.free(metrics);
}

test "BasicMeterProvider lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create resource
    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, resource);
    defer provider.deinit();

    try testing.expect(provider.readers.items.len == 0);
    try testing.expect(provider.cache.count() == 0);
}

test "BasicMeterProvider meter caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, resource);
    defer provider.deinit();

    const scope1 = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    const scope2 = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" }; // Same
    const scope3 = api.InstrumentationScope{ .name = "other.meter", .version = "1.0.0" }; // Different

    const meter1 = try provider.getMeterWithScope(scope1);
    const meter2 = try provider.getMeterWithScope(scope2);
    const meter3 = try provider.getMeterWithScope(scope3);

    // Same scope should return same meter instance
    try testing.expect(meter1.bridge.meter_ptr == meter2.bridge.meter_ptr);
    try testing.expect(meter1.bridge.meter_ptr != meter3.bridge.meter_ptr);

    // Verify cache contains 2 unique entries
    try testing.expectEqual(@as(u32, 2), provider.cache.count());
}

test "BasicMeterProvider processor registration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, resource);
    defer provider.deinit();

    try @import("../common/pipeline.zig").PipelineBuilder(*sdk.MeterProvider).init(&provider)
        .with(sdk.ManualReader.PipelineStep.init({}).flowTo(MockMetricExporter.PipelineStep.init({})))
        .done();

    try testing.expectEqual(@as(usize, 1), provider.readers.items.len);
}

test "BasicMeter instrument creation and data collection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, resource);
    defer provider.deinit();

    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create various instrument types
    const counter_i64 = try meter.createCounter(i64, "test.counter.i64", "Test counter", "requests", null);
    const counter_f64 = try meter.createCounter(f64, "test.counter.f64", "Test counter", "seconds", null);
    const updown_i64 = try meter.createUpDownCounter(i64, "test.updown.i64", "Test updown", "connections", null);
    const gauge_i64 = try meter.createGauge(i64, "test.gauge.i64", "Test gauge", "bytes", null);
    const histogram_f64 = try meter.createHistogram(f64, "test.histogram.f64", "Test histogram", "ms", null);

    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    // Record some measurements
    counter_i64.add(ctx, 10, &empty_attributes);
    counter_i64.add(ctx, 5, &empty_attributes);
    counter_f64.add(ctx, 3.14, &empty_attributes);
    updown_i64.add(ctx, 5, &empty_attributes);
    updown_i64.add(ctx, -2, &empty_attributes);
    gauge_i64.record(ctx, 42, &empty_attributes);
    histogram_f64.record(ctx, 15.5, &empty_attributes);
    histogram_f64.record(ctx, 25.0, &empty_attributes);

    // Note: provider has no configured readers, so this is mostly a dead-end test.
}

test "BasicMeter data collection through processor pipeline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, resource);
    defer provider.deinit();

    // Create mock exporter
    const mock_exporter = try allocator.create(MockMetricExporter);
    mock_exporter.* = MockMetricExporter.init(allocator);
    // Processor takes ownership of this memory

    // Create processor (heap-allocated)
    const reader = try allocator.create(sdk.ManualReader);
    reader.* = try sdk.ManualReader.init(allocator, mock_exporter.metricExporter());

    // Register reader (provider takes ownership)
    try provider.registerReader(reader.reader());

    // Get meter
    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create instruments and record data
    const counter = try meter.createCounter(i64, "http.requests", "HTTP requests", "requests", null);
    const histogram = try meter.createHistogram(f64, "http.duration", "HTTP duration", "ms", null);

    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    counter.add(ctx, 5, &empty_attributes);
    counter.add(ctx, 3, &empty_attributes);
    histogram.record(ctx, 12.5, &empty_attributes);
    histogram.record(ctx, 25.0, &empty_attributes);

    // Force collection via processor (pull model)
    reader.collect();

    // Verify metrics were exported
    try testing.expect(mock_exporter.metricCount() > 0);

    // Check that we have the expected metric types
    var found_counter = false;
    var found_histogram = false;

    for (0..mock_exporter.metricCount()) |i| {
        if (mock_exporter.getMetric(i)) |metric| {
            if (std.mem.eql(u8, metric.name, "http.requests")) {
                found_counter = true;
                try testing.expectEqual(sdk.MetricType.sum, metric.type);
                try testing.expect(metric.data_points.len > 0);
            } else if (std.mem.eql(u8, metric.name, "http.duration")) {
                found_histogram = true;
                try testing.expectEqual(sdk.MetricType.histogram, metric.type);
                try testing.expect(metric.data_points.len > 0);
            }
        }
    }

    try testing.expect(found_counter);
    try testing.expect(found_histogram);
}

test "BasicMeter shutdown behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, resource);
    defer provider.deinit();

    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create counter and record data before shutdown
    const counter = try meter.createCounter(i64, "test.counter", "Test counter", "requests", null);
    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    counter.add(ctx, 10, &empty_attributes);

    // Get the BasicMeter instance for direct access
    const basic_meter: *sdk.Meter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // TODO: Phase 1b - Re-enable once collection is implemented at reader level
    // // Verify data exists before shutdown
    // const metrics_before = try basic_meter.collectMetrics(allocator);
    // defer cleanupMetrics(allocator, metrics_before);
    // try testing.expect(metrics_before.len > 0);

    // Shutdown the meter
    basic_meter.shutdown();
    try testing.expect(basic_meter.is_shutdown.load(.unordered));

    // TODO: Phase 1b - Re-enable once collection is implemented at reader level
    // // Test that collectMetrics still works after shutdown (data preserved)
    // const metrics_after = try basic_meter.collectMetrics(allocator);
    // defer cleanupMetrics(allocator, metrics_after);
    // try testing.expect(metrics_after.len > 0);

    // TODO: The following test should work when shutdown behavior is fully implemented
    // Currently commented out as it may not be implemented yet
    //
    // // Try to record new data after shutdown - should be ignored
    // counter.add(ctx, 5, &empty_attributes);
    //
    // // Verify the counter value didn't change
    // const metrics_final = try basic_meter.collectMetrics(allocator);
    // defer allocator.free(metrics_final);
    // // Should still have same data as before the post-shutdown recording
}

test "BasicMeterProvider flush behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, resource);
    defer provider.deinit();

    const mock_exporter = try allocator.create(MockMetricExporter);
    mock_exporter.* = MockMetricExporter.init(allocator);

    const reader = try allocator.create(sdk.ManualReader);
    reader.* = try sdk.ManualReader.init(allocator, mock_exporter.metricExporter());

    try provider.registerReader(reader.reader());

    // Test successful flush
    const result = provider.forceFlush(1000);
    try testing.expectEqual(api.common.FlushResult.success, result);

    // Test flush with failure
    mock_exporter.flush_result = .failure;
    const result2 = provider.forceFlush(1000);
    try testing.expectEqual(api.common.FlushResult.failure, result2);
}

test "BasicMeter comprehensive instrument test with attributes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, resource);
    defer provider.deinit();

    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Test custom histogram boundaries (for future use)
    _ = [_]f64{ 0.0, 1.0, 5.0, 10.0, 50.0 };

    // Create all instrument types with different value types
    const counter_i64 = try meter.createCounter(i64, "test.counter.i64", "Test i64 counter", "ops", null);
    const counter_f64 = try meter.createCounter(f64, "test.counter.f64", "Test f64 counter", "seconds", null);
    const updown_i64 = try meter.createUpDownCounter(i64, "test.updown.i64", "Test i64 updown", "items", null);
    const updown_f64 = try meter.createUpDownCounter(f64, "test.updown.f64", "Test f64 updown", "temperature", null);
    const gauge_i64 = try meter.createGauge(i64, "test.gauge.i64", "Test i64 gauge", "bytes", null);
    const gauge_f64 = try meter.createGauge(f64, "test.gauge.f64", "Test f64 gauge", "ratio", null);
    const histogram_i64 = try meter.createHistogram(i64, "test.histogram.i64", "Test i64 histogram", "count", null);
    const histogram_f64 = try meter.createHistogram(f64, "test.histogram.f64", "Test f64 histogram", "latency", null);

    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    // Record various measurements
    counter_i64.add(ctx, 15, &empty_attributes);
    counter_i64.add(ctx, 25, &empty_attributes); // Total: 40
    counter_f64.add(ctx, 3.14, &empty_attributes);
    counter_f64.add(ctx, 2.86, &empty_attributes); // Total: 6.0

    updown_i64.add(ctx, 10, &empty_attributes);
    updown_i64.add(ctx, -3, &empty_attributes); // Total: 7
    updown_f64.add(ctx, 5.5, &empty_attributes);
    updown_f64.add(ctx, -1.5, &empty_attributes); // Total: 4.0

    gauge_i64.record(ctx, 1024, &empty_attributes);
    gauge_i64.record(ctx, 2048, &empty_attributes); // Last: 2048
    gauge_f64.record(ctx, 0.85, &empty_attributes);
    gauge_f64.record(ctx, 0.92, &empty_attributes); // Last: 0.92

    // Test histogram with various values to hit different buckets
    histogram_i64.record(ctx, 2, &empty_attributes); // bucket 1 (1-5)
    histogram_i64.record(ctx, 7, &empty_attributes); // bucket 2 (5-10)
    histogram_i64.record(ctx, 15, &empty_attributes); // bucket 3 (10-50)
    histogram_f64.record(ctx, 0.5, &empty_attributes); // bucket 0 (0-1)
    histogram_f64.record(ctx, 3.2, &empty_attributes); // bucket 1 (1-5)
    histogram_f64.record(ctx, 25.0, &empty_attributes); // bucket 3 (10-50)

    // There are no readers configured on the provider, so this is a dead-end test.
}

test "BasicMeter instrument creation after shutdown returns noop instruments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, resource);
    defer provider.deinit();

    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create instrument before shutdown - should be normal SDK instrument
    const counter_before = try meter.createCounter(i64, "test.counter.before", "Test counter", "requests", null);
    try testing.expect(counter_before == .bridge); // Should be bridge to SDK instrument

    // Get the BasicMeter instance to shutdown directly
    const basic_meter: *sdk.Meter = @ptrCast(@alignCast(meter.bridge.meter_ptr));
    basic_meter.shutdown();

    // Create instruments after shutdown - should be noop instruments
    const counter_after = try meter.createCounter(i64, "test.counter.after", "Test counter", "requests", null);
    const updown_after = try meter.createUpDownCounter(f64, "test.updown.after", "Test updown", "bytes", null);
    const gauge_after = try meter.createGauge(i64, "test.gauge.after", "Test gauge", "items", null);
    const histogram_after = try meter.createHistogram(f64, "test.histogram.after", "Test histogram", "ms", null);

    // All instruments created after shutdown should be noop
    try testing.expect(counter_after == .noop);
    try testing.expect(updown_after == .noop);
    try testing.expect(gauge_after == .noop);
    try testing.expect(histogram_after == .noop);

    // Verify noop instruments have the correct names
    try testing.expectEqualStrings("test.counter.after", counter_after.noop);
    try testing.expectEqualStrings("test.updown.after", updown_after.noop);
    try testing.expectEqualStrings("test.gauge.after", gauge_after.noop);
    try testing.expectEqualStrings("test.histogram.after", histogram_after.noop);
}

test "PeriodicReader with multiple instruments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, resource);
    defer provider.deinit();

    // Create mock exporter
    const mock_exporter = try allocator.create(MockMetricExporter);
    mock_exporter.* = MockMetricExporter.init(allocator);
    // Processor takes ownership of this memory

    // Create periodic reader with 100ms interval
    const reader = try allocator.create(sdk.PeriodicReader);
    reader.* = try sdk.PeriodicReader.init(allocator, mock_exporter.metricExporter(), 100);

    // Register reader (provider takes ownership)
    try provider.registerReader(reader.reader());

    // Get meter
    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create regular instruments
    const counter = try meter.createCounter(i64, "test.counter", "Test counter", "requests", null);
    const gauge = try meter.createGauge(f64, "test.gauge", "Test gauge", "ratio", null);
    const histogram = try meter.createHistogram(i64, "test.histogram", "Test histogram", "count", null);

    // Create observable instruments
    const observable_counter = try meter.createObservableCounter(i64, "test.observable.counter", "Test observable counter", "requests", null, &[_]api.metrics.TypeErasedCallback(i64){});
    const observable_gauge = try meter.createObservableGauge(f64, "test.observable.gauge", "Test observable gauge", "ratio", null, &[_]api.metrics.TypeErasedCallback(f64){});
    const observable_updown = try meter.createObservableUpDownCounter(i64, "test.observable.updown", "Test observable updown", "items", null, &[_]api.metrics.TypeErasedCallback(i64){});

    // Record some data with regular instruments
    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    counter.add(ctx, 10, &empty_attributes);
    counter.add(ctx, 5, &empty_attributes);
    gauge.record(ctx, 0.75, &empty_attributes);
    histogram.record(ctx, 15, &empty_attributes);
    histogram.record(ctx, 25, &empty_attributes);

    // Setup callbacks for observable instruments
    const counter_callback = struct {
        fn callback(alloc: std.mem.Allocator, result: *api.metrics.ObservableResult(i64)) void {
            result.observe(alloc, 42, &empty_attributes);
        }
    }.callback;
    const gauge_callback = struct {
        fn callback(alloc: std.mem.Allocator, result: *api.metrics.ObservableResult(f64)) void {
            result.observe(alloc, 0.95, &empty_attributes);
        }
    }.callback;
    const updown_callback = struct {
        fn callback(alloc: std.mem.Allocator, result: *api.metrics.ObservableResult(i64)) void {
            result.observe(alloc, 100, &empty_attributes);
        }
    }.callback;

    // Register the callbacks
    const counter_handle = try observable_counter.registerCallbackNoState(counter_callback);
    const gauge_handle = try observable_gauge.registerCallbackNoState(gauge_callback);
    const updown_handle = try observable_updown.registerCallbackNoState(updown_callback);

    defer {
        counter_handle.unregister();
        gauge_handle.unregister();
        updown_handle.unregister();
    }

    // Wait for periodic collection to happen (simulate time passing)
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Force a final collection
    reader.collect();

    // Verify metrics were exported
    try testing.expect(mock_exporter.metricCount() > 0);

    // Check that we have the expected metric types
    var found_counter = false;
    var found_gauge = false;
    var found_histogram = false;
    var found_observable_counter = false;
    var found_observable_gauge = false;
    var found_observable_updown = false;

    for (0..mock_exporter.metricCount()) |i| {
        if (mock_exporter.getMetric(i)) |metric| {
            if (std.mem.eql(u8, metric.name, "test.counter")) {
                found_counter = true;
                try testing.expectEqual(sdk.MetricType.sum, metric.type);
                try testing.expect(metric.data_points.len > 0);
            } else if (std.mem.eql(u8, metric.name, "test.gauge")) {
                found_gauge = true;
                try testing.expectEqual(sdk.MetricType.gauge, metric.type);
                try testing.expect(metric.data_points.len > 0);
            } else if (std.mem.eql(u8, metric.name, "test.histogram")) {
                found_histogram = true;
                try testing.expectEqual(sdk.MetricType.histogram, metric.type);
                try testing.expect(metric.data_points.len > 0);
            } else if (std.mem.eql(u8, metric.name, "test.observable.counter")) {
                found_observable_counter = true;
                try testing.expectEqual(sdk.MetricType.sum, metric.type);
                try testing.expect(metric.data_points.len > 0);
            } else if (std.mem.eql(u8, metric.name, "test.observable.gauge")) {
                found_observable_gauge = true;
                try testing.expectEqual(sdk.MetricType.gauge, metric.type);
                try testing.expect(metric.data_points.len > 0);
            } else if (std.mem.eql(u8, metric.name, "test.observable.updown")) {
                found_observable_updown = true;
                try testing.expectEqual(sdk.MetricType.sum, metric.type);
                try testing.expect(metric.data_points.len > 0);
            }
        }
    }

    try testing.expect(found_counter);
    try testing.expect(found_gauge);
    try testing.expect(found_histogram);
    try testing.expect(found_observable_counter);
    try testing.expect(found_observable_gauge);
    try testing.expect(found_observable_updown);
}
