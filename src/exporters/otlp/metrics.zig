const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const protobuf = @import("protobuf");

const ExportResult = otel_api.common.ExportResult;
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const MetricData = otel_sdk.metrics.MetricData;
const MetricDataPoint = otel_sdk.metrics.MetricDataPoint;
const MetricType = otel_sdk.metrics.MetricType;
const MetricExporter = otel_sdk.metrics.MetricExporter;

// Import error handler for structured error reporting
const error_handler = otel_api.common;

// Import protobuf definitions
const metrics_v1 = @import("proto/opentelemetry/proto/metrics/v1.pb.zig");
const common_v1 = @import("proto/opentelemetry/proto/common/v1.pb.zig");
const resource_v1 = @import("proto/opentelemetry/proto/resource/v1.pb.zig");

pub const OtlpMetricExporter = struct {
    pub const PipelineStep = otel_sdk.common.PipelineStepInstructions(
        Self,
        otel_sdk.logs.LogExporter,
        OtlpExporterConfig,
        metricsExporter,
        _init,
        otel_sdk.common.PipelineDeinitConnection,
    );
    const Self = @This();

    pub fn _init(self: *Self, ctx: OtlpExporterConfig, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, ctx);
    }

    config: OtlpExporterConfig,
    allocator: std.mem.Allocator,
    is_shutdown: bool = false,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, config: OtlpExporterConfig) OtlpMetricExporter {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OtlpMetricExporter) void {
        _ = self;
    }

    pub fn destroy(self: *OtlpMetricExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportMetrics(self: *OtlpMetricExporter, metrics: []const MetricData) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        const metrics_data = convertToOtlpFormat(self.allocator, metrics) catch |err| {
            const first_metric_name = if (metrics.len > 0) metrics[0].name else "(no metrics)";
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_metric_serialization",
                .error_type = .serialization,
                .message = "OTLP metrics conversion failed",
                .context = first_metric_name,
                .source_error = err,
            });
            return .failure;
        };
        defer metrics_data.deinit();

        self.sendRequest(metrics_data) catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_metric_network",
                .error_type = .network,
                .message = "OTLP metrics network request failed",
                .context = self.config.endpoint,
                .source_error = err,
            });
            return .failure;
        };

        return .success;
    }

    pub fn forceFlush(self: *OtlpMetricExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        // For HTTP-based exporters, force flush is typically a no-op
        // since each export call is synchronous
        return .success;
    }

    pub fn shutdown(self: *OtlpMetricExporter, timeout_ms: ?u64) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = timeout_ms;
        self.is_shutdown = true;
        return .success;
    }

    pub fn metricsExporter(self: *OtlpMetricExporter) MetricExporter {
        return .{
            .bridge = otel_sdk.metrics.BridgeMetricExporter.init(self),
        };
    }

    fn sendRequest(self: *OtlpMetricExporter, metrics_data: metrics_v1.MetricsData) !void {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Serialize to binary protobuf
        const protobuf_bytes = try protobuf.pb_encode(metrics_data, self.allocator);
        defer self.allocator.free(protobuf_bytes);

        // Parse endpoint URL with detailed error context
        const base_uri = std.Uri.parse(self.config.endpoint) catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_metric_url_parsing",
                .error_type = .configuration,
                .message = "OTLP metrics URL parsing failed",
                .context = self.config.endpoint,
                .source_error = err,
            });
            return err;
        };

        // Build full URL with metrics path
        const host_str = switch (base_uri.host.?) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        const scheme_str = if (base_uri.scheme.len > 0) base_uri.scheme else "http";
        const full_url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}{s}", .{ scheme_str, host_str, base_uri.port orelse 4318, self.config.protocol_config.metrics_path });
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);

        var server_header_buffer: [16 * 1024]u8 = undefined;
        var req = try client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
            .headers = .{
                .content_type = .{ .override = "application/x-protobuf" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = protobuf_bytes.len };

        try req.send();
        try req.writeAll(protobuf_bytes);
        try req.finish();

        try req.wait();

        if (req.response.status != .ok) {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_metric_response",
                .error_type = .authentication,
                .message = "OTLP metrics export failed with HTTP error",
                .context = self.config.endpoint,
            });
            return error.ExportFailed;
        }
    }
};

/// Create a console metric exporter with custom configuration
pub fn createMetricExporterWithConfig(config: OtlpExporterConfig, allocator: std.mem.Allocator) !otel_sdk.metrics.MetricExporter {
    const exporter = try allocator.create(OtlpMetricExporter);
    errdefer allocator.destroy(exporter);
    exporter.* = OtlpMetricExporter.init(allocator, config);
    return exporter.metricsExporter();
}

