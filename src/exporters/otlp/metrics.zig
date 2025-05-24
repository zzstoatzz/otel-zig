//! OpenTelemetry Protocol (OTLP) Metric Exporter
//!
//! This module provides an OTLP exporter for metrics that sends
//! data to OTLP-compatible backends using HTTP/JSON transport.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/protocol/otlp.md

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

const ExportResult = otel_sdk.logs.ExportResult;
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const Resource = otel_sdk.resource.Resource;
const MetricData = otel_sdk.metrics.processor.MetricData;
const MetricDataPoint = otel_sdk.metrics.processor.MetricDataPoint;
const MetricType = otel_sdk.metrics.processor.MetricType;
const MetricExporter = otel_sdk.metrics.processor.MetricExporter;

// OTLP metric data structures
const OtlpResourceMetrics = struct {
    resource: OtlpResource,
    scopeMetrics: []const OtlpScopeMetrics,
};

const OtlpResource = struct {
    attributes: []const OtlpKeyValue,
};

const OtlpScopeMetrics = struct {
    scope: OtlpInstrumentationScope,
    metrics: []const OtlpMetric,
};

const OtlpInstrumentationScope = struct {
    name: []const u8,
    version: ?[]const u8,
    attributes: []const OtlpKeyValue,
};

const OtlpMetric = struct {
    name: []const u8,
    description: ?[]const u8,
    unit: ?[]const u8,
    // Use JSON dynamic typing for data field
    sum: ?OtlpSum = null,
    gauge: ?OtlpGauge = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);

        try jw.objectField("description");
        try jw.write(self.description);

        try jw.objectField("unit");
        try jw.write(self.unit);

        if (self.sum) |s| {
            try jw.objectField("sum");
            try jw.write(s);
        }

        if (self.gauge) |g| {
            try jw.objectField("gauge");
            try jw.write(g);
        }

        try jw.endObject();
    }
};

const OtlpSum = struct {
    dataPoints: []const OtlpNumberDataPoint,
    aggregationTemporality: i32 = 2, // CUMULATIVE
    isMonotonic: bool = true,
};

const OtlpGauge = struct {
    dataPoints: []const OtlpNumberDataPoint,
};

const OtlpNumberDataPoint = struct {
    attributes: []const OtlpKeyValue,
    timeUnixNano: []const u8, // String for JSON big numbers
    startTimeUnixNano: ?[]const u8 = null, // String for JSON big numbers
    value: union(enum) {
        asInt: i64,
        asDouble: f64,
    },

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("attributes");
        try jw.write(self.attributes);
        try jw.objectField("timeUnixNano");
        try jw.write(self.timeUnixNano);

        if (self.startTimeUnixNano) |stun| {
            try jw.objectField("startTimeUnixNano");
            try jw.write(stun);
        }

        switch (self.value) {
            .asInt => |i| {
                try jw.objectField("asInt");
                try jw.write(i);
            },
            .asDouble => |d| {
                try jw.objectField("asDouble");
                try jw.write(d);
            },
        }
        try jw.endObject();
    }
};

const OtlpKeyValue = struct {
    key: []const u8,
    value: OtlpAnyValue,
};

const OtlpAnyValue = union(enum) {
    stringValue: []const u8,
    intValue: i64,
    doubleValue: f64,
    boolValue: bool,
};

