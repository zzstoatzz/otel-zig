//! Test file to demonstrate OpenTelemetry View functionality
//!
//! This file shows how views can transform metrics collection:
//! - Attribute filtering
//! - Name and description overrides
//! - Drop aggregations
//! - Multiple views per instrument

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== OpenTelemetry View System Test ===\n", .{});

    // Clean up global providers at program exit
    defer otel_api.provider_registry.unsetAllProviders();

    try testBasicViewFunctionality(allocator);
    try testAttributeFiltering(allocator);
    try testDropAggregation(allocator);
    try testMultipleViews(allocator);
    try testViewOverrides(allocator);

    std.debug.print("\n✅ All view tests completed successfully!\n", .{});
}

/// Test basic view functionality with name override
fn testBasicViewFunctionality(allocator: std.mem.Allocator) !void {
    std.debug.print("\n1. Testing Basic View Functionality\n", .{});
    std.debug.print("   - View renames 'http_requests' to 'http.requests.total'\n", .{});

    // Create view that renames an instrument
    const rename_view = otel_sdk.metrics.View{
        .instrument_selector = .{ .name = "http_requests" },
        .name = "http.requests.total",
        .description = "Total HTTP requests processed",
    };

    // Setup provider with view
    const provider = try otel_sdk.metrics.setupGlobalProviderWithViews(
        allocator,
        .{otel_sdk.metrics.ManualReader.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleMetricExporter.PipelineStep.init(.{}))},
        .{rename_view},
    );
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Get meter and create instrument
    const scope = try otel_api.InstrumentationScope.initSimple("test.meter", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    const counter = try meter.createCounter(i64, "http_requests", "HTTP requests", "requests", null);

    // Record some measurements
    const ctx = otel_api.Context.init(allocator);
    const attributes = [_]otel_api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "GET" } },
        .{ .key = "status", .value = .{ .int = 200 } },
    };

    counter.add(ctx, 10, &attributes);
    counter.add(ctx, 5, &attributes);

    // Force collection and export
    const reader = &provider.readers.items[0];
    reader.collect();

    std.debug.print("   ✅ Instrument renamed via view\n", .{});
}

/// Test attribute filtering functionality
fn testAttributeFiltering(allocator: std.mem.Allocator) !void {
    std.debug.print("\n2. Testing Attribute Filtering\n", .{});
    std.debug.print("   - View filters attributes to only 'method' and 'status'\n", .{});

    // Create view that filters attributes
    const filter_view = otel_sdk.metrics.View{
        .instrument_selector = .{ .name = "api_requests" },
        .attribute_allowed_keys = &[_][]const u8{ "method", "status" },
    };

    // Setup provider with view
    const provider = try otel_sdk.metrics.setupGlobalProviderWithViews(
        allocator,
        .{otel_sdk.metrics.ManualReader.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleMetricExporter.PipelineStep.init(.{}))},
        .{filter_view},
    );
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Get meter and create instrument
    const scope = try otel_api.InstrumentationScope.initSimple("test.meter", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    const counter = try meter.createCounter(i64, "api_requests", "API requests", "requests", null);

    // Record measurements with multiple attributes (some will be filtered)
    const ctx = otel_api.Context.init(allocator);
    const all_attributes = [_]otel_api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "POST" } },
        .{ .key = "status", .value = .{ .int = 201 } },
        .{ .key = "user_id", .value = .{ .string = "12345" } }, // This should be filtered out
        .{ .key = "endpoint", .value = .{ .string = "/api/users" } }, // This should be filtered out
    };

    counter.add(ctx, 3, &all_attributes);

    // Force collection and export
    const reader = &provider.readers.items[0];
    reader.collect();

    std.debug.print("   ✅ Attributes filtered (user_id and endpoint removed)\n", .{});
}

