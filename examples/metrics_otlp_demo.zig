//! OpenTelemetry Metrics OTLP Export Demo
//!
//! This example demonstrates exporting metrics using the OpenTelemetry Protocol (OTLP).
//! It shows how to:
//! - Create a meter provider and instruments
//! - Record measurements
//! - Set up an OTLP exporter
//! - Export metrics to an OTLP-compatible backend
//!
//! To run this example, you'll need an OTLP receiver running, such as:
//! - OpenTelemetry Collector: docker run -p 4318:4318 otel/opentelemetry-collector:latest
//! - Jaeger with OTLP support: docker run -p 4318:4318 jaegertracing/all-in-one:latest

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create arena allocator for meter/instrument operations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    std.debug.print("=== OpenTelemetry Metrics OTLP Export Demo ===\n\n", .{});

    // Create a meter provider (uses arena allocator for potential meter/instrument leaks)
    var sdk_provider = try otel_sdk.metrics.createProvider(arena_allocator);
    defer sdk_provider.deinit();

    // Wrap it for API use
    var provider = otel_sdk.bridge.wrapStandardMeterProvider(&sdk_provider);

    // Get a meter for our application (using arena allocator)
    const meter = try provider.getMeter(
        "otlp.metrics.demo",
        "1.0.0",
        "https://example.com/schema/1.0",
        &[_]otel_api.KeyValue{
            otel_api.KeyValue.init("meter.type", .{ .string = "demo" }),
        },
    );

    // Create various instruments
    const request_counter = try meter.createCounterI64(
        "http.server.request_count",
        "Total number of HTTP requests",
        "1",
    );

    const request_duration = try meter.createCounterF64(
        "http.server.request_duration",
        "Total time spent processing requests",
        "ms",
    );

    const active_requests = try meter.createUpDownCounterI64(
        "http.server.active_requests",
        "Number of active HTTP requests",
        "1",
    );

    const memory_max = try meter.createGaugeF64(
        "process.runtime.memory_max",
        "max memory available",
        "MiB",
    );

    const cpu_usage = try meter.createGaugeF64(
        "process.runtime.cpu_usage",
        "Current CPU usage percentage",
        "%",
    );

    // Create a context for recording (using main allocator for context)
    var ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    // Simulate some application activity
    std.debug.print("Recording metrics...\n", .{});

    // Simulate HTTP requests
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        // Request starts
        active_requests.add(ctx, 1, &[_]otel_api.KeyValue{
            otel_api.KeyValue.init("http.method", .{ .string = "GET" }),
            otel_api.KeyValue.init("http.route", .{ .string = "/api/users" }),
        });

        // Simulate processing time
        const duration = 50.0 + @as(f64, @floatFromInt(i)) * 10.0;
        request_duration.add(ctx, duration, &[_]otel_api.KeyValue{
            otel_api.KeyValue.init("http.method", .{ .string = "GET" }),
            otel_api.KeyValue.init("http.status_code", .{ .int = 200 }),
        });

        // Request completes
        request_counter.add(ctx, 1, &[_]otel_api.KeyValue{
            otel_api.KeyValue.init("http.method", .{ .string = "GET" }),
            otel_api.KeyValue.init("http.status_code", .{ .int = 200 }),
        });

        active_requests.add(ctx, -1, &[_]otel_api.KeyValue{
            otel_api.KeyValue.init("http.method", .{ .string = "GET" }),
            otel_api.KeyValue.init("http.route", .{ .string = "/api/users" }),
        });

        std.debug.print("  Processed request {}: {}ms\n", .{ i + 1, duration });
    }

    // Record some system metrics

    var mem_size: u64 = 0;
    {
        var mib = [_]c_int{ 6, 24 };
        var size: usize = @sizeOf(@TypeOf(mem_size));

        const result = std.posix.system.sysctl(&mib, mib.len, @ptrCast(&mem_size), &size, null, 0);
        if (result != 0) {
            std.debug.print("unable to read memory.", .{});
        }
    }
    const mem_max: f64 = @as(f64, @floatFromInt(mem_size)) / 1048576.0;
    memory_max.record(ctx, mem_max, &[_]otel_api.KeyValue{
        otel_api.KeyValue.init("memory.type", .{ .string = "heap" }),
    });
    std.debug.print("  Memory Max: {d:.2} MiB\n", .{mem_max});

    cpu_usage.record(ctx, 45.2, &[_]otel_api.KeyValue{
        otel_api.KeyValue.init("cpu.core", .{ .string = "all" }),
    });
    std.debug.print("  CPU usage: 45.2%\n", .{});

    // Now collect and export metrics
    std.debug.print("\nCollecting metrics from provider...\n", .{});
    const metrics = try sdk_provider.collectMetrics(allocator);
    defer {
        // Clean up metric data comprehensively
        for (metrics) |metric| {
            // Free data points array (allocated in meter collection)
            if (metric.data_points.len > 0) {
                // Note: In current MVP, attributes are static arrays (&[_]KeyValue{})
                // But if dynamic attributes are added later, they would need cleanup here:
                // for (metric.data_points) |data_point| {
                //     if (data_point.attributes.len > 0) {
                //         allocator.free(data_point.attributes);
                //     }
                // }
                allocator.free(metric.data_points);
            }

            // Note: metric.name, metric.description, metric.unit are currently
            // string literals from instrument creation, so no cleanup needed.
            // If they become dynamically allocated in the future, add cleanup here.
        }
        allocator.free(metrics);
    }

    std.debug.print("Collected {} metrics\n", .{metrics.len});

    // Create OTLP exporter
    const otlp_config = otel_exporters.otlp.OtlpExporterConfig{
        .endpoint = "http://localhost:4318",
        .transport = .http_json,
        .timeout_millis = 10000,
        .headers = &[_]std.http.Header{
            .{ .name = "X-Custom-Header", .value = "metrics-demo" },
        },
    };

    var otlp_exporter = try otel_exporters.otlp.createMetricExporterWithConfig(allocator, otlp_config);
    defer {
        otlp_exporter.deinit();
        allocator.destroy(otlp_exporter);
    }

    // Export the metrics
    std.debug.print("\nExporting metrics to OTLP endpoint: {s}\n", .{otlp_config.endpoint});
    const export_result = otlp_exporter.@"export"(metrics);

    switch (export_result) {
        .success => std.debug.print("✅ Metrics exported successfully!\n", .{}),
        .failure => std.debug.print("❌ Failed to export metrics. Is the OTLP receiver running?\n", .{}),
    }

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("Check your OTLP receiver for the exported metrics!\n", .{});
}
