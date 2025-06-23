const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // OpenTelemetry API Module
    // ========================================================================
    // Contains only interfaces, types, and noop implementations
    // This is what applications import for stable APIs
    const otel_api_mod = b.createModule(.{
        .root_source_file = b.path("src/api/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("otel-api", .{
        .root_source_file = b.path("src/api/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // OpenTelemetry SDK Core Module
    // ========================================================================
    // Contains basic SDK implementations (loggers, providers, processors)
    const otel_sdk_mod = b.createModule(.{
        .root_source_file = b.path("src/sdk/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    otel_sdk_mod.addImport("otel-api", otel_api_mod);

    _ = b.addModule("otel-sdk", .{
        .root_source_file = b.path("src/sdk/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel-api", .module = otel_api_mod },
        },
    });

    // ========================================================================
    // OpenTelemetry protobuf generator
    // ========================================================================
    // Generate the otlp proto outputs
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    const gen_proto = b.step("gen-proto", "generates zig files for OTLP.");
    const protoc_step = @import("protobuf").RunProtocStep.create(b, protobuf_dep.builder, target, .{
        // out directory for the generated zig files
        .destination_directory = b.path("src/exporters/otlp/proto"),
        .source_files = &.{
            "opentelemetry-proto/opentelemetry/proto/logs/v1/logs.proto",
            "opentelemetry-proto/opentelemetry/proto/metrics/v1/metrics.proto",
            "opentelemetry-proto/opentelemetry/proto/trace/v1/trace.proto",
        },
        .include_directories = &.{
            "opentelemetry-proto/",
        },
    });

    gen_proto.dependOn(&protoc_step.step);

    // ========================================================================
    // OpenTelemetry SDK Exporters Module
    // ========================================================================
    // Contains concrete exporters (console, OTLP, etc.)

    const otel_exporters_mod = b.createModule(.{
        .root_source_file = b.path("src/exporters/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    otel_exporters_mod.addImport("otel-api", otel_api_mod);
    otel_exporters_mod.addImport("otel-sdk", otel_sdk_mod);
    otel_exporters_mod.addImport("protobuf", protobuf_dep.module("protobuf"));

    _ = b.addModule("otel-exporters", .{
        .root_source_file = b.path("src/exporters/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel-api", .module = otel_api_mod },
            .{ .name = "otel-sdk", .module = otel_sdk_mod },
            .{ .name = "protobuf", .module = protobuf_dep.module("protobuf") },
        },
    });

    // ========================================================================
    // OpenTelemetry Semantic Conventions Module
    // ========================================================================
    // Contains semantic conventions, can be used independently
    const otel_semconv_mod = b.createModule(.{
        .root_source_file = b.path("src/semconv/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("otel-semconv", .{
        .root_source_file = b.path("src/semconv/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Convenience "All-in-One" Module
    // ========================================================================
    // Re-exports everything for simple use cases
    const otel_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    otel_mod.addImport("otel-api", otel_api_mod);
    otel_mod.addImport("otel-sdk", otel_sdk_mod);
    otel_mod.addImport("otel-exporters", otel_exporters_mod);
    otel_mod.addImport("otel-semconv", otel_semconv_mod);

    _ = b.addModule("otel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel-api", .module = otel_api_mod },
            .{ .name = "otel-sdk", .module = otel_sdk_mod },
            .{ .name = "otel-exporters", .module = otel_exporters_mod },
            .{ .name = "otel-semconv", .module = otel_semconv_mod },
        },
    });

    // ========================================================================
    // Libraries
    // ========================================================================

    // API library (minimal, stable)
    const api_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "otel-api",
        .root_module = otel_api_mod,
    });
    b.installArtifact(api_lib);

    // SDK library (full implementation)
    const sdk_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "otel-sdk",
        .root_module = otel_sdk_mod,
    });
    b.installArtifact(sdk_lib);

    // Exporters library
    const exporters_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "otel-exporters",
        .root_module = otel_exporters_mod,
    });
    b.installArtifact(exporters_lib);

    // All-in-one library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "otel",
        .root_module = otel_mod,
    });
    b.installArtifact(lib);

    // ========================================================================
    // Tests
    // ========================================================================

    // API tests
    const api_unit_tests = b.addTest(.{
        .root_module = otel_api_mod,
    });
    const run_api_tests = b.addRunArtifact(api_unit_tests);

    // SDK tests
    const sdk_unit_tests = b.addTest(.{
        .root_module = otel_sdk_mod,
    });
    const run_sdk_tests = b.addRunArtifact(sdk_unit_tests);

    // Exporters tests
    const exporters_unit_tests = b.addTest(.{
        .root_module = otel_exporters_mod,
    });
    const run_exporters_tests = b.addRunArtifact(exporters_unit_tests);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = otel_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // Test steps
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_sdk_tests.step);
    test_step.dependOn(&run_exporters_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    const test_api_step = b.step("test-api", "Run API tests only");
    test_api_step.dependOn(&run_api_tests.step);

    const test_sdk_step = b.step("test-sdk", "Run SDK tests only");
    test_sdk_step.dependOn(&run_sdk_tests.step);

    const test_exporters_step = b.step("test-exporters", "Run exporters tests only");
    test_exporters_step.dependOn(&run_exporters_tests.step);

    // ========================================================================
    // Examples
    // ========================================================================

    // DNS Query Logging Example
    const dns_query_example = b.addExecutable(.{
        .name = "dns_query_logging",
        .root_source_file = b.path("examples/dns_query_logging.zig"),
        .target = target,
        .optimize = optimize,
    });
    dns_query_example.root_module.addImport("otel-api", otel_api_mod);
    dns_query_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    dns_query_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_dns_query = b.addRunArtifact(dns_query_example);
    const dns_query_step = b.step("example-dns-query", "Run DNS query logging example");
    dns_query_step.dependOn(&run_dns_query.step);

    // DNS Query Logging OTLP Example
    const dns_query_otlp_example = b.addExecutable(.{
        .name = "dns_query_logging_otlp",
        .root_source_file = b.path("examples/dns_query_logging_otlp.zig"),
        .target = target,
        .optimize = optimize,
    });
    dns_query_otlp_example.root_module.addImport("otel-api", otel_api_mod);
    dns_query_otlp_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    dns_query_otlp_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_dns_query_otlp = b.addRunArtifact(dns_query_otlp_example);
    const dns_query_otlp_step = b.step("example-dns-query-otlp", "Run DNS query logging OTLP example");
    dns_query_otlp_step.dependOn(&run_dns_query_otlp.step);

    // Metrics Demo Example
    const metrics_demo_example = b.addExecutable(.{
        .name = "metrics_demo",
        .root_source_file = b.path("examples/metrics_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    metrics_demo_example.root_module.addImport("otel-api", otel_api_mod);
    metrics_demo_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    metrics_demo_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_metrics_demo = b.addRunArtifact(metrics_demo_example);
    const metrics_demo_step = b.step("example-metrics", "Run metrics demo example");
    metrics_demo_step.dependOn(&run_metrics_demo.step);

    // Metrics Histogram Example
    const metrics_histogram_example = b.addExecutable(.{
        .name = "metrics_histogram",
        .root_source_file = b.path("examples/metrics_histogram.zig"),
        .target = target,
        .optimize = optimize,
    });
    metrics_histogram_example.root_module.addImport("otel", otel_mod);
    metrics_histogram_example.root_module.addImport("otel-api", otel_api_mod);
    metrics_histogram_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    metrics_histogram_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_metrics_histogram = b.addRunArtifact(metrics_histogram_example);
    const metrics_histogram_step = b.step("example-metrics-histogram", "Run metrics histogram example");
    metrics_histogram_step.dependOn(&run_metrics_histogram.step);

    // Comprehensive Metrics OTLP Example
    const metrics_comprehensive_otlp_example = b.addExecutable(.{
        .name = "metrics_comprehensive_otlp",
        .root_source_file = b.path("examples/metrics_histogram_otlp.zig"),
        .target = target,
        .optimize = optimize,
    });
    metrics_comprehensive_otlp_example.root_module.addImport("otel", otel_mod);
    metrics_comprehensive_otlp_example.root_module.addImport("otel-api", otel_api_mod);
    metrics_comprehensive_otlp_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    metrics_comprehensive_otlp_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_metrics_comprehensive_otlp = b.addRunArtifact(metrics_comprehensive_otlp_example);
    const metrics_comprehensive_otlp_step = b.step("example-metrics-otlp", "Run comprehensive metrics OTLP example");
    metrics_comprehensive_otlp_step.dependOn(&run_metrics_comprehensive_otlp.step);

    // Simple Trace SDK Example
    const simple_trace_sdk_example = b.addExecutable(.{
        .name = "simple_trace_sdk",
        .root_source_file = b.path("examples/simple_trace_sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_trace_sdk_example.root_module.addImport("otel-api", otel_api_mod);
    simple_trace_sdk_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    simple_trace_sdk_example.root_module.addImport("otel-exporters", otel_exporters_mod);
    b.installArtifact(simple_trace_sdk_example);

    const run_simple_trace_sdk = b.addRunArtifact(simple_trace_sdk_example);
    const simple_trace_sdk_step = b.step("example-simple-trace-sdk", "Run simple trace SDK example");
    simple_trace_sdk_step.dependOn(&run_simple_trace_sdk.step);

    // Comprehensive Trace SDK Example
    const comprehensive_trace_sdk_example = b.addExecutable(.{
        .name = "comprehensive_trace_sdk",
        .root_source_file = b.path("examples/comprehensive_trace_sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    comprehensive_trace_sdk_example.root_module.addImport("otel-api", otel_api_mod);
    comprehensive_trace_sdk_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    comprehensive_trace_sdk_example.root_module.addImport("otel-exporters", otel_exporters_mod);
    b.installArtifact(comprehensive_trace_sdk_example);

    const run_comprehensive_trace_sdk = b.addRunArtifact(comprehensive_trace_sdk_example);
    const comprehensive_trace_sdk_step = b.step("example-comprehensive-trace-sdk", "Run comprehensive trace SDK example");
    comprehensive_trace_sdk_step.dependOn(&run_comprehensive_trace_sdk.step);

    // Simple Trace OTLP Example
    const simple_trace_otlp_example = b.addExecutable(.{
        .name = "simple_trace_otlp",
        .root_source_file = b.path("examples/simple_trace_otlp.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_trace_otlp_example.root_module.addImport("otel-api", otel_api_mod);
    simple_trace_otlp_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    simple_trace_otlp_example.root_module.addImport("otel-exporters", otel_exporters_mod);
    b.installArtifact(simple_trace_otlp_example);

    const run_simple_trace_otlp = b.addRunArtifact(simple_trace_otlp_example);
    const simple_trace_otlp_step = b.step("example-simple-trace-otlp", "Run simple trace OTLP example");
    simple_trace_otlp_step.dependOn(&run_simple_trace_otlp.step);

    // Sampling Test Example
    const sampling_test_example = b.addExecutable(.{
        .name = "test_sampling",
        .root_source_file = b.path("examples/test_sampling.zig"),
        .target = target,
        .optimize = optimize,
    });
    sampling_test_example.root_module.addImport("otel-api", otel_api_mod);
    sampling_test_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    sampling_test_example.root_module.addImport("otel-exporters", otel_exporters_mod);
    b.installArtifact(sampling_test_example);

    const run_sampling_test = b.addRunArtifact(sampling_test_example);
    const sampling_test_step = b.step("example-sampling-test", "Run sampling test example");
    sampling_test_step.dependOn(&run_sampling_test.step);

    // Batch Spans Example
    const batch_spans_example = b.addExecutable(.{
        .name = "batch_spans",
        .root_source_file = b.path("examples/batch_spans.zig"),
        .target = target,
        .optimize = optimize,
    });
    batch_spans_example.root_module.addImport("otel-api", otel_api_mod);
    batch_spans_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    batch_spans_example.root_module.addImport("otel-exporters", otel_exporters_mod);
    b.installArtifact(batch_spans_example);

    const run_batch_spans = b.addRunArtifact(batch_spans_example);
    const batch_spans_step = b.step("example-batch-spans", "Run batch spans example");
    batch_spans_step.dependOn(&run_batch_spans.step);

    // Simple Batch Test Example
    const simple_batch_test_example = b.addExecutable(.{
        .name = "simple_batch_test",
        .root_source_file = b.path("examples/simple_batch_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_batch_test_example.root_module.addImport("otel-api", otel_api_mod);
    simple_batch_test_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    simple_batch_test_example.root_module.addImport("otel-exporters", otel_exporters_mod);
    b.installArtifact(simple_batch_test_example);

    const run_simple_batch_test = b.addRunArtifact(simple_batch_test_example);
    const simple_batch_test_step = b.step("example-simple-batch-test", "Run simple batch test example");
    simple_batch_test_step.dependOn(&run_simple_batch_test.step);

    // All examples step
    const examples_step = b.step("examples", "Run all examples");
    examples_step.dependOn(&run_dns_query.step);
    examples_step.dependOn(&run_dns_query_otlp.step);
    examples_step.dependOn(&run_metrics_demo.step);
    examples_step.dependOn(&run_metrics_histogram.step);
    examples_step.dependOn(&run_metrics_comprehensive_otlp.step);
    examples_step.dependOn(&run_simple_trace_sdk.step);
    examples_step.dependOn(&run_comprehensive_trace_sdk.step);
    examples_step.dependOn(&run_simple_trace_otlp.step);
    examples_step.dependOn(&run_sampling_test.step);
    examples_step.dependOn(&run_batch_spans.step);
    examples_step.dependOn(&run_simple_batch_test.step);
}