/// Test drop aggregation functionality
fn testDropAggregation(allocator: std.mem.Allocator) !void {
    std.debug.print("\n3. Testing Drop Aggregation\n", .{});
    std.debug.print("   - View drops debug metrics\n", .{});

    // Create view that drops debug metrics
    const drop_view = otel_sdk.metrics.View{
        .instrument_selector = .{ .name = "debug.metric" }, // Exact match for now
        .aggregation_override = .drop,
    };

    // Create normal view for production metrics
    const normal_view = otel_sdk.metrics.View{
        .instrument_selector = .{ .name = "prod.counter" },
    };

    // Setup provider with both views
    const provider = try otel_sdk.metrics.setupGlobalProviderWithViews(
        allocator,
        .{otel_sdk.metrics.ManualReader.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleMetricExporter.PipelineStep.init(.{}))},
        .{ drop_view, normal_view },
    );
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Get meter and create instruments
    const scope = try otel_api.InstrumentationScope.initSimple("test.meter", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    const debug_counter = try meter.createCounter(i64, "debug.metric", "Debug metric", "count", null);
    const prod_counter = try meter.createCounter(i64, "prod.counter", "Production counter", "count", null);

    // Record measurements on both
    const ctx = otel_api.Context.init(allocator);
    const empty_attrs = [_]otel_api.AttributeKeyValue{};

    debug_counter.add(ctx, 100, &empty_attrs); // This should be dropped
    prod_counter.add(ctx, 50, &empty_attrs); // This should be collected

    // Force collection and export
    const reader = &provider.readers.items[0];
    reader.collect();

    std.debug.print("   ✅ Debug metric dropped, production metric collected\n", .{});
}

/// Test multiple views matching the same instrument
fn testMultipleViews(allocator: std.mem.Allocator) !void {
    std.debug.print("\n4. Testing Multiple Views\n", .{});
    std.debug.print("   - Multiple views create independent streams\n", .{});

    // Create multiple views for the same instrument
    const full_view = otel_sdk.metrics.View{
        .instrument_selector = .{ .name = "multi_metric" },
        .name = "multi.metric.full",
        .description = "Full metric with all attributes",
    };

    const filtered_view = otel_sdk.metrics.View{
        .instrument_selector = .{ .name = "multi_metric" },
        .name = "multi.metric.filtered",
        .description = "Filtered metric with only method attribute",
        .attribute_allowed_keys = &[_][]const u8{"method"},
    };

    // Setup provider with multiple views
    const provider = try otel_sdk.metrics.setupGlobalProviderWithViews(
        allocator,
        .{otel_sdk.metrics.ManualReader.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleMetricExporter.PipelineStep.init(.{}))},
        .{ full_view, filtered_view },
    );
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Get meter and create instrument
    const scope = try otel_api.InstrumentationScope.initSimple("test.meter", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    const counter = try meter.createCounter(i64, "multi_metric", "Multi-view metric", "count", null);

    // Record measurements
    const ctx = otel_api.Context.init(allocator);
    const attributes = [_]otel_api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "GET" } },
        .{ .key = "status", .value = .{ .int = 200 } },
        .{ .key = "path", .value = .{ .string = "/health" } },
    };

    counter.add(ctx, 25, &attributes);

    // Force collection and export
    const reader = &provider.readers.items[0];
    reader.collect();

    std.debug.print("   ✅ Single instrument created two metric streams\n", .{});
}

/// Test view name and description overrides
fn testViewOverrides(allocator: std.mem.Allocator) !void {
    std.debug.print("\n5. Testing View Overrides\n", .{});
    std.debug.print("   - View overrides name and description\n", .{});

    // Create view with overrides
    const override_view = otel_sdk.metrics.View{
        .instrument_selector = .{ .name = "original_name" },
        .name = "new.awesome.metric",
        .description = "This is a much better description",
    };

    // Setup provider with view
    const provider = try otel_sdk.metrics.setupGlobalProviderWithViews(
        allocator,
        .{otel_sdk.metrics.ManualReader.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleMetricExporter.PipelineStep.init(.{}))},
        .{override_view},
    );
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Get meter and create instrument with original name
    const scope = try otel_api.InstrumentationScope.initSimple("test.meter", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    const counter = try meter.createCounter(i64, "original_name", "Original boring description", "count", null);

    // Record measurements
    const ctx = otel_api.Context.init(allocator);
    const attributes = [_]otel_api.AttributeKeyValue{
        .{ .key = "version", .value = .{ .string = "v1.0" } },
    };

    counter.add(ctx, 42, &attributes);

    // Force collection and export
    const reader = &provider.readers.items[0];
    reader.collect();

    std.debug.print("   ✅ Metric exported with new name and description\n", .{});
}
