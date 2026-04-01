//! DNS Query Logging Example with OTLP Export
//!
//! This example demonstrates OpenTelemetry logging using the OTLP exporter
//! to send logs to an OpenTelemetry Collector or compatible backend.
//! It performs a DNS query for google.com and logs the entire process,
//! including application lifecycle events.
//!
//! ## Prerequisites
//! You'll need an OTLP-compatible receiver running, such as:
//! - OpenTelemetry Collector on http://localhost:4318
//! - Any cloud provider OTLP endpoint
//!
//! ## Setup
//! Start an OpenTelemetry Collector with OTLP HTTP receiver:
//! ```yaml
//! receivers:
//!   otlp:
//!     protocols:
//!       http:
//!         endpoint: 0.0.0.0:4318
//! processors:
//!   batch:
//! exporters:
//!   logging:
//!     loglevel: debug
//! service:
//!   pipelines:
//!     logs:
//!       receivers: [otlp]
//!       processors: [batch]
//!       exporters: [logging]
//! ```

const std = @import("std");
const io = std.Options.debug_io;
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up global providers at program exit
    defer otel_api.provider_registry.unsetAllProviders();

    // Setup global provider with pipeline configuration in one call
    const exporter_config = otel_exporters.otlp.OtlpExporterConfig{
        .endpoint = "http://localhost:4318",
        .transport = .http_protobuf,
    };
    const provider = try otel_sdk.logs.setupGlobalProvider(allocator, .{
        otel_sdk.logs.SimpleLogRecordProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.otlp.OtlpLogExporter.PipelineStep.init(exporter_config)),
    });
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Create execution context
    const ctx = &[_]otel_api.ContextKeyValue{};

    const scope = otel_api.InstrumentationScope{ .name = "dns.query.example", .version = "1.0.0" };
    var app_logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);

    // Log application startup using proper log records
    const startup_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "app.name", .value = .{ .string = "dns-query-otlp-example" } })
        .add(.{ .key = "app.version", .value = .{ .string = "1.0.0" } })
        .add(.{ .key = "app.language", .value = .{ .string = "zig" } })
        .add(.{ .key = "event.type", .value = .{ .string = "application.startup" } })
        .add(.{ .key = "exporter.type", .value = .{ .string = "otlp" } })
        .add(.{ .key = "exporter.endpoint", .value = .{ .string = "http://localhost:4318" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, startup_attrs);
    app_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS Query OTLP Example application starting" }, // body
        startup_attrs, // attributes
        @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)), // timestamp_ns
        null, // observed_timestamp_ns
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Log OTLP connectivity info
    const connectivity_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "otlp.endpoint", .value = .{ .string = "http://localhost:4318" } })
        .add(.{ .key = "otlp.protocol", .value = .{ .string = "http/json" } })
        .add(.{ .key = "otlp.path", .value = .{ .string = "/v1/logs" } })
        .add(.{ .key = "check.type", .value = .{ .string = "connectivity_info" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, connectivity_attrs);
    app_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "OTLP exporter configured - ensure collector is running on localhost:4318" }, // body
        connectivity_attrs, // attributes
        @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)), // timestamp_ns
        null, // observed_timestamp_ns
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Perform DNS query with comprehensive logging
    try performDnsQuery(ctx, allocator);

    // Log application shutdown
    const shutdown_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "event.type", .value = .{ .string = "application.shutdown" } })
        .add(.{ .key = "app.exit_code", .value = .{ .int = 0 } })
        .add(.{ .key = "exporter.type", .value = .{ .string = "otlp" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, shutdown_attrs);
    app_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS Query OTLP Example application shutting down" }, // body
        shutdown_attrs, // attributes
        @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)), // timestamp_ns
        null, // observed_timestamp_ns
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Give OTLP exporter time to send final logs
    std.log.info("Waiting for OTLP exporter to flush remaining logs...", .{});
    io.sleep(.{ .nanoseconds = std.time.ns_per_ms * 100 }, .real) catch {};

    // OTLP logging resources will be automatically cleaned up by defer setup.deinit()
    std.log.info("OTLP logging exporter will be shut down automatically...", .{});

    // Final status check
    std.log.info("DNS Query OTLP Example completed successfully.", .{});
}

