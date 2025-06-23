//! OpenTelemetry Basic Meter Provider SDK Implementation
//!
//! This module provides the basic concrete implementation of MeterProvider for the SDK.
//! It manages meter lifecycle, caching, and configuration.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md

const std = @import("std");

const otel_api = @import("otel-api");
const Meter = otel_api.metrics.Meter;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const FlushResult = otel_api.common.FlushResult;
const Context = otel_api.Context;

const PipelineBuilder = @import("../common/pipeline.zig").PipelineBuilder;
const Resource = @import("../resource/resource.zig").Resource;
const MetricData = @import("data.zig").MetricData;
const MetricDataPoint = @import("data.zig").MetricDataPoint;
const MetricType = @import("data.zig").MetricType;
const MetricValue = @import("data.zig").MetricValue;
const MetricProcessor = @import("processor.zig").MetricProcessor;
const aggregations = @import("basic_aggregations.zig");

/// Context for meter cache HashMap
const MeterCacheContext = struct {
    pub fn hash(_: MeterCacheContext, key: InstrumentationScope) u64 {
        return key.hashCode();
    }

    pub fn eql(_: MeterCacheContext, a: InstrumentationScope, b: InstrumentationScope) bool {
        return InstrumentationScope.eql(a, b);
    }
};

/// Basic meter provider with caching and configuration
pub const BasicMeterProvider = struct {
    // internal state fields
    allocator: std.mem.Allocator,
    resource: Resource,
    cache: std.HashMapUnmanaged(InstrumentationScope, *BasicMeter, MeterCacheContext, 80),
    processors: std.ArrayListUnmanaged(MetricProcessor),
    mutex: std.Thread.Mutex,

    pub const unconfigured = .{
        .allocator = undefined,
        .resource = Resource.empty,
        .cache = .empty,
        .processors = .empty,
        .mutex = .{},
    };

    pub fn init(
        allocator: std.mem.Allocator,
        resource: Resource,
    ) BasicMeterProvider {
        return .{
            .allocator = allocator,
            .resource = resource,
            .cache = .empty,
            .processors = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *BasicMeterProvider) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Iterate over the meters.
        var iter = self.cache.iterator();
        while (iter.next()) |kv| {
            // Unregister the meter from the processors
            for (self.processors.items) |*processor| processor.unregisterMeter(kv.value_ptr.*);

            // Clean up the meter.
            kv.key_ptr.deinitOwned(self.allocator);
            kv.value_ptr.*.deinit();
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.cache.deinit(self.allocator);

        // Iterate over the processors.
        for (self.processors.items) |processor| {
            // Clean up the processor.
            processor.deinit();
            processor.destroy();
        }
        self.processors.deinit(self.allocator);

        // Clean up the resource.
        self.resource.deinitOwned(self.allocator);
    }

    /// Destroys the provider instance (assumes deinit() was already called)
    pub fn destroy(self: *BasicMeterProvider) void {
        self.allocator.destroy(self);
    }

    /// Interface defined method to get a meter.
    ///
    /// The provided scope is copied internally.
    pub fn getMeterWithScope(self: *BasicMeterProvider, scope: InstrumentationScope) !Meter {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check cache first
        if (self.cache.get(scope)) |meter| {
            return meter.meter();
        }

        // Create a locally owned Scope.
        const owned_scope = try InstrumentationScope.initOwned(self.allocator, scope);
        errdefer owned_scope.deinitOwned(self.allocator);

        // Create new SDK meter
        const std_meter = try self.allocator.create(BasicMeter);
        errdefer self.allocator.destroy(std_meter);

        std_meter.* = try BasicMeter.init(self.allocator, owned_scope, self.resource);

        // Register the meter with the processor for collection
        //
        // Iterating over processors should be thread safe as they can
        // only be mutated at start-up / single threaded.
        for (self.processors.items) |*processor| processor.registerMeter(std_meter);

        try self.cache.put(self.allocator, owned_scope, std_meter);

        return std_meter.meter();
    }

    /// Interface defined method to force the attached processor to flush.
    pub fn forceFlush(self: *BasicMeterProvider, timeout_ms: ?u64) FlushResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.processors.items) |*processor| {
            processor.collect();
            const flush_result = processor.forceFlush(timeout_ms);
            switch (flush_result) {
                .success => {},
                .failure => return .failure,
                .timeout => return .timeout,
            }
        }
        return .success;
    }

    pub fn shutdown(self: *BasicMeterProvider, timeout_ms: ?u64) void {
        // The mutex block is distinct because the mutex must be released before
        // forceFlush can be called.
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Flag each meter as shutdown to stop collection and instrument creation
            var iter = self.cache.iterator();
            while (iter.next()) |kv| {
                kv.value_ptr.*.shutdown();
            }
        }
        _ = self.forceFlush(timeout_ms);
    }

    /// Attach a processor to this provider.
    ///
    /// This method is not thread-safe and should only be called during initialization.
    pub fn registerProcessor(self: *BasicMeterProvider, processor: MetricProcessor) !void {
        try self.processors.append(self.allocator, processor);
    }

    /// Convert the provider into an API interface.
    pub fn meterProvider(self: *BasicMeterProvider) otel_api.metrics.MeterProvider {
        return otel_api.metrics.MeterProvider{ .bridge = otel_api.metrics.MeterProviderBridge.init(self) };
    }

    /// Generate a pipelinebuilder for this provider.
    pub fn pipelineBuilder(self: *BasicMeterProvider) PipelineBuilder(*BasicMeterProvider) {
        return .init(self);
    }
};

