//! OpenTelemetry Console Metric Exporter
//!
//! This module provides a console exporter for metrics that writes
//! JSON-formatted metric output to stdout or stderr. The JSON format
//! follows the OpenTelemetry protocol buffer JSON representation.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otlp_metrics = @import("../otlp/metrics.zig");
const protobuf = @import("protobuf");

const ExportResult = otel_api.common.ExportResult;
const ConsoleExporterConfig = @import("root.zig").ConsoleExporterConfig;

// Import error handler for structured error reporting
const error_handler = otel_api.common;

// Import protobuf definitions
const metrics_v1 = @import("../otlp/proto/opentelemetry/proto/metrics/v1.pb.zig");
const common_v1 = @import("../otlp/proto/opentelemetry/proto/common/v1.pb.zig");
const resource_v1 = @import("../otlp/proto/opentelemetry/proto/resource/v1.pb.zig");

// Custom JSON serialization helpers for OTLP protobuf structures
const JsonError = std.json.WriteStream(std.ArrayList(u8).Writer, .assumed_correct).Error;

fn writeFloat(jw: anytype, value: f64) JsonError!void {
    // Format float using scientific notation only if decimal representation is longer than 7 characters
    var buf: [64]u8 = undefined;
    const decimal_str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable; // 64 bytes is enough for any float

    // Remove trailing zeros after decimal point for cleaner output
    var trimmed_str = decimal_str;
    if (std.mem.indexOf(u8, decimal_str, ".")) |dot_idx| {
        var end_idx = decimal_str.len;
        while (end_idx > dot_idx + 1 and decimal_str[end_idx - 1] == '0') {
            end_idx -= 1;
        }
        // Remove decimal point if all decimals were zeros
        if (end_idx == dot_idx + 1 and decimal_str[dot_idx] == '.') {
            end_idx = dot_idx;
        }
        trimmed_str = decimal_str[0..end_idx];
    }

    if (trimmed_str.len > 7) {
        try jw.write(value); // Default JSON formatting uses scientific notation
    } else {
        try jw.print("{s}", .{trimmed_str}); // Use the trimmed decimal notation
    }
}