/// OTLP metric exporter implementation
pub const OtlpMetricExporter = struct {
    config: OtlpExporterConfig,
    allocator: std.mem.Allocator,
    is_shutdown: bool,
    mutex: std.Thread.Mutex,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, config: OtlpExporterConfig) OtlpMetricExporter {
        return .{
            .config = config,
            .allocator = allocator,
            .is_shutdown = false,
            .mutex = .{},
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *OtlpMetricExporter) void {
        self.http_client.deinit();
    }

    pub fn @"export"(self: *OtlpMetricExporter, metrics: []const MetricData) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Local arena for the OTLP transform and network send.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Convert metrics to OTLP format and send
        const json_data = convertToOtlpFormat(arena.allocator(), metrics) catch |err| {
            std.log.err("Failed to convert metrics to OTLP format: {}", .{err});
            return .failure;
        };
        defer arena.allocator().free(json_data);

        const result = self.sendRequest(arena.allocator(), json_data) catch |err| {
            std.log.err("Failed to send OTLP metrics: {}", .{err});
            return .failure;
        };

        return result;
    }

    pub fn forceFlush(self: *OtlpMetricExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        // HTTP requests are synchronous, nothing to flush
        return .success;
    }

    pub fn shutdown(self: *OtlpMetricExporter, timeout_ms: ?u64) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;
        _ = timeout_ms;

        // Nothing special to clean up for HTTP
        return .success;
    }

    fn sendRequest(self: *OtlpMetricExporter, allocator: std.mem.Allocator, json_data: []const u8) !ExportResult {
        // Parse endpoint URL with detailed error context
        const uri = std.Uri.parse(self.config.endpoint) catch |err| {
            std.log.err("OTLP URL Parsing Error: {s} - {s}", .{ self.config.endpoint, @errorName(err) });
            return err;
        };

        // Build full URL with logs path
        const host_str = switch (uri.host.?) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        const scheme_str = if (uri.scheme.len > 0) uri.scheme else "http";
        const full_url = try std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ scheme_str, host_str, uri.port orelse 4318, self.config.protocol_config.metrics_path });
        defer allocator.free(full_url);
        std.log.debug("OTLP Request Details. URL:{s} Method:{s} content-type:{s} content-length:{} data:{s}", .{ full_url, "POST", "application/json", json_data.len, json_data });

        // Create HTTP request
        const full_uri = try std.Uri.parse(full_url);
        var req = try self.http_client.open(.POST, full_uri, .{
            .server_header_buffer = try allocator.alloc(u8, 8192),
        });
        defer req.deinit();

        // Set request headers
        req.headers.content_type = .{ .override = "application/json" };
        req.transfer_encoding = .{ .content_length = @intCast(json_data.len) };

        // Add custom headers from config
        if (self.config.headers.len > 0) {
            var extra_headers = try allocator.alloc(std.http.Header, self.config.headers.len);
            for (self.config.headers, 0..) |header, h| {
                extra_headers[h] = header;
            }
            req.extra_headers = extra_headers;
        }

        // Send request
        try req.send();
        try req.writeAll(json_data);
        try req.finish();
        try req.wait();

        // Check response status
        switch (req.response.status) {
            .ok => return .success,
            .bad_request, .unauthorized, .forbidden, .not_found => {
                std.log.err("OTLP export failed with status: {}", .{req.response.status});
                return .failure;
            },
            else => {
                std.log.warn("OTLP export got unexpected status: {}", .{req.response.status});
                return .failure;
            },
        }
    }

    /// Get the vtable for MetricExporter interface
    pub fn vtable() MetricExporter.VTable {
        return .{
            .exportFn = exportWrapper,
            .forceFlush = forceFlushWrapper,
            .shutdown = shutdownWrapper,
        };
    }

    fn exportWrapper(ptr: *anyopaque, metrics: []const MetricData) ExportResult {
        const self = @as(*OtlpMetricExporter, @ptrCast(@alignCast(ptr)));
        return self.@"export"(metrics);
    }

    fn forceFlushWrapper(ptr: *anyopaque, timeout_ms: ?u64) ExportResult {
        const self = @as(*OtlpMetricExporter, @ptrCast(@alignCast(ptr)));
        return self.forceFlush(timeout_ms);
    }

    fn shutdownWrapper(ptr: *anyopaque, timeout_ms: ?u64) ExportResult {
        const self = @as(*OtlpMetricExporter, @ptrCast(@alignCast(ptr)));
        return self.shutdown(timeout_ms);
    }
};

