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

    // Add exporters import to SDK module (needed for setup functions)
    otel_sdk_mod.addImport("otel-exporters", otel_exporters_mod);

    _ = b.addModule("otel-exporters", .{
        .root_source_file = b.path("src/exporters/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel-api", .module = otel_api_mod },
            .{ .name = "otel-sdk", .module = otel_sdk_mod },
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
    
    const run_metrics_demo = b.addRunArtifact(metrics_demo_example);
    const metrics_demo_step = b.step("example-metrics", "Run metrics demo example");
    metrics_demo_step.dependOn(&run_metrics_demo.step);

    // Metrics OTLP Demo Example
    const metrics_otlp_demo_example = b.addExecutable(.{
        .name = "metrics_otlp_demo",
        .root_source_file = b.path("examples/metrics_otlp_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    metrics_otlp_demo_example.root_module.addImport("otel-api", otel_api_mod);
    metrics_otlp_demo_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    metrics_otlp_demo_example.root_module.addImport("otel-exporters", otel_exporters_mod);
    
    const run_metrics_otlp_demo = b.addRunArtifact(metrics_otlp_demo_example);
    const metrics_otlp_demo_step = b.step("example-metrics-otlp", "Run metrics OTLP demo example");
    metrics_otlp_demo_step.dependOn(&run_metrics_otlp_demo.step);

    // All examples step
    const examples_step = b.step("examples", "Run all examples");
    examples_step.dependOn(&run_dns_query.step);
    examples_step.dependOn(&run_dns_query_otlp.step);
    examples_step.dependOn(&run_metrics_demo.step);
    examples_step.dependOn(&run_metrics_otlp_demo.step);
}