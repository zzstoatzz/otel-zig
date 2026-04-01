//! DNS Query Logging Example using std.log bridge with OTLP
//!
//! This example demonstrates how existing std.log code can automatically emit
//! OpenTelemetry log records through the std.log bridge, with no changes to
//! existing logging calls. All logs are exported via OTLP.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");
const io = std.Options.debug_io;

// Configure std.log to use OpenTelemetry bridge
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = otel_sdk.std_log_bridge.otelLogFn,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up global providers at program exit
    defer otel_api.provider_registry.unsetAllProviders();

    // Setup global OTel logging provider with OTLP exporter
    const provider = try otel_sdk.logs.setupGlobalProvider(
        allocator,
        .{otel_sdk.logs.SimpleLogRecordProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.otlp.OtlpLogExporter.PipelineStep.init(.{}))},
    );
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Initialize the std.log bridge
    try otel_sdk.std_log_bridge.init(.{
        .enabled = true,
        .include_scope_attribute = true,
        .instrumentation_scope_name = "dns.query.std_log.example",
        .instrumentation_scope_version = "1.0.0",
    });
    defer otel_sdk.std_log_bridge.deinit();

    // Now all std.log calls will automatically emit OpenTelemetry log records!

    // Log application startup using standard std.log
    std.log.info("DNS Query Example application starting (using std.log bridge)", .{});

    // Perform DNS query with std.log calls
    try performDnsQuery(allocator);

    // Log application shutdown
    std.log.info("DNS Query Example application shutting down", .{});

    // Give OTLP exporter time to flush
    io.sleep(.{ .nanoseconds = 1 * std.time.ns_per_s }, .real) catch {};
}

fn performDnsQuery(allocator: std.mem.Allocator) !void {
    const hostname = "google.com";

    // Create scoped logger for DNS operations
    const dns_log = std.log.scoped(.dns_resolver);

    // Log DNS query initiation - this will become an OTel log record automatically
    dns_log.info("Initiating DNS query for hostname: {s}", .{hostname});

    // Log detailed operation start
    dns_log.debug("DNS resolution starting for {s}", .{hostname});

    // Perform the actual DNS lookup
    const address_list = std.net.getAddressList(allocator, hostname, 80) catch |err| {
        // Log DNS query failure using std.log
        dns_log.err("DNS query failed for {s}: {}", .{ hostname, err });
        return err;
    };
    defer address_list.deinit();

    // Calculate timing information
    const addr_count = address_list.addrs.len;

    // Log successful DNS resolution
    dns_log.info("DNS query completed successfully for {s} - resolved {} addresses", .{ hostname, addr_count });

    // Create scoped logger for detailed IP logging
    const ip_log = std.log.scoped(.ip_resolver);

    // Log each resolved IP address
    for (address_list.addrs, 0..) |addr, i| {
        const ip_str = try std.fmt.allocPrint(allocator, "{f}", .{addr.in});
        defer allocator.free(ip_str);

        ip_log.debug("Resolved IP address #{}: {s} for {s}", .{ i, ip_str, hostname });
    }

    // Use application-specific scoped logger
    const app_log = std.log.scoped(.application);
    app_log.info("DNS resolution summary: {s} resolved to {} addresses", .{ hostname, addr_count });

    // Demonstrate different log levels
    app_log.debug("Debug: DNS lookup operation completed successfully", .{});
    app_log.warn("Warning: This is just a demo warning message", .{});

    // Show error logging (this won't actually error)
    if (addr_count == 0) {
        app_log.err("Error: No IP addresses resolved for {s}", .{hostname});
    }

    // Performance/monitoring scoped logger
    const perf_log = std.log.scoped(.performance);
    perf_log.info("Operation metrics - hostname: {s}, resolved_count: {}, operation: dns_query", .{ hostname, addr_count });

    // Security-related scoped logger
    const security_log = std.log.scoped(.security);
    security_log.debug("DNS query performed for external hostname: {s}", .{hostname});

    // System-level scoped logger
    const system_log = std.log.scoped(.system);
    system_log.info("Network operation completed - DNS resolution for {s}", .{hostname});
}