fn convertToOtlpFormat(allocator: std.mem.Allocator, metrics: []const MetricData) ![]u8 {
    if (metrics.len == 0) {
        const empty_resource_metrics = OtlpResourceMetrics{
            .resource = OtlpResource{ .attributes = &[_]OtlpKeyValue{} },
            .scopeMetrics = &[_]OtlpScopeMetrics{},
        };

        var json_buffer = std.ArrayList(u8).init(allocator);
        defer json_buffer.deinit();
        try std.json.stringify(.{ .resourceMetrics = &[_]OtlpResourceMetrics{empty_resource_metrics} }, .{}, json_buffer.writer());
        return try json_buffer.toOwnedSlice();
    }

    // Convert resource attributes to OTLP format
    const resource = metrics[0].resource;
    var otlp_resource_attributes = std.ArrayList(OtlpKeyValue).init(allocator);
    defer otlp_resource_attributes.deinit();

    for (resource.attributes) |attr| {
        const otlp_value = switch (attr.value) {
            .string => |s| OtlpAnyValue{ .stringValue = s },
            .int => |int_val| OtlpAnyValue{ .intValue = int_val },
            .float => |f| OtlpAnyValue{ .doubleValue = f },
            .bool => |b| OtlpAnyValue{ .boolValue = b },
            .bool_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.appendSlice(if (item) "true" else "false");
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
            .int_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.writer().print("{}", .{item});
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
            .float_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.writer().print("{}", .{item});
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
            .string_array => |arr| blk: {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                try result.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try result.appendSlice(", ");
                    try result.writer().print("\"{s}\"", .{item});
                }
                try result.append(']');
                const str = try result.toOwnedSlice();
                break :blk OtlpAnyValue{ .stringValue = str };
            },
        };

        try otlp_resource_attributes.append(OtlpKeyValue{
            .key = attr.key,
            .value = otlp_value,
        });
    }

    // Group metrics by scope
    var scope_map = std.StringHashMap(std.ArrayList(MetricData)).init(allocator);
    defer {
        var iter = scope_map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        scope_map.deinit();
    }

    for (metrics) |metric| {
        const scope_key = metric.scope.name;
        var entry = try scope_map.getOrPut(scope_key);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(MetricData).init(allocator);
        }
        try entry.value_ptr.append(metric);
    }

    // Convert scope metrics to OTLP format
    var otlp_scope_metrics = std.ArrayList(OtlpScopeMetrics).init(allocator);
    defer otlp_scope_metrics.deinit();

    var scope_iter = scope_map.iterator();
    while (scope_iter.next()) |entry| {
        const scope_metrics = entry.value_ptr.items;
        if (scope_metrics.len == 0) continue;

        const scope = scope_metrics[0].scope;

        // Convert metrics to OTLP format
        var otlp_metrics = std.ArrayList(OtlpMetric).init(allocator);
        defer otlp_metrics.deinit();

        for (scope_metrics) |metric| {
            // Convert data points
            var otlp_data_points = std.ArrayList(OtlpNumberDataPoint).init(allocator);
            defer otlp_data_points.deinit();

            for (metric.data_points) |point| {
                // Convert attributes
                var otlp_attributes = std.ArrayList(OtlpKeyValue).init(allocator);
                defer otlp_attributes.deinit();

                for (point.attributes) |attr| {
                    const otlp_value = switch (attr.value) {
                        .string => |s| OtlpAnyValue{ .stringValue = s },
                        .int => |int_val| OtlpAnyValue{ .intValue = int_val },
                        .float => |f| OtlpAnyValue{ .doubleValue = f },
                        .bool => |b| OtlpAnyValue{ .boolValue = b },
                        .bool_array => |arr| blk: {
                            var result = std.ArrayList(u8).init(allocator);
                            defer result.deinit();
                            try result.append('[');
                            for (arr, 0..) |item, idx| {
                                if (idx > 0) try result.appendSlice(", ");
                                try result.appendSlice(if (item) "true" else "false");
                            }
                            try result.append(']');
                            const str = try result.toOwnedSlice();
                            break :blk OtlpAnyValue{ .stringValue = str };
                        },
                        .int_array => |arr| blk: {
                            var result = std.ArrayList(u8).init(allocator);
                            defer result.deinit();
                            try result.append('[');
                            for (arr, 0..) |item, idx| {
                                if (idx > 0) try result.appendSlice(", ");
                                try result.writer().print("{}", .{item});
                            }
                            try result.append(']');
                            const str = try result.toOwnedSlice();
                            break :blk OtlpAnyValue{ .stringValue = str };
                        },
                        .float_array => |arr| blk: {
                            var result = std.ArrayList(u8).init(allocator);
                            defer result.deinit();
                            try result.append('[');
                            for (arr, 0..) |item, idx| {
                                if (idx > 0) try result.appendSlice(", ");
                                try result.writer().print("{}", .{item});
                            }
                            try result.append(']');
                            const str = try result.toOwnedSlice();
                            break :blk OtlpAnyValue{ .stringValue = str };
                        },
                        .string_array => |arr| blk: {
                            var result = std.ArrayList(u8).init(allocator);
                            defer result.deinit();
                            try result.append('[');
                            for (arr, 0..) |item, idx| {
                                if (idx > 0) try result.appendSlice(", ");
                                try result.writer().print("\"{s}\"", .{item});
                            }
                            try result.append(']');
                            const str = try result.toOwnedSlice();
                            break :blk OtlpAnyValue{ .stringValue = str };
                        },
                    };

                    try otlp_attributes.append(OtlpKeyValue{
                        .key = attr.key,
                        .value = otlp_value,
                    });
                }

                // Convert timestamp to string
                const timestamp_str = try std.fmt.allocPrint(allocator, "{}", .{point.timestamp_ns});
                
                // Convert start timestamp to string for monotonic metrics
                const start_timestamp_str = if (point.start_timestamp_ns) |start_ts|
                    try std.fmt.allocPrint(allocator, "{}", .{start_ts})
                else
                    null;

                const data_point = OtlpNumberDataPoint{
                    .attributes = try otlp_attributes.toOwnedSlice(),
                    .timeUnixNano = timestamp_str,
                    .startTimeUnixNano = start_timestamp_str,
                    .value = switch (point.value) {
                        .i64_sum, .i64_gauge => |int_val| .{ .asInt = int_val },
                        .f64_sum, .f64_gauge => |double_val| .{ .asDouble = double_val },
                    },
                };

                try otlp_data_points.append(data_point);
            }

            // Create OTLP metric based on type
            const otlp_metric = switch (metric.type) {
                .sum => OtlpMetric{
                    .name = metric.name,
                    .description = metric.description,
                    .unit = metric.unit,
                    .sum = OtlpSum{
                        .dataPoints = try otlp_data_points.toOwnedSlice(),
                        .aggregationTemporality = 2, // AGGREGATION_TEMPORALITY_CUMULATIVE
                        .isMonotonic = true,
                    },
                    .gauge = null,
                },
                .gauge => OtlpMetric{
                    .name = metric.name,
                    .description = metric.description,
                    .unit = metric.unit,
                    .sum = null,
                    .gauge = OtlpGauge{
                        .dataPoints = try otlp_data_points.toOwnedSlice(),
                    },
                },
                else => OtlpMetric{
                    .name = metric.name,
                    .description = metric.description,
                    .unit = metric.unit,
                    .sum = null,
                    .gauge = OtlpGauge{
                        .dataPoints = try otlp_data_points.toOwnedSlice(),
                    },
                },
            };

            try otlp_metrics.append(otlp_metric);
        }

        const scope_metric = OtlpScopeMetrics{
            .scope = OtlpInstrumentationScope{
                .name = scope.name,
                .version = scope.version,
                .attributes = &[_]OtlpKeyValue{},
            },
            .metrics = try otlp_metrics.toOwnedSlice(),
        };

        try otlp_scope_metrics.append(scope_metric);
    }

    // Create OTLP structure
    const resource_metrics = OtlpResourceMetrics{
        .resource = OtlpResource{
            .attributes = try otlp_resource_attributes.toOwnedSlice(),
        },
        .scopeMetrics = try otlp_scope_metrics.toOwnedSlice(),
    };

    // Serialize to JSON
    var json_buffer = std.ArrayList(u8).init(allocator);
    defer json_buffer.deinit();

    try std.json.stringify(.{ .resourceMetrics = &[_]OtlpResourceMetrics{resource_metrics} }, .{ .emit_null_optional_fields = false }, json_buffer.writer());
    return try json_buffer.toOwnedSlice();
}