fn convertToOtlpFormat(allocator: std.mem.Allocator, metrics: []const MetricData) !metrics_v1.MetricsData {
    var resource_metrics_map = std.StringHashMap(std.ArrayList(MetricData)).init(allocator);
    defer {
        var it = resource_metrics_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        resource_metrics_map.deinit();
    }

    // Group metrics by resource
    for (metrics) |metric| {
        // Group by service name if available, otherwise use empty string
        const resource_key = if (metric.resource.getAttribute("service.name")) |attr|
            attr.string
        else
            "";
        const result = try resource_metrics_map.getOrPut(resource_key);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(MetricData).init(allocator);
        }
        try result.value_ptr.append(metric);
    }

    var metrics_data = metrics_v1.MetricsData.init(allocator);
    metrics_data.resource_metrics = std.ArrayList(metrics_v1.ResourceMetrics).init(allocator);

    var resource_it = resource_metrics_map.iterator();
    while (resource_it.next()) |entry| {
        const resource_metrics = entry.value_ptr.*;
        if (resource_metrics.items.len == 0) continue;

        var rm = metrics_v1.ResourceMetrics.init(allocator);

        // Convert resource
        var resource = resource_v1.Resource.init(allocator);
        resource.attributes = std.ArrayList(common_v1.KeyValue).init(allocator);

        const res = resource_metrics.items[0].resource;
        const attrs = res.attributes;
        for (attrs) |attr| {
            const kv = common_v1.KeyValue{
                .key = protobuf.ManagedString.managed(attr.key),
                .value = try convertAttributeValue(allocator, attr.value),
            };
            try resource.attributes.append(kv);
        }

        rm.resource = resource;

        // Group by instrumentation scope
        var scope_map = std.StringHashMap(std.ArrayList(MetricData)).init(allocator);
        defer {
            var it = scope_map.iterator();
            while (it.next()) |scope_entry| {
                scope_entry.value_ptr.deinit();
            }
            scope_map.deinit();
        }

        for (resource_metrics.items) |metric| {
            const scope_name = metric.scope.name;
            const result = try scope_map.getOrPut(scope_name);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(MetricData).init(allocator);
            }
            try result.value_ptr.append(metric);
        }

        rm.scope_metrics = std.ArrayList(metrics_v1.ScopeMetrics).init(allocator);

        var scope_it = scope_map.iterator();
        while (scope_it.next()) |scope_entry| {
            const scope_metrics = scope_entry.value_ptr.*;
            if (scope_metrics.items.len == 0) continue;

            var sm = metrics_v1.ScopeMetrics.init(allocator);

            // Convert instrumentation scope
            const inst_scope = scope_metrics.items[0].scope;
            var scope = common_v1.InstrumentationScope.init(allocator);
            scope.name = protobuf.ManagedString.managed(inst_scope.name);
            if (inst_scope.version) |version| {
                scope.version = protobuf.ManagedString.managed(version);
            }

            // Convert scope attributes
            scope.attributes = std.ArrayList(common_v1.KeyValue).init(allocator);
            for (inst_scope.attributes) |attr| {
                const kv = common_v1.KeyValue{
                    .key = protobuf.ManagedString.managed(attr.key),
                    .value = try convertAttributeValue(allocator, attr.value),
                };
                try scope.attributes.append(kv);
            }

            sm.scope = scope;
            sm.metrics = std.ArrayList(metrics_v1.Metric).init(allocator);

            // Convert metrics
            for (scope_metrics.items) |metric_data| {
                var metric = metrics_v1.Metric.init(allocator);
                metric.name = protobuf.ManagedString.managed(metric_data.name);
                metric.description = protobuf.ManagedString.managed(metric_data.description orelse "");
                metric.unit = protobuf.ManagedString.managed(metric_data.unit orelse "");
                metric.metadata = std.ArrayList(common_v1.KeyValue).init(allocator);

                // Convert metric data based on type
                switch (metric_data.type) {
                    .sum => {
                        var sum = metrics_v1.Sum.init(allocator);
                        sum.data_points = try convertNumberDataPoints(allocator, metric_data.data_points);
                        sum.aggregation_temporality = .AGGREGATION_TEMPORALITY_CUMULATIVE;
                        sum.is_monotonic = true;
                        metric.data = .{ .sum = sum };
                    },
                    .gauge => {
                        var gauge = metrics_v1.Gauge.init(allocator);
                        gauge.data_points = try convertNumberDataPoints(allocator, metric_data.data_points);
                        metric.data = .{ .gauge = gauge };
                    },
                    .histogram => {
                        var histogram = metrics_v1.Histogram.init(allocator);
                        histogram.data_points = try convertHistogramDataPoints(allocator, metric_data.data_points);
                        histogram.aggregation_temporality = .AGGREGATION_TEMPORALITY_CUMULATIVE;
                        metric.data = .{ .histogram = histogram };
                    },
                }

                try sm.metrics.append(metric);
            }

            try rm.scope_metrics.append(sm);
        }

        try metrics_data.resource_metrics.append(rm);
    }

    return metrics_data;
}

