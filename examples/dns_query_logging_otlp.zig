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
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // One-line OTLP logging setup - sends to localhost:4318 by default
    const config = otel_exporters.otlp.OtlpExporterConfig{
        .endpoint = "http://localhost:4318",
        .transport = .http_json,
    };
    var setup = otel_sdk.setup.otlpLogging(allocator, config) catch |err| {
        std.log.err("Failed to initialize OTLP logging exporter: {s}", .{@errorName(err)});
        return err;
    };
    defer setup.deinit();

    // Create execution context
    var ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    // Get application logger from global registry (now backed by OTLP exporter)
    const app_logger = try otel_api.provider_registry.getGlobalLoggerWithVersion("dns.query.example.otlp", "1.0.0");

    // Log application startup using proper log records
    const startup_attrs = [_]otel_api.common.KeyValue{
        otel_api.common.KeyValue.init("app.name", .{ .string = "dns-query-otlp-example" }),
        otel_api.common.KeyValue.init("app.version", .{ .string = "1.0.0" }),
        otel_api.common.KeyValue.init("app.language", .{ .string = "zig" }),
        otel_api.common.KeyValue.init("event.type", .{ .string = "application.startup" }),
        otel_api.common.KeyValue.init("exporter.type", .{ .string = "otlp" }),
        otel_api.common.KeyValue.init("exporter.endpoint", .{ .string = "http://localhost:4318" }),
    };
    const startup_record = otel_api.logs.LogRecord{
        .severity_number = .info,
        .body = .{ .string = "DNS Query OTLP Example application starting" },
        .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        .attributes = &startup_attrs,
    };
    app_logger.emitLogRecord(ctx, startup_record);

    // Log OTLP connectivity info
    const connectivity_attrs = [_]otel_api.common.KeyValue{
        otel_api.common.KeyValue.init("otlp.endpoint", .{ .string = "http://localhost:4318" }),
        otel_api.common.KeyValue.init("otlp.protocol", .{ .string = "http/json" }),
        otel_api.common.KeyValue.init("otlp.path", .{ .string = "/v1/logs" }),
        otel_api.common.KeyValue.init("check.type", .{ .string = "connectivity_info" }),
    };
    const connectivity_record = otel_api.logs.LogRecord{
        .severity_number = .info,
        .body = .{ .string = "OTLP exporter configured - ensure collector is running on localhost:4318" },
        .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        .attributes = &connectivity_attrs,
    };
    app_logger.emitLogRecord(ctx, connectivity_record);

    // Perform DNS query with comprehensive logging
    try performDnsQuery(ctx, allocator);

    // Log application shutdown
    const shutdown_attrs = [_]otel_api.common.KeyValue{
        otel_api.common.KeyValue.init("event.type", .{ .string = "application.shutdown" }),
        otel_api.common.KeyValue.init("app.exit_code", .{ .int = 0 }),
        otel_api.common.KeyValue.init("exporter.type", .{ .string = "otlp" }),
    };
    const shutdown_record = otel_api.logs.LogRecord{
        .severity_number = .info,
        .body = .{ .string = "DNS Query OTLP Example application shutting down" },
        .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        .attributes = &shutdown_attrs,
    };
    app_logger.emitLogRecord(ctx, shutdown_record);

    // Give OTLP exporter time to send final logs
    std.log.info("Waiting for OTLP exporter to flush remaining logs...", .{});
    std.time.sleep(std.time.ns_per_ms * 100);

    // OTLP logging resources will be automatically cleaned up by defer setup.deinit()
    std.log.info("OTLP logging exporter will be shut down automatically...", .{});

    // Final status check
    std.log.info("DNS Query OTLP Example completed successfully.", .{});
    std.log.info("Check your OTLP collector logs to verify log delivery.", .{});
    std.log.info("If no logs appear in collector, check:", .{});
    std.log.info("  - Collector is running on localhost:4318", .{});
    std.log.info("  - Collector configuration accepts HTTP OTLP logs", .{});
    std.log.info("  - No firewall blocking port 4318", .{});
    std.log.info("", .{});
}