/// Create an OTLP metric exporter with default configuration
pub fn createMetricExporter(allocator: std.mem.Allocator) !*OtlpMetricExporter {
    return createMetricExporterWithConfig(allocator, .{});
}

/// Create an OTLP metric exporter with custom configuration
pub fn createMetricExporterWithConfig(allocator: std.mem.Allocator, config: OtlpExporterConfig) !*OtlpMetricExporter {
    const exporter = try allocator.create(OtlpMetricExporter);
    exporter.* = OtlpMetricExporter.init(allocator, config);
    return exporter;
}

/// Wrap an OTLP exporter as a MetricExporter
pub fn wrapAsMetricExporter(otlp_exporter: *OtlpMetricExporter) MetricExporter {
    return .{
        .ptr = otlp_exporter,
        .vtable = &OtlpMetricExporter.vtable(),
    };
}

test "OtlpMetricExporter basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var exporter = OtlpMetricExporter.init(allocator, .{
        .endpoint = "http://localhost:4318",
    });
    defer exporter.deinit();

    const result = exporter.forceFlush(5000);
    try testing.expectEqual(ExportResult.success, result);

    const shutdown_result = exporter.shutdown(5000);
    try testing.expectEqual(ExportResult.success, shutdown_result);
}

test "OTLP metric format conversion" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use arena allocator like the export function does
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Create test metric data
    const test_resource = try otel_sdk.resource.Resource.init(&[_]otel_api.KeyValue{
        otel_api.KeyValue.init("service.name", .{ .string = "test-service" }),
    }, null);

    const scope = try otel_api.InstrumentationScope.init("test.meter", "1.0.0", null, &.{});

    const data_points = [_]MetricDataPoint{
        .{
            .timestamp_ns = 1234567890,
            .start_timestamp_ns = 1234567000,
            .attributes = &[_]otel_api.KeyValue{
                otel_api.KeyValue.init("method", .{ .string = "GET" }),
            },
            .value = .{ .i64_sum = 42 },
        },
    };

    const metric = MetricData{
        .name = "test.counter",
        .description = "Test counter",
        .unit = "1",
        .type = .sum,
        .data_points = &data_points,
        .scope = scope,
        .resource = &test_resource,
    };

    const json = try convertToOtlpFormat(arena.allocator(), &[_]MetricData{metric});

    // Verify JSON contains expected fields
    try testing.expect(std.mem.indexOf(u8, json, "\"resourceMetrics\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"scopeMetrics\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"test.counter\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"sum\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"asInt\":42") != null);
}