fn convertAttributeValue(allocator: std.mem.Allocator, value: otel_api.AttributeValue) !common_v1.AnyValue {
    var any_value = common_v1.AnyValue.init(allocator);

    switch (value) {
        .string => |s| {
            any_value.value = .{ .string_value = protobuf.ManagedString.managed(s) };
        },
        .bool => |b| {
            any_value.value = .{ .bool_value = b };
        },
        .int => |i| {
            any_value.value = .{ .int_value = i };
        },
        .float => |d| {
            any_value.value = .{ .double_value = d };
        },
        .string_array => |arr| {
            var array_value = common_v1.ArrayValue.init(allocator);
            array_value.values = std.ArrayList(common_v1.AnyValue).init(allocator);
            for (arr) |s| {
                var av = common_v1.AnyValue.init(allocator);
                av.value = .{ .string_value = protobuf.ManagedString.managed(s) };
                try array_value.values.append(av);
            }
            any_value.value = .{ .array_value = array_value };
        },
        .bool_array => |arr| {
            var array_value = common_v1.ArrayValue.init(allocator);
            array_value.values = std.ArrayList(common_v1.AnyValue).init(allocator);
            for (arr) |b| {
                var av = common_v1.AnyValue.init(allocator);
                av.value = .{ .bool_value = b };
                try array_value.values.append(av);
            }
            any_value.value = .{ .array_value = array_value };
        },
        .int_array => |arr| {
            var array_value = common_v1.ArrayValue.init(allocator);
            array_value.values = std.ArrayList(common_v1.AnyValue).init(allocator);
            for (arr) |i| {
                var av = common_v1.AnyValue.init(allocator);
                av.value = .{ .int_value = i };
                try array_value.values.append(av);
            }
            any_value.value = .{ .array_value = array_value };
        },
        .float_array => |arr| {
            var array_value = common_v1.ArrayValue.init(allocator);
            array_value.values = std.ArrayList(common_v1.AnyValue).init(allocator);
            for (arr) |d| {
                var av = common_v1.AnyValue.init(allocator);
                av.value = .{ .double_value = d };
                try array_value.values.append(av);
            }
            any_value.value = .{ .array_value = array_value };
        },
    }

    return any_value;
}

fn convertNumberDataPoints(allocator: std.mem.Allocator, data_points: []const MetricDataPoint) !std.ArrayList(metrics_v1.NumberDataPoint) {
    var result = std.ArrayList(metrics_v1.NumberDataPoint).init(allocator);

    for (data_points) |dp| {
        var ndp = metrics_v1.NumberDataPoint.init(allocator);
        ndp.attributes = std.ArrayList(common_v1.KeyValue).init(allocator);

        // Convert attributes
        for (dp.attributes) |attr| {
            const kv = common_v1.KeyValue{
                .key = protobuf.ManagedString.managed(attr.key),
                .value = try convertAttributeValue(allocator, attr.value),
            };
            try ndp.attributes.append(kv);
        }

        ndp.time_unix_nano = dp.timestamp_ns;
        ndp.start_time_unix_nano = dp.start_timestamp_ns orelse 0;

        // Set value based on type
        switch (dp.value) {
            .i64_gauge => |i| ndp.value = .{ .as_int = i },
            .f64_gauge => |d| ndp.value = .{ .as_double = d },
            .i64_sum => |i| ndp.value = .{ .as_int = i },
            .f64_sum => |d| ndp.value = .{ .as_double = d },
            .i64_histogram, .f64_histogram => unreachable, // Histogram data points are handled separately
        }

        ndp.exemplars = std.ArrayList(metrics_v1.Exemplar).init(allocator);
        ndp.flags = 0;

        try result.append(ndp);
    }

    return result;
}