/// Basic meter implementation (formerly StandardMeter)
pub const BasicMeter = struct {
    allocator: std.mem.Allocator,
    is_shutdown: std.atomic.Value(bool),
    scope: InstrumentationScope,
    resource: Resource,

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
    ) !BasicMeter {
        return .{
            .allocator = allocator,
            .scope = scope,
            .resource = resource,
            .is_shutdown = .init(false),
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

    pub fn meter(self: *BasicMeter) otel_api.metrics.Meter {
        return otel_api.metrics.Meter{
            .bridge = otel_api.metrics.MeterBridge.init(self),
        };
    }

    pub fn deinit(self: *BasicMeter) void {
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

    pub fn shutdown(self: *BasicMeter) void {
        self.is_shutdown.store(true, .release);
    }

    pub fn createCounterI64(
        self: *BasicMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Counter(i64) {
        if (self.is_shutdown.load(.acquire)) {
            return otel_api.metrics.Counter(i64){ .noop = name };
        }

        const counter = try self.allocator.create(StandardCounter(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardCounter(i64).init(
            name,
            description,
            unit,
            self,
        );
        errdefer counter.deinit();

        try self.counters_i64.append(self.allocator, counter);

        return otel_api.metrics.Counter(i64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createCounterF64(
        self: *BasicMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Counter(f64) {
        if (self.is_shutdown.load(.acquire)) {
            return otel_api.metrics.Counter(f64){ .noop = name };
        }

        const counter = try self.allocator.create(StandardCounter(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardCounter(f64).init(
            name,
            description,
            unit,
            self,
        );
        errdefer counter.deinit();

        try self.counters_f64.append(self.allocator, counter);

        return otel_api.metrics.Counter(f64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createUpDownCounterI64(
        self: *BasicMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.UpDownCounter(i64) {
        if (self.is_shutdown.load(.acquire)) {
            return otel_api.metrics.UpDownCounter(i64){ .noop = name };
        }

        const counter = try self.allocator.create(StandardUpDownCounter(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardUpDownCounter(i64).init(
            name,
            description,
            unit,
            self,
        );
        errdefer counter.deinit();

        try self.up_down_counters_i64.append(self.allocator, counter);

        return otel_api.metrics.UpDownCounter(i64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createUpDownCounterF64(
        self: *BasicMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.UpDownCounter(f64) {
        if (self.is_shutdown.load(.acquire)) {
            return otel_api.metrics.UpDownCounter(f64){ .noop = name };
        }

        const counter = try self.allocator.create(StandardUpDownCounter(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardUpDownCounter(f64).init(
            name,
            description,
            unit,
            self,
        );
        errdefer counter.deinit();

        try self.up_down_counters_f64.append(self.allocator, counter);

        return otel_api.metrics.UpDownCounter(f64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createGaugeI64(
        self: *BasicMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Gauge(i64) {
        if (self.is_shutdown.load(.acquire)) {
            return otel_api.metrics.Gauge(i64){ .noop = name };
        }

        const counter = try self.allocator.create(StandardGauge(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardGauge(i64).init(
            name,
            description,
            unit,
            self,
        );
        errdefer counter.deinit();

        try self.gauges_i64.append(self.allocator, counter);

        return otel_api.metrics.Gauge(i64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createGaugeF64(
        self: *BasicMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Gauge(f64) {
        if (self.is_shutdown.load(.acquire)) {
            return otel_api.metrics.Gauge(f64){ .noop = name };
        }

        const counter = try self.allocator.create(StandardGauge(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try StandardGauge(f64).init(
            name,
            description,
            unit,
            self,
        );
        errdefer counter.deinit();

        try self.gauges_f64.append(self.allocator, counter);

        return otel_api.metrics.Gauge(f64){
            .bridge = otel_api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createHistogramI64(
        self: *BasicMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Histogram(i64) {
        if (self.is_shutdown.load(.acquire)) {
            return otel_api.metrics.Histogram(i64){ .noop = name };
        }

        const histogram = try self.allocator.create(StandardHistogram(i64));
        errdefer self.allocator.destroy(histogram);

        histogram.* = try StandardHistogram(i64).init(
            self.allocator,
            name,
            description,
            unit,
            self,
            .{}, // Use default config
        );
        errdefer histogram.deinit();

        try self.histograms_i64.append(self.allocator, histogram);

        return otel_api.metrics.Histogram(i64){
            .bridge = otel_api.metrics.InstrumentBridge.init(histogram),
        };
    }

    pub fn createHistogramF64(
        self: *BasicMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !otel_api.metrics.Histogram(f64) {
        if (self.is_shutdown.load(.acquire)) {
            return otel_api.metrics.Histogram(f64){ .noop = name };
        }

        const histogram = try self.allocator.create(StandardHistogram(f64));
        errdefer self.allocator.destroy(histogram);

        histogram.* = try StandardHistogram(f64).init(
            self.allocator,
            name,
            description,
            unit,
            self,
            .{}, // Use default config
        );
        errdefer histogram.deinit();

        try self.histograms_f64.append(self.allocator, histogram);

        return otel_api.metrics.Histogram(f64){
            .bridge = otel_api.metrics.InstrumentBridge.init(histogram),
        };
    }

    /// Collect metrics from all instruments managed by this meter
    pub fn collectMetrics(self: *BasicMeter, allocator: std.mem.Allocator) ![]MetricData {
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

// Instrument implementations are now local to this file

/// Standard Counter implementation with sum aggregation
fn StandardCounter(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        parent_meter: *BasicMeter,
        aggregation: aggregations.SumAggregation(T),
        mutex: std.Thread.Mutex,

        fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *BasicMeter,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .parent_meter = parent_meter,
                .aggregation = aggregations.SumAggregation(T).init(),
                .mutex = std.Thread.Mutex{},
            };
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == i64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn addF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == f64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn recordI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn recordF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        fn getValue(self: *@This()) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getValue();
        }

        fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.aggregation.reset();
        }

        fn getStartTimestamp(self: *@This()) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getStartTime();
        }
    };
}

/// Standard UpDownCounter implementation with sum aggregation (allowing negative)
fn StandardUpDownCounter(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        parent_meter: *BasicMeter,
        aggregation: aggregations.SumAggregation(T),
        mutex: std.Thread.Mutex,

        fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *BasicMeter,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .parent_meter = parent_meter,
                .aggregation = aggregations.SumAggregation(T).init(),
                .mutex = std.Thread.Mutex{},
            };
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == i64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn addF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == f64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.add(value);
            } else {
                unreachable;
            }
        }

        pub fn recordI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn recordF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        fn getValue(self: *@This()) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getValue();
        }

        fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.aggregation.reset();
        }

        fn getStartTimestamp(self: *@This()) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getStartTime();
        }
    };
}

/// Standard Gauge implementation with last value aggregation
fn StandardGauge(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        parent_meter: *BasicMeter,
        aggregation: aggregations.LastValueAggregation(T),
        mutex: std.Thread.Mutex,

        fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *BasicMeter,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .parent_meter = parent_meter,
                .aggregation = aggregations.LastValueAggregation(T).init(),
                .mutex = std.Thread.Mutex{},
            };
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn addF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn recordI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == i64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.record(value);
            } else {
                unreachable;
            }
        }

        pub fn recordF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == f64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.record(value);
            } else {
                unreachable;
            }
        }

        fn getValue(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getValue();
        }

        fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.aggregation.reset();
        }
    };
}

/// Standard Histogram implementation with histogram aggregation
fn StandardHistogram(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        parent_meter: *BasicMeter,
        aggregation: aggregations.HistogramAggregation(T),
        mutex: std.Thread.Mutex,
        allocator: std.mem.Allocator,

        fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *BasicMeter,
            config: aggregations.HistogramAggregationConfig,
        ) !@This() {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .parent_meter = parent_meter,
                .aggregation = try aggregations.HistogramAggregation(T).init(allocator, config),
                .mutex = std.Thread.Mutex{},
                .allocator = allocator,
            };
        }

        fn deinit(self: *@This()) void {
            self.aggregation.deinit(self.allocator);
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn addF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn recordI64(self: *@This(), ctx: Context, value: i64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == i64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.record(value);
            } else {
                unreachable;
            }
        }

        pub fn recordF64(self: *@This(), ctx: Context, value: f64, attributes: []const AttributeKeyValue) void {
            _ = ctx;
            _ = attributes;
            if (T == f64) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.aggregation.record(value);
            } else {
                unreachable;
            }
        }

        fn getCount(self: *@This()) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getCount();
        }

        fn getSum(self: *@This()) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getSum();
        }

        fn getMin(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getMin();
        }

        fn getMax(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getMax();
        }

        fn getStartTimestamp(self: *@This()) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aggregation.getStartTime();
        }

        fn getBoundaries(self: *@This()) []const f64 {
            return self.aggregation.getBoundaries();
        }

        fn getCounts(self: *@This(), allocator: std.mem.Allocator) ![]u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            const counts = try allocator.dupe(u64, self.aggregation.getCounts());
            return counts;
        }

        fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.aggregation.reset();
        }
    };
}

// Import test dependencies
const MockMetricExporter = @import("exporter.zig").MockMetricExporter;
const BasicMetricProcessor = @import("basic_processor.zig").BasicMetricProcessor;
const ResourceBuilder = @import("../resource/resource.zig").ResourceBuilder;

// Helper function to cleanup MetricData memory
fn cleanupMetrics(allocator: std.mem.Allocator, metrics: []MetricData) void {
    for (metrics) |metric| {
        // Free histogram bucket_counts if present (must do this before freeing data_points)
        for (metric.data_points) |data_point| {
            switch (data_point.value) {
                .i64_histogram => |hist| allocator.free(hist.bucket_counts),
                .f64_histogram => |hist| allocator.free(hist.bucket_counts),
                else => {},
            }
        }

        // Free data_points array
        allocator.free(metric.data_points);
    }
    allocator.free(metrics);
}

test "BasicMeterProvider lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create resource
    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    // Create provider (takes ownership of resource)
    var provider = BasicMeterProvider.init(allocator, resource);
    defer provider.deinit();

    try testing.expect(provider.processors.items.len == 0);
    try testing.expect(provider.cache.count() == 0);
}

test "BasicMeterProvider meter caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicMeterProvider.init(allocator, resource);
    defer provider.deinit();

    const scope1 = try InstrumentationScope.initSimple("test.meter", "1.0.0");
    const scope2 = try InstrumentationScope.initSimple("test.meter", "1.0.0"); // Same
    const scope3 = try InstrumentationScope.initSimple("other.meter", "1.0.0"); // Different

    const meter1 = try provider.getMeterWithScope(scope1);
    const meter2 = try provider.getMeterWithScope(scope2);
    const meter3 = try provider.getMeterWithScope(scope3);

    // Same scope should return same meter instance
    try testing.expect(meter1.bridge.meter_ptr == meter2.bridge.meter_ptr);
    try testing.expect(meter1.bridge.meter_ptr != meter3.bridge.meter_ptr);

    // Verify cache contains 2 unique entries
    try testing.expectEqual(@as(u32, 2), provider.cache.count());
}

test "BasicMeterProvider processor registration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicMeterProvider.init(allocator, resource);
    defer provider.deinit();

    try @import("../common/pipeline.zig").PipelineBuilder(*BasicMeterProvider).init(&provider)
        .with(BasicMetricProcessor.PipelineStep.init({}).flowTo(MockMetricExporter.PipelineStep.init({})))
        .done();

    try testing.expectEqual(@as(usize, 1), provider.processors.items.len);
}

test "BasicMeter instrument creation and data collection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicMeterProvider.init(allocator, resource);
    defer provider.deinit();

    const scope = try InstrumentationScope.initSimple("test.meter", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Create various instrument types
    const counter_i64 = try meter.createCounter(i64, "test.counter.i64", "Test counter", "requests");
    const counter_f64 = try meter.createCounter(f64, "test.counter.f64", "Test counter", "seconds");
    const updown_i64 = try meter.createUpDownCounter(i64, "test.updown.i64", "Test updown", "connections");
    const gauge_i64 = try meter.createGauge(i64, "test.gauge.i64", "Test gauge", "bytes");
    const histogram_f64 = try meter.createHistogram(f64, "test.histogram.f64", "Test histogram", "ms");

    const ctx = Context.init(allocator);
    const empty_attributes = [_]AttributeKeyValue{};

    // Record some measurements
    counter_i64.add(ctx, 10, &empty_attributes);
    counter_i64.add(ctx, 5, &empty_attributes);
    counter_f64.add(ctx, 3.14, &empty_attributes);
    updown_i64.add(ctx, 5, &empty_attributes);
    updown_i64.add(ctx, -2, &empty_attributes);
    gauge_i64.record(ctx, 42, &empty_attributes);
    histogram_f64.record(ctx, 15.5, &empty_attributes);
    histogram_f64.record(ctx, 25.0, &empty_attributes);

    // Get the BasicMeter instance for direct collectMetrics call
    const basic_meter: *BasicMeter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // Collect metrics directly
    const metrics = try basic_meter.collectMetrics(allocator);
    defer cleanupMetrics(allocator, metrics);

    // We should have metrics for each instrument that recorded data
    // Note: Empty instruments might be skipped, so we check for >= expected minimums
    try testing.expect(metrics.len >= 5);

    // Verify each metric has proper structure
    for (metrics) |metric| {
        try testing.expect(metric.name.len > 0);
        try testing.expect(metric.data_points.len > 0);
        try testing.expect(InstrumentationScope.eql(metric.scope, scope));

        // Test attributes are empty (MVP state)
        // TODO: This test should break when attributes are implemented
        for (metric.data_points) |data_point| {
            try testing.expectEqual(@as(usize, 0), data_point.attributes.len);
        }
    }
}

test "BasicMeter data collection through processor pipeline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicMeterProvider.init(allocator, resource);
    defer provider.deinit();

    // Create mock exporter
    const mock_exporter = try allocator.create(MockMetricExporter);
    mock_exporter.* = MockMetricExporter.init(allocator);
    // Processor takes ownership of this memory

    // Create processor (heap-allocated)
    const processor = try allocator.create(BasicMetricProcessor);
    processor.* = BasicMetricProcessor.init(allocator, mock_exporter.metricExporter());

    // Register processor (provider takes ownership)
    try provider.registerProcessor(processor.metricProcessor());

    // Get meter
    const scope = try InstrumentationScope.initSimple("test.meter", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Create instruments and record data
    const counter = try meter.createCounter(i64, "http.requests", "HTTP requests", "requests");
    const histogram = try meter.createHistogram(f64, "http.duration", "HTTP duration", "ms");

    const ctx = Context.init(allocator);
    const empty_attributes = [_]AttributeKeyValue{};

    counter.add(ctx, 5, &empty_attributes);
    counter.add(ctx, 3, &empty_attributes);
    histogram.record(ctx, 12.5, &empty_attributes);
    histogram.record(ctx, 25.0, &empty_attributes);

    // Force collection via processor (pull model)
    processor.collect();

    // Verify metrics were exported
    try testing.expect(mock_exporter.metricCount() > 0);

    // Check that we have the expected metric types
    var found_counter = false;
    var found_histogram = false;

    for (0..mock_exporter.metricCount()) |i| {
        if (mock_exporter.getMetric(i)) |metric| {
            if (std.mem.eql(u8, metric.name, "http.requests")) {
                found_counter = true;
                try testing.expectEqual(MetricType.sum, metric.type);
                try testing.expect(metric.data_points.len > 0);
            } else if (std.mem.eql(u8, metric.name, "http.duration")) {
                found_histogram = true;
                try testing.expectEqual(MetricType.histogram, metric.type);
                try testing.expect(metric.data_points.len > 0);
            }
        }
    }

    try testing.expect(found_counter);
    try testing.expect(found_histogram);
}

test "BasicMeter shutdown behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicMeterProvider.init(allocator, resource);
    defer provider.deinit();

    const scope = try InstrumentationScope.initSimple("test.meter", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Create counter and record data before shutdown
    const counter = try meter.createCounter(i64, "test.counter", "Test counter", "requests");
    const ctx = Context.init(allocator);
    const empty_attributes = [_]AttributeKeyValue{};

    counter.add(ctx, 10, &empty_attributes);

    // Get the BasicMeter instance for direct access
    const basic_meter: *BasicMeter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // Verify data exists before shutdown
    const metrics_before = try basic_meter.collectMetrics(allocator);
    defer cleanupMetrics(allocator, metrics_before);
    try testing.expect(metrics_before.len > 0);

    // Shutdown the meter
    basic_meter.shutdown();
    try testing.expect(basic_meter.is_shutdown.load(.unordered));

    // Test that collectMetrics still works after shutdown (data preserved)
    const metrics_after = try basic_meter.collectMetrics(allocator);
    defer cleanupMetrics(allocator, metrics_after);
    try testing.expect(metrics_after.len > 0);

    // TODO: The following test should work when shutdown behavior is fully implemented
    // Currently commented out as it may not be implemented yet
    //
    // // Try to record new data after shutdown - should be ignored
    // counter.add(ctx, 5, &empty_attributes);
    //
    // // Verify the counter value didn't change
    // const metrics_final = try basic_meter.collectMetrics(allocator);
    // defer allocator.free(metrics_final);
    // // Should still have same data as before the post-shutdown recording
}

test "BasicMeterProvider flush behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicMeterProvider.init(allocator, resource);
    defer provider.deinit();

    const mock_exporter = try allocator.create(MockMetricExporter);
    mock_exporter.* = MockMetricExporter.init(allocator);

    const processor = try allocator.create(BasicMetricProcessor);
    processor.* = BasicMetricProcessor.init(allocator, mock_exporter.metricExporter());

    try provider.registerProcessor(processor.metricProcessor());

    // Test successful flush
    const result = provider.forceFlush(1000);
    try testing.expectEqual(FlushResult.success, result);

    // Test flush with failure
    mock_exporter.flush_result = .failure;
    const result2 = provider.forceFlush(1000);
    try testing.expectEqual(FlushResult.failure, result2);
}

test "BasicMeter comprehensive instrument test with attributes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicMeterProvider.init(allocator, resource);
    defer provider.deinit();

    const scope = try InstrumentationScope.initSimple("test.meter", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Test custom histogram boundaries (for future use)
    _ = [_]f64{ 0.0, 1.0, 5.0, 10.0, 50.0 };

    // Create all instrument types with different value types
    const counter_i64 = try meter.createCounter(i64, "test.counter.i64", "Test i64 counter", "ops");
    const counter_f64 = try meter.createCounter(f64, "test.counter.f64", "Test f64 counter", "seconds");
    const updown_i64 = try meter.createUpDownCounter(i64, "test.updown.i64", "Test i64 updown", "items");
    const updown_f64 = try meter.createUpDownCounter(f64, "test.updown.f64", "Test f64 updown", "temperature");
    const gauge_i64 = try meter.createGauge(i64, "test.gauge.i64", "Test i64 gauge", "bytes");
    const gauge_f64 = try meter.createGauge(f64, "test.gauge.f64", "Test f64 gauge", "ratio");
    const histogram_i64 = try meter.createHistogram(i64, "test.histogram.i64", "Test i64 histogram", "count");
    const histogram_f64 = try meter.createHistogram(f64, "test.histogram.f64", "Test f64 histogram", "latency");

    const ctx = Context.init(allocator);
    const empty_attributes = [_]AttributeKeyValue{};

    // TODO: Test with attributes when attribute support is implemented
    // This test should break when attributes are added to remind us to update it
    // const attributes = [_]AttributeKeyValue{
    //     .{ .key = "method", .value = .{ .string = "GET" } },
    //     .{ .key = "status", .value = .{ .int = 200 } },
    // };

    // Record various measurements
    counter_i64.add(ctx, 15, &empty_attributes);
    counter_i64.add(ctx, 25, &empty_attributes); // Total: 40
    counter_f64.add(ctx, 3.14, &empty_attributes);
    counter_f64.add(ctx, 2.86, &empty_attributes); // Total: 6.0

    updown_i64.add(ctx, 10, &empty_attributes);
    updown_i64.add(ctx, -3, &empty_attributes); // Total: 7
    updown_f64.add(ctx, 5.5, &empty_attributes);
    updown_f64.add(ctx, -1.5, &empty_attributes); // Total: 4.0

    gauge_i64.record(ctx, 1024, &empty_attributes);
    gauge_i64.record(ctx, 2048, &empty_attributes); // Last: 2048
    gauge_f64.record(ctx, 0.85, &empty_attributes);
    gauge_f64.record(ctx, 0.92, &empty_attributes); // Last: 0.92

    // Test histogram with various values to hit different buckets
    histogram_i64.record(ctx, 2, &empty_attributes); // bucket 1 (1-5)
    histogram_i64.record(ctx, 7, &empty_attributes); // bucket 2 (5-10)
    histogram_i64.record(ctx, 15, &empty_attributes); // bucket 3 (10-50)
    histogram_f64.record(ctx, 0.5, &empty_attributes); // bucket 0 (0-1)
    histogram_f64.record(ctx, 3.2, &empty_attributes); // bucket 1 (1-5)
    histogram_f64.record(ctx, 25.0, &empty_attributes); // bucket 3 (10-50)

    // Get the BasicMeter instance for direct collectMetrics call
    const basic_meter: *BasicMeter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // Collect metrics
    const metrics = try basic_meter.collectMetrics(allocator);
    defer cleanupMetrics(allocator, metrics);

    // Should have metrics for all instruments with recorded data
    try testing.expect(metrics.len >= 8);

    // Verify comprehensive metric properties
    var counters_found: u32 = 0;
    var gauges_found: u32 = 0;
    var histograms_found: u32 = 0;

    for (metrics) |metric| {
        // Verify common properties
        try testing.expect(metric.name.len > 0);
        try testing.expect(metric.data_points.len > 0);
        try testing.expect(InstrumentationScope.eql(metric.scope, scope));

        // Verify timestamps exist
        for (metric.data_points) |data_point| {
            try testing.expect(data_point.timestamp_ns > 0);

            // TODO: This test should break when attributes are implemented
            try testing.expectEqual(@as(usize, 0), data_point.attributes.len);
        }

        // Count metric types
        switch (metric.type) {
            .sum => counters_found += 1,
            .gauge => gauges_found += 1,
            .histogram => histograms_found += 1,
        }
    }

    // Verify we found all expected metric types
    // Note: Both counters and updown counters report as .sum type
    try testing.expect(counters_found >= 4); // 2 counters + 2 updown counters
    try testing.expect(gauges_found >= 2); // 2 gauges
    try testing.expect(histograms_found >= 2); // 2 histograms
}

test "BasicMeter instrument creation after shutdown returns noop instruments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try ResourceBuilder.init(allocator)
        .withDefaults()
        .finish(allocator);

    var provider = BasicMeterProvider.init(allocator, resource);
    defer provider.deinit();

    const scope = try InstrumentationScope.initSimple("test.meter", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Create instrument before shutdown - should be normal SDK instrument
    const counter_before = try meter.createCounter(i64, "test.counter.before", "Test counter", "requests");
    try testing.expect(counter_before == .bridge); // Should be bridge to SDK instrument

    // Get the BasicMeter instance to shutdown directly
    const basic_meter: *BasicMeter = @ptrCast(@alignCast(meter.bridge.meter_ptr));
    basic_meter.shutdown();

    // Create instruments after shutdown - should be noop instruments
    const counter_after = try meter.createCounter(i64, "test.counter.after", "Test counter", "requests");
    const updown_after = try meter.createUpDownCounter(f64, "test.updown.after", "Test updown", "bytes");
    const gauge_after = try meter.createGauge(i64, "test.gauge.after", "Test gauge", "items");
    const histogram_after = try meter.createHistogram(f64, "test.histogram.after", "Test histogram", "ms");

    // All instruments created after shutdown should be noop
    try testing.expect(counter_after == .noop);
    try testing.expect(updown_after == .noop);
    try testing.expect(gauge_after == .noop);
    try testing.expect(histogram_after == .noop);

    // Verify noop instruments have the correct names
    try testing.expectEqualStrings("test.counter.after", counter_after.noop);
    try testing.expectEqualStrings("test.updown.after", updown_after.noop);
    try testing.expectEqualStrings("test.gauge.after", gauge_after.noop);
    try testing.expectEqualStrings("test.histogram.after", histogram_after.noop);
}