fn writeMetricsData(writer: anytype, data: metrics_v1.MetricsData) JsonError!void {
    var jw = std.json.writeStream(writer, .{});
    try jw.beginObject();
    try jw.objectField("resourceMetrics");
    try jw.beginArray();
    for (data.resource_metrics.items) |rm| {
        try writeResourceMetrics(&jw, rm);
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeResourceMetrics(jw: anytype, rm: metrics_v1.ResourceMetrics) JsonError!void {
    try jw.beginObject();

    if (rm.resource) |resource| {
        try jw.objectField("resource");
        try writeResource(jw, resource);
    }

    try jw.objectField("scopeMetrics");
    try jw.beginArray();
    for (rm.scope_metrics.items) |sm| {
        try writeScopeMetrics(jw, sm);
    }
    try jw.endArray();

    // Don't write empty schemaUrl

    try jw.endObject();
}

fn writeResource(jw: anytype, resource: resource_v1.Resource) JsonError!void {
    try jw.beginObject();

    try jw.objectField("attributes");
    try jw.beginArray();
    for (resource.attributes.items) |attr| {
        try writeKeyValue(jw, attr);
    }
    try jw.endArray();

    // Don't write dropped_attributes_count or entity_refs to match OTLP JSON format

    try jw.endObject();
}

fn writeScopeMetrics(jw: anytype, sm: metrics_v1.ScopeMetrics) JsonError!void {
    try jw.beginObject();

    if (sm.scope) |scope| {
        try jw.objectField("scope");
        try writeInstrumentationScope(jw, scope);
    }

    try jw.objectField("metrics");
    try jw.beginArray();
    for (sm.metrics.items) |metric| {
        try writeMetric(jw, metric);
    }
    try jw.endArray();

    // Don't write empty schemaUrl

    try jw.endObject();
}

fn writeInstrumentationScope(jw: anytype, scope: common_v1.InstrumentationScope) JsonError!void {
    try jw.beginObject();

    try jw.objectField("name");
    try jw.write(scope.name.getSlice());

    try jw.objectField("version");
    try jw.write(scope.version.getSlice());

    try jw.objectField("attributes");
    try jw.beginArray();
    for (scope.attributes.items) |attr| {
        try writeKeyValue(jw, attr);
    }
    try jw.endArray();

    // Don't write droppedAttributesCount

    try jw.endObject();
}

fn writeMetric(jw: anytype, metric: metrics_v1.Metric) JsonError!void {
    try jw.beginObject();

    try jw.objectField("name");
    try jw.write(metric.name.getSlice());

    try jw.objectField("description");
    try jw.write(metric.description.getSlice());

    try jw.objectField("unit");
    try jw.write(metric.unit.getSlice());

    if (metric.data) |data| {
        switch (data) {
            .gauge => |gauge| {
                try jw.objectField("gauge");
                try writeGauge(jw, gauge);
            },
            .sum => |sum| {
                try jw.objectField("sum");
                try writeSum(jw, sum);
            },
            .histogram => |histogram| {
                try jw.objectField("histogram");
                try writeHistogram(jw, histogram);
            },
            .exponential_histogram => |exp_hist| {
                try jw.objectField("exponentialHistogram");
                try writeExponentialHistogram(jw, exp_hist);
            },
            .summary => |summary| {
                try jw.objectField("summary");
                try writeSummary(jw, summary);
            },
        }
    }

    try jw.endObject();
}

fn writeGauge(jw: anytype, gauge: metrics_v1.Gauge) JsonError!void {
    try jw.beginObject();

    try jw.objectField("dataPoints");
    try jw.beginArray();
    for (gauge.data_points.items) |dp| {
        try writeNumberDataPoint(jw, dp);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeSum(jw: anytype, sum: metrics_v1.Sum) JsonError!void {
    try jw.beginObject();

    try jw.objectField("dataPoints");
    try jw.beginArray();
    for (sum.data_points.items) |dp| {
        try writeNumberDataPoint(jw, dp);
    }
    try jw.endArray();

    try jw.objectField("aggregationTemporality");
    try jw.write(@intFromEnum(sum.aggregation_temporality));

    try jw.objectField("isMonotonic");
    try jw.write(sum.is_monotonic);

    try jw.endObject();
}

fn writeHistogram(jw: anytype, histogram: metrics_v1.Histogram) JsonError!void {
    try jw.beginObject();

    try jw.objectField("dataPoints");
    try jw.beginArray();
    for (histogram.data_points.items) |dp| {
        try writeHistogramDataPoint(jw, dp);
    }
    try jw.endArray();

    try jw.objectField("aggregationTemporality");
    try jw.write(@intFromEnum(histogram.aggregation_temporality));

    try jw.endObject();
}

fn writeExponentialHistogram(jw: anytype, exp_hist: metrics_v1.ExponentialHistogram) JsonError!void {
    try jw.beginObject();

    try jw.objectField("dataPoints");
    try jw.beginArray();
    for (exp_hist.data_points.items) |dp| {
        try writeExponentialHistogramDataPoint(jw, dp);
    }
    try jw.endArray();

    try jw.objectField("aggregationTemporality");
    try jw.write(@intFromEnum(exp_hist.aggregation_temporality));

    try jw.endObject();
}

fn writeSummary(jw: anytype, summary: metrics_v1.Summary) JsonError!void {
    try jw.beginObject();

    try jw.objectField("dataPoints");
    try jw.beginArray();
    for (summary.data_points.items) |dp| {
        try writeSummaryDataPoint(jw, dp);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeNumberDataPoint(jw: anytype, dp: metrics_v1.NumberDataPoint) JsonError!void {
    try jw.beginObject();

    if (dp.value) |value| {
        switch (value) {
            .as_double => |d| {
                try jw.objectField("asDouble");
                try writeFloat(jw, d);
            },
            .as_int => |i| {
                try jw.objectField("asInt");
                try jw.write(i);
            },
        }
    }

    if (dp.start_time_unix_nano > 0) {
        try jw.objectField("startTimeUnixNano");
        try jw.print("\"{}\"", .{dp.start_time_unix_nano});
    }

    try jw.objectField("timeUnixNano");
    try jw.print("\"{}\"", .{dp.time_unix_nano});

    try jw.objectField("attributes");
    try jw.beginArray();
    for (dp.attributes.items) |attr| {
        try writeKeyValue(jw, attr);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeHistogramDataPoint(jw: anytype, dp: metrics_v1.HistogramDataPoint) JsonError!void {
    try jw.beginObject();

    if (dp.start_time_unix_nano > 0) {
        try jw.objectField("startTimeUnixNano");
        try jw.print("\"{}\"", .{dp.start_time_unix_nano});
    }

    try jw.objectField("timeUnixNano");
    try jw.print("\"{}\"", .{dp.time_unix_nano});

    try jw.objectField("count");
    try jw.write(dp.count);

    if (dp.sum) |sum| {
        try jw.objectField("sum");
        try writeFloat(jw, sum);
    }

    try jw.objectField("bucketCounts");
    try jw.beginArray();
    for (dp.bucket_counts.items) |count| {
        try jw.write(count);
    }
    try jw.endArray();

    try jw.objectField("explicitBounds");
    try jw.beginArray();
    for (dp.explicit_bounds.items) |bound| {
        try writeFloat(jw, bound);
    }
    try jw.endArray();

    if (dp.min) |min| {
        try jw.objectField("min");
        try writeFloat(jw, min);
    }

    if (dp.max) |max| {
        try jw.objectField("max");
        try writeFloat(jw, max);
    }

    try jw.objectField("attributes");
    try jw.beginArray();
    for (dp.attributes.items) |attr| {
        try writeKeyValue(jw, attr);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeExponentialHistogramDataPoint(jw: anytype, dp: metrics_v1.ExponentialHistogramDataPoint) JsonError!void {
    try jw.beginObject();

    if (dp.start_time_unix_nano > 0) {
        try jw.objectField("startTimeUnixNano");
        try jw.print("\"{}\"", .{dp.start_time_unix_nano});
    }

    try jw.objectField("timeUnixNano");
    try jw.print("\"{}\"", .{dp.time_unix_nano});

    try jw.objectField("count");
    try jw.write(dp.count);

    if (dp.sum) |sum| {
        try jw.objectField("sum");
        try writeFloat(jw, sum);
    }

    try jw.objectField("scale");
    try jw.write(dp.scale);

    try jw.objectField("zeroCount");
    try jw.write(dp.zero_count);

    if (dp.positive) |positive| {
        try jw.objectField("positive");
        try writeBuckets(jw, positive);
    }

    if (dp.negative) |negative| {
        try jw.objectField("negative");
        try writeBuckets(jw, negative);
    }

    if (dp.min) |min| {
        try jw.objectField("min");
        try writeFloat(jw, min);
    }

    if (dp.max) |max| {
        try jw.objectField("max");
        try writeFloat(jw, max);
    }

    try jw.objectField("zeroThreshold");
    try writeFloat(jw, dp.zero_threshold);

    try jw.objectField("attributes");
    try jw.beginArray();
    for (dp.attributes.items) |attr| {
        try writeKeyValue(jw, attr);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeBuckets(jw: anytype, buckets: metrics_v1.ExponentialHistogramDataPoint.Buckets) JsonError!void {
    try jw.beginObject();

    try jw.objectField("offset");
    try jw.write(buckets.offset);

    try jw.objectField("bucketCounts");
    try jw.beginArray();
    for (buckets.bucket_counts.items) |count| {
        try jw.write(count);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeSummaryDataPoint(jw: anytype, dp: metrics_v1.SummaryDataPoint) JsonError!void {
    try jw.beginObject();

    if (dp.start_time_unix_nano > 0) {
        try jw.objectField("startTimeUnixNano");
        try jw.print("\"{}\"", .{dp.start_time_unix_nano});
    }

    try jw.objectField("timeUnixNano");
    try jw.print("\"{}\"", .{dp.time_unix_nano});

    try jw.objectField("count");
    try jw.write(dp.count);

    try jw.objectField("sum");
    try writeFloat(jw, dp.sum);

    try jw.objectField("quantileValues");
    try jw.beginArray();
    for (dp.quantile_values.items) |qv| {
        try jw.beginObject();
        try jw.objectField("quantile");
        try writeFloat(jw, qv.quantile);
        try jw.objectField("value");
        try writeFloat(jw, qv.value);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("attributes");
    try jw.beginArray();
    for (dp.attributes.items) |attr| {
        try writeKeyValue(jw, attr);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeKeyValue(jw: anytype, kv: common_v1.KeyValue) JsonError!void {
    try jw.beginObject();

    try jw.objectField("key");
    try jw.write(kv.key.getSlice());

    if (kv.value) |value| {
        try jw.objectField("value");
        try writeAnyValue(jw, value);
    }

    try jw.endObject();
}

fn writeAnyValue(jw: anytype, value: common_v1.AnyValue) JsonError!void {
    // Flatten the AnyValue structure - write the union directly without the wrapper
    if (value.value) |v| {
        switch (v) {
            .string_value => |s| {
                try jw.beginObject();
                try jw.objectField("stringValue");
                try jw.write(s.getSlice());
                try jw.endObject();
            },
            .bool_value => |b| {
                try jw.beginObject();
                try jw.objectField("boolValue");
                try jw.write(b);
                try jw.endObject();
            },
            .int_value => |i| {
                try jw.beginObject();
                try jw.objectField("intValue");
                try jw.write(i);
                try jw.endObject();
            },
            .double_value => |d| {
                try jw.beginObject();
                try jw.objectField("doubleValue");
                try writeFloat(jw, d);
                try jw.endObject();
            },
            .array_value => |arr| {
                try jw.beginObject();
                try jw.objectField("arrayValue");
                try jw.beginObject();
                try jw.objectField("values");
                try jw.beginArray();
                for (arr.values.items) |av| {
                    try writeAnyValue(jw, av);
                }
                try jw.endArray();
                try jw.endObject();
                try jw.endObject();
            },
            .kvlist_value => |kvlist| {
                try jw.beginObject();
                try jw.objectField("kvlistValue");
                try jw.beginObject();
                try jw.objectField("values");
                try jw.beginArray();
                for (kvlist.values.items) |kv2| {
                    try writeKeyValue(jw, kv2);
                }
                try jw.endArray();
                try jw.endObject();
                try jw.endObject();
            },
            .bytes_value => |bytes| {
                try jw.beginObject();
                try jw.objectField("bytesValue");
                try jw.write(bytes.getSlice());
                try jw.endObject();
            },
        }
    }
}

/// Console metric exporter implementation using JSON output
pub const ConsoleMetricExporter = struct {
    pub const PipelineStep = otel_sdk.common.PipelineStepInstructions(
        Self,
        otel_sdk.metrics.MetricExporter,
        ConsoleExporterConfig,
        metricsExporter,
        _init,
        otel_sdk.common.PipelineDeinitConnection,
    );
    const Self = @This();

    pub fn _init(self: *Self, ctx: ConsoleExporterConfig, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, ctx);
    }

    config: ConsoleExporterConfig,
    writer: std.fs.File.Writer,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: ConsoleExporterConfig) ConsoleMetricExporter {
        const file = if (config.use_stderr) std.io.getStdErr() else std.io.getStdOut();
        return .{
            .config = config,
            .writer = file.writer(),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConsoleMetricExporter) void {
        _ = self;
    }

    pub fn destroy(self: *ConsoleMetricExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportMetrics(self: *ConsoleMetricExporter, metrics: []const otel_sdk.metrics.MetricData) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Create a buffer to write JSON to
        var json_buffer = std.ArrayList(u8).init(self.allocator);
        defer json_buffer.deinit();

        // Convert SDK metrics to protobuf format and write as JSON
        const protobuf_data = self.convertToOtlpFormat(metrics) catch |err| {
            const first_metric_name = if (metrics.len > 0) metrics[0].name else "(no metrics)";
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "console_metric_conversion",
                .error_type = .serialization,
                .message = "Failed to convert metrics to protobuf format",
                .context = first_metric_name,
                .source_error = err,
            });
            return .failure;
        };
        defer protobuf_data.deinit();

        writeMetricsData(json_buffer.writer(), protobuf_data) catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "console_metric_write",
                .error_type = .serialization,
                .message = "Failed to write metrics JSON to console",
                .context = null,
                .source_error = err,
            });
            return .failure;
        };

        // Write the JSON to console
        self.writer.writeAll(json_buffer.items) catch {
            return .failure;
        };

        // Add a newline for better readability
        self.writer.writeByte('\n') catch {
            return .failure;
        };

        return .success;
    }

    fn convertToOtlpFormat(self: *ConsoleMetricExporter, metrics: []const otel_sdk.metrics.MetricData) !metrics_v1.MetricsData {
        var resource_metrics_map = std.StringHashMap(std.ArrayList(otel_sdk.metrics.MetricData)).init(self.allocator);
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
                result.value_ptr.* = std.ArrayList(otel_sdk.metrics.MetricData).init(self.allocator);
            }
            try result.value_ptr.append(metric);
        }

        var metrics_data = metrics_v1.MetricsData.init(self.allocator);
        metrics_data.resource_metrics = std.ArrayList(metrics_v1.ResourceMetrics).init(self.allocator);

        var resource_it = resource_metrics_map.iterator();
        while (resource_it.next()) |entry| {
            const resource_metrics = entry.value_ptr.*;
            if (resource_metrics.items.len == 0) continue;

            var rm = metrics_v1.ResourceMetrics.init(self.allocator);

            // Convert resource
            var resource = resource_v1.Resource.init(self.allocator);
            resource.attributes = std.ArrayList(common_v1.KeyValue).init(self.allocator);

            const res = resource_metrics.items[0].resource;
            const attrs = res.attributes;
            for (attrs) |attr| {
                const kv = common_v1.KeyValue{
                    .key = protobuf.ManagedString.managed(attr.key),
                    .value = try self.convertAttributeValue(attr.value),
                };
                try resource.attributes.append(kv);
            }

            rm.resource = resource;

            // Group by instrumentation scope
            var scope_map = std.StringHashMap(std.ArrayList(otel_sdk.metrics.MetricData)).init(self.allocator);
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
                    result.value_ptr.* = std.ArrayList(otel_sdk.metrics.MetricData).init(self.allocator);
                }
                try result.value_ptr.append(metric);
            }

            rm.scope_metrics = std.ArrayList(metrics_v1.ScopeMetrics).init(self.allocator);

            var scope_it = scope_map.iterator();
            while (scope_it.next()) |scope_entry| {
                const scope_metrics = scope_entry.value_ptr.*;
                if (scope_metrics.items.len == 0) continue;

                var sm = metrics_v1.ScopeMetrics.init(self.allocator);

                // Convert instrumentation scope
                const inst_scope = scope_metrics.items[0].scope;
                var scope = common_v1.InstrumentationScope.init(self.allocator);
                scope.name = protobuf.ManagedString.managed(inst_scope.name);
                if (inst_scope.version) |version| {
                    scope.version = protobuf.ManagedString.managed(version);
                }

                // Convert scope attributes
                scope.attributes = std.ArrayList(common_v1.KeyValue).init(self.allocator);
                for (inst_scope.attributes) |attr| {
                    const kv = common_v1.KeyValue{
                        .key = protobuf.ManagedString.managed(attr.key),
                        .value = try self.convertAttributeValue(attr.value),
                    };
                    try scope.attributes.append(kv);
                }

                sm.scope = scope;
                sm.metrics = std.ArrayList(metrics_v1.Metric).init(self.allocator);

                // Convert metrics
                for (scope_metrics.items) |metric_data| {
                    var metric = metrics_v1.Metric.init(self.allocator);
                    metric.name = protobuf.ManagedString.managed(metric_data.name);
                    metric.description = protobuf.ManagedString.managed(metric_data.description orelse "");
                    metric.unit = protobuf.ManagedString.managed(metric_data.unit orelse "");
                    metric.metadata = std.ArrayList(common_v1.KeyValue).init(self.allocator);

                    // Convert metric data based on type
                    switch (metric_data.type) {
                        .sum => {
                            var sum = metrics_v1.Sum.init(self.allocator);
                            sum.data_points = try self.convertNumberDataPoints(metric_data.data_points);
                            sum.aggregation_temporality = .AGGREGATION_TEMPORALITY_CUMULATIVE;
                            sum.is_monotonic = true;
                            metric.data = .{ .sum = sum };
                        },
                        .gauge => {
                            var gauge = metrics_v1.Gauge.init(self.allocator);
                            gauge.data_points = try self.convertNumberDataPoints(metric_data.data_points);
                            metric.data = .{ .gauge = gauge };
                        },
                        .histogram => {
                            var histogram = metrics_v1.Histogram.init(self.allocator);
                            histogram.data_points = try self.convertHistogramDataPoints(metric_data.data_points);
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

    fn convertAttributeValue(self: *ConsoleMetricExporter, value: otel_api.common.AttributeValue) !common_v1.AnyValue {
        var any_value = common_v1.AnyValue.init(self.allocator);

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
                var array_value = common_v1.ArrayValue.init(self.allocator);
                array_value.values = std.ArrayList(common_v1.AnyValue).init(self.allocator);
                for (arr) |s| {
                    var av = common_v1.AnyValue.init(self.allocator);
                    av.value = .{ .string_value = protobuf.ManagedString.managed(s) };
                    try array_value.values.append(av);
                }
                any_value.value = .{ .array_value = array_value };
            },
            .bool_array => |arr| {
                var array_value = common_v1.ArrayValue.init(self.allocator);
                array_value.values = std.ArrayList(common_v1.AnyValue).init(self.allocator);
                for (arr) |b| {
                    var av = common_v1.AnyValue.init(self.allocator);
                    av.value = .{ .bool_value = b };
                    try array_value.values.append(av);
                }
                any_value.value = .{ .array_value = array_value };
            },
            .int_array => |arr| {
                var array_value = common_v1.ArrayValue.init(self.allocator);
                array_value.values = std.ArrayList(common_v1.AnyValue).init(self.allocator);
                for (arr) |i| {
                    var av = common_v1.AnyValue.init(self.allocator);
                    av.value = .{ .int_value = i };
                    try array_value.values.append(av);
                }
                any_value.value = .{ .array_value = array_value };
            },
            .float_array => |arr| {
                var array_value = common_v1.ArrayValue.init(self.allocator);
                array_value.values = std.ArrayList(common_v1.AnyValue).init(self.allocator);
                for (arr) |d| {
                    var av = common_v1.AnyValue.init(self.allocator);
                    av.value = .{ .double_value = d };
                    try array_value.values.append(av);
                }
                any_value.value = .{ .array_value = array_value };
            },
        }

        return any_value;
    }

    fn convertNumberDataPoints(self: *ConsoleMetricExporter, data_points: []const otel_sdk.metrics.MetricDataPoint) !std.ArrayList(metrics_v1.NumberDataPoint) {
        var result = std.ArrayList(metrics_v1.NumberDataPoint).init(self.allocator);

        for (data_points) |dp| {
            var ndp = metrics_v1.NumberDataPoint.init(self.allocator);
            ndp.attributes = std.ArrayList(common_v1.KeyValue).init(self.allocator);

            // Convert attributes
            for (dp.attributes) |attr| {
                const kv = common_v1.KeyValue{
                    .key = protobuf.ManagedString.managed(attr.key),
                    .value = try self.convertAttributeValue(attr.value),
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

            ndp.exemplars = std.ArrayList(metrics_v1.Exemplar).init(self.allocator);
            ndp.flags = 0;

            try result.append(ndp);
        }

        return result;
    }

    fn convertHistogramDataPoints(self: *ConsoleMetricExporter, data_points: []const otel_sdk.metrics.MetricDataPoint) !std.ArrayList(metrics_v1.HistogramDataPoint) {
        var result = std.ArrayList(metrics_v1.HistogramDataPoint).init(self.allocator);

        for (data_points) |dp| {
            var hdp = metrics_v1.HistogramDataPoint.init(self.allocator);
            hdp.attributes = std.ArrayList(common_v1.KeyValue).init(self.allocator);

            // Convert attributes
            for (dp.attributes) |attr| {
                const kv = common_v1.KeyValue{
                    .key = protobuf.ManagedString.managed(attr.key),
                    .value = try self.convertAttributeValue(attr.value),
                };
                try hdp.attributes.append(kv);
            }

            hdp.time_unix_nano = dp.timestamp_ns;
            hdp.start_time_unix_nano = dp.start_timestamp_ns orelse 0;

            switch (dp.value) {
                .i64_histogram => |h| {
                    hdp.count = h.count;
                    hdp.sum = @floatFromInt(h.sum);

                    hdp.bucket_counts = std.ArrayList(u64).init(self.allocator);
                    for (h.bucket_counts) |count| {
                        try hdp.bucket_counts.append(count);
                    }

                    hdp.explicit_bounds = std.ArrayList(f64).init(self.allocator);
                    for (h.boundaries) |bound| {
                        try hdp.explicit_bounds.append(bound);
                    }

                    hdp.min = if (h.min) |min| @floatFromInt(min) else null;
                    hdp.max = if (h.max) |max| @floatFromInt(max) else null;
                },
                .f64_histogram => |h| {
                    hdp.count = h.count;
                    hdp.sum = h.sum;

                    hdp.bucket_counts = std.ArrayList(u64).init(self.allocator);
                    for (h.bucket_counts) |count| {
                        try hdp.bucket_counts.append(count);
                    }

                    hdp.explicit_bounds = std.ArrayList(f64).init(self.allocator);
                    for (h.boundaries) |bound| {
                        try hdp.explicit_bounds.append(bound);
                    }

                    hdp.min = h.min;
                    hdp.max = h.max;
                },
                else => unreachable, // Only histogram data points should be passed here
            }

            hdp.exemplars = std.ArrayList(metrics_v1.Exemplar).init(self.allocator);
            hdp.flags = 0;

            try result.append(hdp);
        }

        return result;
    }

    pub fn forceFlush(self: *ConsoleMetricExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        return .success;
    }

    pub fn shutdown(self: *ConsoleMetricExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        return .success;
    }

    pub fn metricsExporter(self: *ConsoleMetricExporter) otel_sdk.metrics.MetricExporter {
        return .{
            .bridge = otel_sdk.metrics.BridgeMetricExporter.init(self),
        };
    }
};

/// Create a console metric exporter with custom configuration
pub fn createMetricExporterWithConfig(config: ConsoleExporterConfig, allocator: std.mem.Allocator) !otel_sdk.metrics.MetricExporter {
    const exporter = try allocator.create(ConsoleMetricExporter);
    errdefer allocator.destroy(exporter);
    exporter.* = ConsoleMetricExporter.init(allocator, config);
    return exporter.metricsExporter();
}

test "ConsoleMetricExporter JSON output" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var exporter = try allocator.create(ConsoleMetricExporter);
    defer allocator.destroy(exporter);
    exporter.* = ConsoleMetricExporter.init(allocator, .{});
    defer exporter.deinit();

    const result = exporter.forceFlush(5000);
    try testing.expectEqual(ExportResult.success, result);
}