fn convertHistogramDataPoints(allocator: std.mem.Allocator, data_points: []const MetricDataPoint) !std.ArrayList(metrics_v1.HistogramDataPoint) {
    var result = std.ArrayList(metrics_v1.HistogramDataPoint).init(allocator);

    for (data_points) |dp| {
        var hdp = metrics_v1.HistogramDataPoint.init(allocator);
        hdp.attributes = std.ArrayList(common_v1.KeyValue).init(allocator);

        // Convert attributes
        for (dp.attributes) |attr| {
            const kv = common_v1.KeyValue{
                .key = protobuf.ManagedString.managed(attr.key),
                .value = try convertAttributeValue(allocator, attr.value),
            };
            try hdp.attributes.append(kv);
        }

        hdp.time_unix_nano = dp.timestamp_ns;
        hdp.start_time_unix_nano = dp.start_timestamp_ns orelse 0;

        switch (dp.value) {
            .i64_histogram => |h| {
                hdp.count = h.count;
                hdp.sum = @floatFromInt(h.sum);

                hdp.bucket_counts = std.ArrayList(u64).init(allocator);
                for (h.bucket_counts) |count| {
                    try hdp.bucket_counts.append(count);
                }

                hdp.explicit_bounds = std.ArrayList(f64).init(allocator);
                for (h.boundaries) |bound| {
                    try hdp.explicit_bounds.append(bound);
                }

                hdp.min = if (h.min) |min| @floatFromInt(min) else null;
                hdp.max = if (h.max) |max| @floatFromInt(max) else null;
            },
            .f64_histogram => |h| {
                hdp.count = h.count;
                hdp.sum = h.sum;

                hdp.bucket_counts = std.ArrayList(u64).init(allocator);
                for (h.bucket_counts) |count| {
                    try hdp.bucket_counts.append(count);
                }

                hdp.explicit_bounds = std.ArrayList(f64).init(allocator);
                for (h.boundaries) |bound| {
                    try hdp.explicit_bounds.append(bound);
                }

                hdp.min = h.min;
                hdp.max = h.max;
            },
            else => unreachable, // Only histogram data points should be passed here
        }

        hdp.exemplars = std.ArrayList(metrics_v1.Exemplar).init(allocator);
        hdp.flags = 0;

        try result.append(hdp);
    }

    return result;
}

test "convertToOtlpFormat with histogram" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create test resource
    const resource_attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "test-service" } },
    };
    const resource = otel_sdk.resource.Resource.init(&resource_attrs, null) catch unreachable;

    // Create test instrumentation scope
    const scope = otel_api.InstrumentationScope{
        .name = "test-scope",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &[_]otel_api.common.AttributeKeyValue{},
    };

    // Create test histogram data
    const boundaries = [_]f64{ 1.0, 5.0, 10.0 };
    const bucket_counts = [_]u64{ 2, 3, 1, 0 };
    const histogram = otel_sdk.metrics.F64HistogramData{
        .count = 6,
        .sum = 25.5,
        .min = 0.5,
        .max = 9.2,
        .boundaries = &boundaries,
        .bucket_counts = &bucket_counts,
    };

    const data_point = otel_sdk.metrics.MetricDataPoint{
        .attributes = &[_]otel_api.common.AttributeKeyValue{},
        .timestamp_ns = 1234567890,
        .start_timestamp_ns = 1234567000,
        .value = .{ .f64_histogram = histogram },
    };

    const metric_data = otel_sdk.metrics.MetricData{
        .resource = resource,
        .scope = scope,
        .name = "test_histogram",
        .description = "A test histogram",
        .unit = "ms",
        .type = .histogram,
        .data_points = &[_]otel_sdk.metrics.MetricDataPoint{data_point},
    };

    const metrics = [_]otel_sdk.metrics.MetricData{metric_data};
    var result = try convertToOtlpFormat(allocator, &metrics);
    defer result.deinit();

    try testing.expect(result.resource_metrics.items.len == 1);
    const rm = result.resource_metrics.items[0];
    try testing.expect(rm.scope_metrics.items.len == 1);

    const sm = rm.scope_metrics.items[0];
    try testing.expect(sm.metrics.items.len == 1);

    const metric = sm.metrics.items[0];
    try testing.expect(std.mem.eql(u8, metric.name.getSlice(), "test_histogram"));

    if (metric.data) |data| {
        switch (data) {
            .histogram => |hist| {
                try testing.expect(hist.data_points.items.len == 1);
                const hdp = hist.data_points.items[0];
                try testing.expectEqual(@as(u64, 6), hdp.count);
                if (hdp.sum) |sum| {
                    try testing.expectApproxEqAbs(@as(f64, 25.5), sum, 0.001);
                } else {
                    try testing.expect(false); // sum should be present
                }
            },
            else => try testing.expect(false),
        }
    } else {
        try testing.expect(false);
    }
}
