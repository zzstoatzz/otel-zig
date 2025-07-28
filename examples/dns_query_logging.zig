//! DNS Query Logging Example
//!
//! This example demonstrates OpenTelemetry logging using the new bridge pattern
//! and setup functions. It performs a DNS query for google.com and logs the
//! entire process, including application lifecycle events.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up global providers at program exit
    defer otel_api.provider_registry.unsetAllProviders();

    // Setup global provider with pipeline configuration in one call
    const provider = try otel_sdk.logs.setupGlobalProvider(allocator, .{otel_sdk.logs.SimpleLogRecordProcessor.PipelineStep.init({})
        .flowTo(otel_exporters.console.StreamLogExporter(std.fs.File.Writer).PipelineStep.init(.{}))});
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Get application logger from global registry (now backed by SDK)
    const scope = try otel_api.InstrumentationScope.initSimple("dns.query.example", "1.0.0");
    var app_logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);

    // Create execution context
    var ctx = otel_api.Context.empty(allocator);
    defer ctx.deinit();

    // Log application startup using proper log records
    const startup_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add("app.name", .{ .string = "dns-query-example" })
        .add("app.version", .{ .string = "1.0.0" })
        .add("app.language", .{ .string = "zig" })
        .add("event.type", .{ .string = "application.startup" })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, startup_attrs);

    app_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS Query Example application starting" }, // body
        startup_attrs, // attributes
        @as(i64, @intCast(std.time.nanoTimestamp())), // timestamp_ns
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
        .add("event.type", .{ .string = "application.shutdown" })
        .add("app.exit_code", .{ .int = 0 })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, shutdown_attrs);

    app_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS Query Example application shutting down" }, // body
        shutdown_attrs, // attributes
        @as(i64, @intCast(std.time.nanoTimestamp())), // timestamp_ns
        null, // observed_timestamp_ns
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );
}

fn performDnsQuery(ctx: otel_api.Context, allocator: std.mem.Allocator) !void {
    const hostname = "google.com";

    // Get DNS operation logger from global registry
    const scope = try otel_api.InstrumentationScope.initWithName("dns.resolver");
    var dns_logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);

    // Log DNS query initiation
    dns_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "Initiating DNS query for hostname: google.com" }, // body
        null, // attributes
        @as(i64, @intCast(std.time.nanoTimestamp())), // timestamp_ns
        null, // observed_timestamp_ns
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Log detailed operation start
    const start_time = @as(i64, @intCast(std.time.nanoTimestamp()));
    const dns_start_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add("dns.hostname", .{ .string = hostname })
        .add("operation.name", .{ .string = "dns_query" })
        .add("operation.type", .{ .string = "dns_resolution" })
        .add("operation.status", .{ .string = "started" })
        .finish(allocator);
    defer otel_api.AttributeKeyValue.deinitOwnedSlice(allocator, dns_start_attrs);
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
        // Log DNS query failure
        const duration_ns = @as(i64, @intCast(std.time.nanoTimestamp())) - start_time;
        const error_attrs = try otel_api.common.AttributeBuilder.init(allocator)
            .add("dns.hostname", .{ .string = hostname })
            .add("error.type", .{ .string = @errorName(err) })
            .add("operation.status", .{ .string = "failed" })
            .add("dns.duration_ns", .{ .int = duration_ns })
            .finish(allocator);
        defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, error_attrs);
        dns_logger.emitLogRecord(
            ctx,
            .@"error", // severity
            .{ .string = "DNS query failed" }, // body
            error_attrs, // attributes
            @as(i64, @intCast(std.time.nanoTimestamp())), // timestamp_ns
            null, // observed_timestamp_ns
            null, // event_name
            null, // severity_text
            null, // trace_id
            null, // span_id
            null, // flags
        );
        return err;
    };
    defer address_list.deinit();

    const end_time = @as(i64, @intCast(std.time.nanoTimestamp()));
    const duration_ns = end_time - start_time;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    // Log successful DNS resolution
    const success_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add("dns.hostname", .{ .string = hostname })
        .add("dns.resolved_count", .{ .int = @as(i64, @intCast(address_list.addrs.len)) })
        .add("dns.duration_ns", .{ .int = @as(i64, @intCast(duration_ns)) })
        .add("dns.duration_ms", .{ .float = duration_ms })
        .add("operation.status", .{ .string = "completed" })
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
        const ip_str = try std.fmt.allocPrint(allocator, "{}", .{addr.in});
        defer allocator.free(ip_str);

        const ip_attrs = try otel_api.common.AttributeBuilder.init(allocator)
            .add("dns.hostname", .{ .string = hostname })
            .add("dns.resolved_ip", .{ .string = ip_str })
            .add("dns.resolution_index", .{ .int = @as(i64, @intCast(i)) })
            .add("dns.address_family", .{ .string = "ipv4" })
            .finish(allocator);
        defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, ip_attrs);
        dns_logger.emitLogRecord(
            ctx,
            .debug, // severity
            .{ .string = "Resolved IP address" }, // body
            ip_attrs, // attributes
            @as(i64, @intCast(std.time.nanoTimestamp())), // timestamp_ns
            null, // observed_timestamp_ns
            null, // event_name
            null, // severity_text
            null, // trace_id
            null, // span_id
            null, // flags
        );
    }

    // Log summary statistics
    dns_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS resolution summary: google.com resolved to multiple addresses" }, // body
        null, // attributes
        @as(i64, @intCast(std.time.nanoTimestamp())), // timestamp_ns
        null, // observed_timestamp_ns
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );
}