fn performDnsQuery(ctx: []const otel_api.ContextKeyValue, allocator: std.mem.Allocator) !void {
    const hostname = "google.com";

    // Get DNS operation logger from global registry
    const scope = otel_api.InstrumentationScope{ .name = "dns.resolver.otlp" };
    var dns_logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);

    // Log DNS query initiation
    dns_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "Initiating DNS query for hostname: google.com via OTLP" }, // body
        null, // attributes
        @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)), // timestamp_ns
        null, // observed_timestamp_ns
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Log detailed operation start
    const start_time = @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds));
    const dns_start_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "dns.hostname", .value = .{ .string = hostname } })
        .add(.{ .key = "dns.query_type", .value = .{ .string = "A" } })
        .add(.{ .key = "operation.type", .value = .{ .string = "dns_resolution" } })
        .add(.{ .key = "operation.status", .value = .{ .string = "started" } })
        .add(.{ .key = "telemetry.exporter", .value = .{ .string = "otlp" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, dns_start_attrs);
    dns_logger.emitLogRecord(
        ctx,
        .debug, // severity
        .{ .string = "DNS resolution starting" }, // body
        dns_start_attrs, // attributes
        start_time, // timestamp_ns
        null, // observed_timestamp_ns
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Perform the actual DNS lookup

    const address_list = std.net.getAddressList(allocator, hostname, 80) catch |err| {
        // Log comprehensive DNS query failure information
        const duration_ns = @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)) - start_time;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

        // Determine error category and provide specific guidance
        const error_category = switch (err) {
            error.NameServerFailure => "dns_server_error",
            error.UnknownHostName => "hostname_not_found",
            error.NetworkNotFound => "network_connectivity",
            error.TemporaryNameServerFailure => "temporary_dns_failure",
            error.OutOfMemory => "memory_allocation",
            else => "unknown_dns_error",
        };

        const error_message = switch (err) {
            error.NameServerFailure => "DNS server returned a failure response - check DNS server configuration",
            error.UnknownHostName => "Hostname does not exist or cannot be resolved - verify the hostname is correct",
            error.NetworkNotFound => "Network is unreachable - check internet connectivity and firewall settings",
            error.TemporaryNameServerFailure => "Temporary DNS server failure - retry may succeed",
            error.OutOfMemory => "Insufficient memory for DNS resolution - check available system memory",
            else => "Unknown DNS resolution error occurred",
        };

        const error_attrs = try otel_api.common.AttributeBuilder.init(allocator)
            .add(.{ .key = "dns.hostname", .value = .{ .string = hostname } })
            .add(.{ .key = "error.type", .value = .{ .string = @errorName(err) } })
            .add(.{ .key = "error.category", .value = .{ .string = error_category } })
            .add(.{ .key = "error.message", .value = .{ .string = error_message } })
            .add(.{ .key = "operation.status", .value = .{ .string = "failed" } })
            .add(.{ .key = "dns.duration_ns", .value = .{ .int = duration_ns } })
            .add(.{ .key = "dns.duration_ms", .value = .{ .float = duration_ms } })
            .add(.{ .key = "telemetry.exporter", .value = .{ .string = "otlp" } })
            .add(.{ .key = "diagnostic.suggestion", .value = .{ .string = "Check network connectivity and DNS configuration" } })
            .finish(allocator);
        defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, error_attrs);
        dns_logger.emitLogRecord(
            ctx,
            .@"error", // severity
            .{ .string = error_message }, // body
            error_attrs, // attributes
            @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)), // timestamp_ns
            null, // observed_timestamp_ns
            null, // event_name
            null, // severity_text
            null, // trace_id
            null, // span_id
            null, // flags
        );

        // Also log to stderr for immediate user feedback
        std.log.err("DNS Resolution Failed:", .{});
        std.log.err("  Hostname: {s}", .{hostname});
        std.log.err("  Error: {s} ({s})", .{ @errorName(err), error_message });
        std.log.err("  Duration: {d:.2}ms", .{duration_ms});
        std.log.err("  Category: {s}", .{error_category});
        std.log.err("", .{});
        if (err == error.NetworkNotFound) {
            std.log.err("Troubleshooting steps:", .{});
            std.log.err("  1. Check internet connection", .{});
            std.log.err("  2. Verify DNS servers are configured", .{});
            std.log.err("  3. Try 'ping google.com' from command line", .{});
            std.log.err("  4. Check firewall/proxy settings", .{});
        }

        return err;
    };
    defer address_list.deinit();

    const end_time = @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds));
    const duration_ns = end_time - start_time;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    // Log successful DNS resolution
    const success_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "dns.hostname", .value = .{ .string = hostname } })
        .add(.{ .key = "dns.resolved_count", .value = .{ .int = @as(i64, @intCast(address_list.addrs.len)) } })
        .add(.{ .key = "dns.duration_ns", .value = .{ .int = @as(i64, @intCast(duration_ns)) } })
        .add(.{ .key = "dns.duration_ms", .value = .{ .float = duration_ms } })
        .add(.{ .key = "operation.status", .value = .{ .string = "completed" } })
        .add(.{ .key = "telemetry.exporter", .value = .{ .string = "otlp" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, success_attrs);
    dns_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS query completed successfully" }, // body
        success_attrs, // attributes
        end_time, // timestamp_ns
        null, // observed_timestamp_ns
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Log each resolved IP address
    for (address_list.addrs, 0..) |addr, i| {
        const ip_str = try std.fmt.allocPrint(allocator, "{f}", .{addr.in});
        defer allocator.free(ip_str);

        const ip_attrs = try otel_api.common.AttributeBuilder.init(allocator)
            .add(.{ .key = "dns.hostname", .value = .{ .string = hostname } })
            .add(.{ .key = "dns.resolved_ip", .value = .{ .string = ip_str } })
            .add(.{ .key = "dns.resolution_index", .value = .{ .int = @as(i64, @intCast(i)) } })
            .add(.{ .key = "dns.address_family", .value = .{ .string = "ipv4" } })
            .add(.{ .key = "telemetry.exporter", .value = .{ .string = "otlp" } })
            .finish(allocator);
        defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, ip_attrs);
        dns_logger.emitLogRecord(
            ctx,
            .debug, // severity
            .{ .string = "Resolved IP address" }, // body
            ip_attrs, // attributes
            @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)), // timestamp_ns
            null, // observed_timestamp_ns
            null, // event_name
            null, // severity_text
            null, // trace_id
            null, // span_id
            null, // flags
        );
    }

    // Log summary statistics
    const summary_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "dns.hostname", .value = .{ .string = hostname } })
        .add(.{ .key = "dns.resolved_count", .value = .{ .int = @as(i64, @intCast(address_list.addrs.len)) } })
        .add(.{ .key = "dns.duration_ms", .value = .{ .float = duration_ms } })
        .add(.{ .key = "telemetry.exporter", .value = .{ .string = "otlp" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, summary_attrs);
    dns_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS resolution summary: google.com resolved to multiple addresses" }, // body
        summary_attrs, // attributes
        @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)), // timestamp_ns
        null, // observed_timestamp_ns
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );
}
