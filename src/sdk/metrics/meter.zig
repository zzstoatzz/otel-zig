//! OpenTelemetry Meter SDK Implementation
//!
//! This module provides the concrete implementation of Meter for the SDK.
//! It manages instrument lifecycle and provides the actual measurement recording.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md

const std = @import("std");
const otel_api = @import("otel-api");

const InstrumentationScope = otel_api.common.InstrumentationScope;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const Context = otel_api.Context;
const Resource = @import("../resource/resource.zig").Resource;

// Import instrument implementations
const StandardCounter = @import("instruments.zig").StandardCounter;
const StandardUpDownCounter = @import("instruments.zig").StandardUpDownCounter;
const StandardGauge = @import("instruments.zig").StandardGauge;
const StandardHistogram = @import("instruments.zig").StandardHistogram;
const HistogramAggregationConfig = @import("instruments.zig").HistogramAggregationConfig;

// Import SDK data types.
const MetricData = @import("data.zig").MetricData;
const MetricDataPoint = @import("data.zig").MetricDataPoint;
const MetricType = @import("data.zig").MetricType;
const MetricValue = @import("data.zig").MetricValue;
const MetricProcessor = @import("processor.zig").MetricProcessor;

/// Standard meter implementation
pub const StandardMeter = struct {
    allocator: std.mem.Allocator,
    scope: InstrumentationScope,
    resource: Resource,
    handler: MetricProcessor,

    // Track created instruments for cleanup
    counters_i64: std.ArrayListUnmanaged(*StandardCounter(i64)),
    counters_f64: std.ArrayListUnmanaged(*StandardCounter(f64)),
    up_down_counters_i64: std.ArrayListUnmanaged(*StandardUpDownCounter(i64)),
    up_down_counters_f64: std.ArrayListUnmanaged(*StandardUpDownCounter(f64)),
    gauges_i64: std.ArrayListUnmanaged(*StandardGauge(i64)),
    gauges_f64: std.ArrayListUnmanaged(*StandardGauge(f64)),
    histograms_i64: std.ArrayListUnmanaged(*StandardHistogram(i64)),
    histograms_f64: std.ArrayListUnmanaged(*StandardHistogram(f64)),

    pub fn init(
        allocator: std.mem.Allocator,
        scope: InstrumentationScope,
        resource: Resource,
        default_processor: MetricProcessor,
    ) !StandardMeter {
        return .{
            .allocator = allocator,
            .scope = scope,
            .resource = resource,
            .handler = default_processor,
            .counters_i64 = .empty,
            .counters_f64 = .empty,
            .up_down_counters_i64 = .empty,
            .up_down_counters_f64 = .empty,
            .gauges_i64 = .empty,
            .gauges_f64 = .empty,
            .histograms_i64 = .empty,
            .histograms_f64 = .empty,
        };
    }

    pub fn meter(self: *StandardMeter) otel_api.metrics.Meter {
        return otel_api.metrics.Meter{
            .bridge = otel_api.metrics.MeterBridge.init(self),
        };
    }

    pub fn deinit(self: *StandardMeter) void {
        const instruments = .{
            self.counters_i64,
            self.counters_f64,
            self.up_down_counters_i64,
            self.up_down_counters_f64,
            self.gauges_i64,
            self.gauges_f64,
            self.histograms_i64,
            self.histograms_f64,
        };
        inline for (instruments) |list| {
            for (list.items) |instrument| {
                instrument.deinit();
                self.allocator.destroy(instrument);
            }
            // The captured var is const, which blocks calling
            // deinit. But ArrayLists are just pointers to memory
            // so I can get away with calling deinit on a mutable
            // copy.
            var mutable_list = list;
            mutable_list.deinit(self.allocator);
        }
    }

    pub fn createCounterI64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Counter(i64) {
        const counter = try self.allocator.create(StandardCounter(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardCounter(i64).init(
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer counter.deinit();

        try self.counters_i64.append(self.allocator, counter);

        return otel_api.metrics.Counter(i64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createCounterF64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Counter(f64) {
        const counter = try self.allocator.create(StandardCounter(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardCounter(f64).init(
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer counter.deinit();

        try self.counters_f64.append(self.allocator, counter);

        return otel_api.metrics.Counter(f64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createUpDownCounterI64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.UpDownCounter(i64) {
        const counter = try self.allocator.create(StandardUpDownCounter(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardUpDownCounter(i64).init(
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer counter.deinit();

        try self.up_down_counters_i64.append(self.allocator, counter);

        return otel_api.metrics.UpDownCounter(i64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createUpDownCounterF64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.UpDownCounter(f64) {
        const counter = try self.allocator.create(StandardUpDownCounter(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardUpDownCounter(f64).init(
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer counter.deinit();

        try self.up_down_counters_f64.append(self.allocator, counter);

        return otel_api.metrics.UpDownCounter(f64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createGaugeI64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Gauge(i64) {
        const counter = try self.allocator.create(StandardGauge(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardGauge(i64).init(
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer counter.deinit();

        try self.gauges_i64.append(self.allocator, counter);

        return otel_api.metrics.Gauge(i64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createGaugeF64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Gauge(f64) {
        const counter = try self.allocator.create(StandardGauge(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardGauge(f64).init(
            name,
            description,
            unit,
            self.scope,
            self.resource,
        );
        errdefer counter.deinit();

        try self.gauges_f64.append(self.allocator, counter);

        return otel_api.metrics.Gauge(f64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createHistogramI64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Histogram(i64) {
        const histogram = try self.allocator.create(StandardHistogram(i64));
        errdefer self.allocator.destroy(histogram);

        histogram.* = try StandardHistogram(i64).init(
            self.allocator,
            name,
            description,
            unit,
            self.scope,
            self.resource,
            .{}, // Use default config
        );
        errdefer histogram.deinit();

        try self.histograms_i64.append(self.allocator, histogram);

        return otel_api.metrics.Histogram(i64){
            .bridge = otel_api.metrics.InstrumentBridge.init(histogram),
        };
    }

    pub fn createHistogramF64(
        self: *StandardMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Histogram(f64) {
        const histogram = try self.allocator.create(StandardHistogram(f64));
        errdefer self.allocator.destroy(histogram);

        histogram.* = try StandardHistogram(f64).init(
            self.allocator,
            name,
            description,
            unit,
            self.scope,
            self.resource,
            .{}, // Use default config
        );
        errdefer histogram.deinit();

        try self.histograms_f64.append(self.allocator, histogram);

        return otel_api.metrics.Histogram(f64){
            .bridge = otel_api.metrics.InstrumentBridge.init(histogram),
        };
    }

    /// Collect metrics from all instruments managed by this meter
    pub fn collectMetrics(self: *StandardMeter, allocator: std.mem.Allocator) ![]MetricData {
        var metrics = std.ArrayList(MetricData).init(allocator);
        errdefer metrics.deinit();

        const timestamp_ns = @as(u64, @intCast(std.time.nanoTimestamp()));

        // Collect from i64 counters
        for (self.counters_i64.items) |counter| {
            const value = counter.getValue();
            if (value == 0) continue; // Skip empty counters

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            errdefer allocator.free(data_points);
            data_points[0] = MetricDataPoint{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .i64_sum = value },
            };

            try metrics.append(.{
                .name = counter.name,
                .description = counter.description,
                .unit = counter.unit,
                .type = .sum,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from f64 counters
        for (self.counters_f64.items) |counter| {
            const value = counter.getValue();
            if (value == 0) continue; // Skip empty counters

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .f64_sum = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = counter.name,
                .description = counter.description,
                .unit = counter.unit,
                .type = .sum,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from i64 up-down counters
        for (self.up_down_counters_i64.items) |counter| {
            const value = counter.getValue();

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .i64_sum = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = counter.name,
                .description = counter.description,
                .unit = counter.unit,
                .type = .sum,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from f64 up-down counters
        for (self.up_down_counters_f64.items) |counter| {
            const value = counter.getValue();

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .f64_sum = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = counter.name,
                .description = counter.description,
                .unit = counter.unit,
                .type = .sum,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from i64 gauges
        for (self.gauges_i64.items) |gauge| {
            const value = gauge.getValue() orelse continue; // Skip if no value recorded

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = null, // Gauges don't have start times
                .attributes = &[_]AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .i64_gauge = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = gauge.name,
                .description = gauge.description,
                .unit = gauge.unit,
                .type = .gauge,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from f64 gauges
        for (self.gauges_f64.items) |gauge| {
            const value = gauge.getValue() orelse continue; // Skip if no value recorded

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = null, // Gauges don't have start times
                .attributes = &[_]AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .f64_gauge = value },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = gauge.name,
                .description = gauge.description,
                .unit = gauge.unit,
                .type = .gauge,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from i64 histograms
        for (self.histograms_i64.items) |histogram| {
            const count = histogram.getCount();
            if (count == 0) continue; // Skip empty histograms

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = histogram.getStartTimestamp(),
                .attributes = &[_]AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{
                    .i64_histogram = .{
                        .count = count,
                        .sum = histogram.getSum(),
                        .min = histogram.getMin(),
                        .max = histogram.getMax(),
                        .boundaries = histogram.getBoundaries(),
                        .bucket_counts = try histogram.getCounts(allocator),
                    },
                },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = histogram.name,
                .description = histogram.description,
                .unit = histogram.unit,
                .type = .histogram,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        // Collect from f64 histograms
        for (self.histograms_f64.items) |histogram| {
            const count = histogram.getCount();
            if (count == 0) continue; // Skip empty histograms

            const data_point = try allocator.create(MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = histogram.getStartTimestamp(),
                .attributes = &[_]AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{
                    .f64_histogram = .{
                        .count = count,
                        .sum = histogram.getSum(),
                        .min = histogram.getMin(),
                        .max = histogram.getMax(),
                        .boundaries = histogram.getBoundaries(),
                        .bucket_counts = try histogram.getCounts(allocator),
                    },
                },
            };

            const data_points = try allocator.alloc(MetricDataPoint, 1);
            data_points[0] = data_point.*;
            allocator.destroy(data_point);

            try metrics.append(.{
                .name = histogram.name,
                .description = histogram.description,
                .unit = histogram.unit,
                .type = .histogram,
                .data_points = data_points,
                .scope = self.scope,
                .resource = self.resource,
            });
        }

        return metrics.toOwnedSlice();
    }
};