fn performDnsQuery(ctx: otel_api.Context, allocator: std.mem.Allocator) !void {
    const hostname = "google.com";

    // Get DNS operation logger from global registry
    const dns_logger = try otel_api.provider_registry.getGlobalLogger("dns.resolver.otlp");

    // Log DNS query initiation
    const info_record = otel_api.logs.LogRecord{
        .severity_number = .info,
        .body = .{ .string = "Initiating DNS query for hostname: google.com via OTLP" },
        .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
    };
    dns_logger.emitLogRecord(ctx, info_record);

    // Log detailed operation start
    const dns_start_attrs = [_]otel_api.common.KeyValue{
        otel_api.common.KeyValue.init("dns.hostname", .{ .string = hostname }),
        otel_api.common.KeyValue.init("dns.query_type", .{ .string = "A" }),
        otel_api.common.KeyValue.init("operation.type", .{ .string = "dns_resolution" }),
        otel_api.common.KeyValue.init("operation.status", .{ .string = "started" }),
        otel_api.common.KeyValue.init("telemetry.exporter", .{ .string = "otlp" }),
    };
    const dns_start_record = otel_api.logs.LogRecord{
        .severity_number = .debug,
        .body = .{ .string = "DNS resolution starting" },
        .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        .attributes = &dns_start_attrs,
    };
    dns_logger.emitLogRecord(ctx, dns_start_record);

    // Perform the actual DNS lookup
    const start_time = @as(i64, @intCast(std.time.nanoTimestamp()));

    const address_list = std.net.getAddressList(allocator, hostname, 80) catch |err| {
        // Log comprehensive DNS query failure information
        const duration_ns = @as(i64, @intCast(std.time.nanoTimestamp())) - start_time;
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

        const error_attrs = [_]otel_api.common.KeyValue{
            otel_api.common.KeyValue.init("dns.hostname", .{ .string = hostname }),
            otel_api.common.KeyValue.init("error.type", .{ .string = @errorName(err) }),
            otel_api.common.KeyValue.init("error.category", .{ .string = error_category }),
            otel_api.common.KeyValue.init("error.message", .{ .string = error_message }),
            otel_api.common.KeyValue.init("operation.status", .{ .string = "failed" }),
            otel_api.common.KeyValue.init("dns.duration_ns", .{ .int = duration_ns }),
            otel_api.common.KeyValue.init("dns.duration_ms", .{ .float = duration_ms }),
            otel_api.common.KeyValue.init("telemetry.exporter", .{ .string = "otlp" }),
            otel_api.common.KeyValue.init("diagnostic.suggestion", .{ .string = "Check network connectivity and DNS configuration" }),
        };
        const error_record = otel_api.logs.LogRecord{
            .severity_number = .@"error",
            .body = .{ .string = error_message },
            .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
            .attributes = &error_attrs,
        };
        dns_logger.emitLogRecord(ctx, error_record);

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

    const end_time = @as(i64, @intCast(std.time.nanoTimestamp()));
    const duration_ns = end_time - start_time;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    // Log successful DNS resolution
    const success_attrs = [_]otel_api.common.KeyValue{
        otel_api.common.KeyValue.init("dns.hostname", .{ .string = hostname }),
        otel_api.common.KeyValue.init("dns.resolved_count", .{ .int = @as(i64, @intCast(address_list.addrs.len)) }),
        otel_api.common.KeyValue.init("dns.duration_ns", .{ .int = @as(i64, @intCast(duration_ns)) }),
        otel_api.common.KeyValue.init("dns.duration_ms", .{ .float = duration_ms }),
        otel_api.common.KeyValue.init("operation.status", .{ .string = "completed" }),
        otel_api.common.KeyValue.init("telemetry.exporter", .{ .string = "otlp" }),
    };
    const success_record = otel_api.logs.LogRecord{
        .severity_number = .info,
        .body = .{ .string = "DNS query completed successfully" },
        .timestamp_ns = end_time,
        .attributes = &success_attrs,
    };
    dns_logger.emitLogRecord(ctx, success_record);

    // Log each resolved IP address
    for (address_list.addrs, 0..) |addr, i| {
        const ip_str = try std.fmt.allocPrint(allocator, "{}", .{addr.in});
        defer allocator.free(ip_str);

        const ip_attrs = [_]otel_api.common.KeyValue{
            otel_api.common.KeyValue.init("dns.hostname", .{ .string = hostname }),
            otel_api.common.KeyValue.init("dns.resolved_ip", .{ .string = ip_str }),
            otel_api.common.KeyValue.init("dns.resolution_index", .{ .int = @as(i64, @intCast(i)) }),
            otel_api.common.KeyValue.init("dns.address_family", .{ .string = "ipv4" }),
            otel_api.common.KeyValue.init("telemetry.exporter", .{ .string = "otlp" }),
        };
        const ip_record = otel_api.logs.LogRecord{
            .severity_number = .debug,
            .body = .{ .string = "Resolved IP address" },
            .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
            .attributes = &ip_attrs,
        };
        dns_logger.emitLogRecord(ctx, ip_record);
    }

    // Log summary statistics
    const summary_attrs = [_]otel_api.common.KeyValue{
        otel_api.common.KeyValue.init("dns.hostname", .{ .string = hostname }),
        otel_api.common.KeyValue.init("dns.resolved_count", .{ .int = @as(i64, @intCast(address_list.addrs.len)) }),
        otel_api.common.KeyValue.init("dns.duration_ms", .{ .float = duration_ms }),
        otel_api.common.KeyValue.init("telemetry.exporter", .{ .string = "otlp" }),
    };
    const summary_record = otel_api.logs.LogRecord{
        .severity_number = .info,
        .body = .{ .string = "DNS resolution summary: google.com resolved to multiple addresses" },
        .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        .attributes = &summary_attrs,
    };
    dns_logger.emitLogRecord(ctx, summary_record);
}
