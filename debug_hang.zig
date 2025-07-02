//! Debug file to diagnose the hanging issue when setting up SDK providers in tests

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("Starting diagnosis...\n", .{});

    // Test 1: Basic provider setup
    print("Test 1: Setting up trace provider...\n", .{});
    testTraceProviderSetup(allocator) catch |err| {
        print("Test 1 failed: {}\n", .{err});
        return;
    };
    print("Test 1 passed!\n", .{});

    // Test 2: Multiple provider setup
    print("Test 2: Setting up multiple providers...\n", .{});
    testMultipleProviders(allocator) catch |err| {
        print("Test 2 failed: {}\n", .{err});
        return;
    };
    print("Test 2 passed!\n", .{});

    // Test 3: Provider setup with span creation
    print("Test 3: Provider setup with span operations...\n", .{});
    testSpanOperations(allocator) catch |err| {
        print("Test 3 failed: {}\n", .{err});
        return;
    };
    print("Test 3 passed!\n", .{});

    // Test 4: Validation operations
    print("Test 4: Testing validation with real spans...\n", .{});
    testValidationOperations(allocator) catch |err| {
        print("Test 4 failed: {}\n", .{err});
        return;
    };
    print("Test 4 passed!\n", .{});

    print("All tests passed! No hanging detected.\n", .{});
}

fn testTraceProviderSetup(allocator: std.mem.Allocator) !void {
    print("  Creating trace provider...\n", .{});

    const trace_provider = try otel_sdk.trace.setupGlobalProvider(
        allocator,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleTraceExporter.PipelineStep.init(.{}))},
    );

    print("  Provider created successfully\n", .{});

    defer {
        print("  Cleaning up trace provider...\n", .{});
        trace_provider.deinit();
        trace_provider.destroy();
        print("  Trace provider cleaned up\n", .{});
    }

    // Small delay to see if it hangs during setup
    std.time.sleep(100 * std.time.ns_per_ms);
    print("  Setup delay completed\n", .{});
}

fn testMultipleProviders(allocator: std.mem.Allocator) !void {
    print("  Setting up trace provider...\n", .{});
    const trace_provider = try otel_sdk.trace.setupGlobalProvider(
        allocator,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleTraceExporter.PipelineStep.init(.{}))},
    );
    defer {
        trace_provider.deinit();
        trace_provider.destroy();
    }

    print("  Setting up log provider...\n", .{});
    const log_provider = try otel_sdk.logs.setupGlobalProvider(
        allocator,
        .{otel_sdk.logs.BasicLogProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.console.StreamLogExporter(std.fs.File.Writer).PipelineStep.init(.{}))},
    );
    defer {
        log_provider.deinit();
        log_provider.destroy();
    }

    print("  Setting up metric provider...\n", .{});
    const metric_provider = try otel_sdk.metrics.setupGlobalProvider(
        allocator,
        .{otel_sdk.metrics.BasicMetricProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleMetricExporter.PipelineStep.init(.{}))},
    );
    defer {
        metric_provider.deinit();
        metric_provider.destroy();
    }

    print("  All providers set up, sleeping...\n", .{});
    std.time.sleep(100 * std.time.ns_per_ms);
    print("  Multiple providers test completed\n", .{});
}

fn testSpanOperations(allocator: std.mem.Allocator) !void {
    print("  Setting up provider for span operations...\n", .{});
    const trace_provider = try otel_sdk.trace.setupGlobalProvider(
        allocator,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleTraceExporter.PipelineStep.init(.{}))},
    );
    defer {
        trace_provider.deinit();
        trace_provider.destroy();
    }

    print("  Creating tracer and context...\n", .{});
    const scope = try otel_api.InstrumentationScope.initSimple("debug.tracer", "1.0.0");
    var tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);
    const ctx = otel_api.Context.init(allocator);
    defer ctx.deinit();

    print("  Creating span...\n", .{});
    const span = try tracer.startSpan("debug-span", .{}, ctx);

    print("  Setting span attributes...\n", .{});
    try span.setAttribute("test.key", otel_api.common.AttributeValue{ .string = "test.value" });

    print("  Ending span...\n", .{});
    span.end(null);
    span.deinit();

    print("  Span operations completed\n", .{});
}

fn testValidationOperations(allocator: std.mem.Allocator) !void {
    print("  Setting up provider for validation testing...\n", .{});
    const trace_provider = try otel_sdk.trace.setupGlobalProvider(
        allocator,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleTraceExporter.PipelineStep.init(.{}))},
    );
    defer {
        trace_provider.deinit();
        trace_provider.destroy();
    }

    print("  Creating tracer and context...\n", .{});
    const scope = try otel_api.InstrumentationScope.initSimple("validation.tracer", "1.0.0");
    var tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);
    const ctx = otel_api.Context.init(allocator);
    defer ctx.deinit();

    print("  Testing validation with invalid inputs...\n", .{});

    // Test empty span name (should trigger validation)
    print("    Creating span with empty name...\n", .{});
    const span1 = try tracer.startSpan("", .{}, ctx);
    defer span1.deinit();
    defer span1.end(null);

    // Test invalid attributes (should trigger validation)
    print("    Setting invalid attributes...\n", .{});
    span1.setAttribute("", otel_api.common.AttributeValue{ .string = "invalid_key" }) catch {};

    // Test invalid span name update
    print("    Updating span name to empty...\n", .{});
    span1.updateName("") catch {};

    print("  Validation operations completed\n", .{});
}
