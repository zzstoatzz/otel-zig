//! DNS Query Logging Example
//!
//! This example demonstrates OpenTelemetry logging using the new bridge pattern
//! and setup functions. It performs a DNS query for google.com and logs the
//! entire process, including application lifecycle events.
//!
//! With the bridge pattern, setting up logging is now a single line!

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // One-line logging setup with the new bridge pattern!
    var setup = try otel_sdk.setup.consoleLogging(allocator, .info);
    defer setup.deinit();

    // Create execution context
    var ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    // Get application logger from global registry (now backed by SDK)
    const app_logger = try otel_api.provider_registry.getGlobalLoggerWithVersion("dns.query.example", "1.0.0");

    // Log application startup using proper log records
    const startup_attrs = [_]otel_api.common.KeyValue{
        otel_api.common.KeyValue.init("app.name", .{ .string = "dns-query-example" }),
        otel_api.common.KeyValue.init("app.version", .{ .string = "1.0.0" }),
        otel_api.common.KeyValue.init("app.language", .{ .string = "zig" }),
        otel_api.common.KeyValue.init("event.type", .{ .string = "application.startup" }),
    };
    const startup_record = otel_api.logs.LogRecord{
        .severity_number = .info,
        .body = .{ .string = "DNS Query Example application starting" },
        .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        .attributes = &startup_attrs,
    };
    app_logger.emitLogRecord(ctx, startup_record);

    // Perform DNS query with comprehensive logging
    try performDnsQuery(ctx, allocator);

    // Log application shutdown
    const shutdown_attrs = [_]otel_api.common.KeyValue{
        otel_api.common.KeyValue.init("event.type", .{ .string = "application.shutdown" }),
        otel_api.common.KeyValue.init("app.exit_code", .{ .int = 0 }),
    };
    const shutdown_record = otel_api.logs.LogRecord{
        .severity_number = .info,
        .body = .{ .string = "DNS Query Example application shutting down" },
        .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        .attributes = &shutdown_attrs,
    };
    app_logger.emitLogRecord(ctx, shutdown_record);
}

fn performDnsQuery(ctx: otel_api.Context, allocator: std.mem.Allocator) !void {
    const hostname = "google.com";

    // Get DNS operation logger from global registry
    const dns_logger = try otel_api.provider_registry.getGlobalLogger("dns.resolver");

    // Log DNS query initiation
    const info_record = otel_api.logs.LogRecord{
        .severity_number = .info,
        .body = .{ .string = "Initiating DNS query for hostname: google.com" },
        .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
    };
    dns_logger.emitLogRecord(ctx, info_record);

    // Log detailed operation start
    const dns_start_attrs = [_]otel_api.common.KeyValue{
        otel_api.common.KeyValue.init("dns.hostname", .{ .string = hostname }),
        otel_api.common.KeyValue.init("dns.query_type", .{ .string = "A" }),
        otel_api.common.KeyValue.init("operation.type", .{ .string = "dns_resolution" }),
        otel_api.common.KeyValue.init("operation.status", .{ .string = "started" }),
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
        // Log DNS query failure
        const duration_ns = @as(i64, @intCast(std.time.nanoTimestamp())) - start_time;
        const error_attrs = [_]otel_api.common.KeyValue{
            otel_api.common.KeyValue.init("dns.hostname", .{ .string = hostname }),
            otel_api.common.KeyValue.init("error.type", .{ .string = @errorName(err) }),
            otel_api.common.KeyValue.init("operation.status", .{ .string = "failed" }),
            otel_api.common.KeyValue.init("dns.duration_ns", .{ .int = duration_ns }),
        };
        const error_record = otel_api.logs.LogRecord{
            .severity_number = .@"error",
            .body = .{ .string = "DNS query failed" },
            .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
            .attributes = &error_attrs,
        };
        dns_logger.emitLogRecord(ctx, error_record);
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
    const summary_record = otel_api.logs.LogRecord{
        .severity_number = .info,
        .body = .{ .string = "DNS resolution summary: google.com resolved to multiple addresses" },
        .timestamp_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
    };
    dns_logger.emitLogRecord(ctx, summary_record);
}
