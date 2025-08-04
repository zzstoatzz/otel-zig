const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const AsyncInstrumentConfig = @import("async_instrument_config.zig").AsyncInstrumentConfig;
    const MetricData = @import("data.zig").MetricData;
    const MetricDataPoint = @import("data.zig").MetricDataPoint;
    const Resource = @import("../resource/resource.zig").Resource;
    const async_instr = @import("async_instruments.zig");
    const sync_instr = @import("instruments.zig");
};

/// Basic meter implementation (formerly StandardMeter)
pub const Meter = struct {
    allocator: std.mem.Allocator,
    is_shutdown: std.atomic.Value(bool),
    scope: api.InstrumentationScope,
    resource: sdk.Resource,

    // Synchronous instruments
    counters_i64: std.ArrayListUnmanaged(*sdk.sync_instr.StandardCounter(i64)),
    counters_f64: std.ArrayListUnmanaged(*sdk.sync_instr.StandardCounter(f64)),
    up_down_counters_i64: std.ArrayListUnmanaged(*sdk.sync_instr.StandardUpDownCounter(i64)),
    up_down_counters_f64: std.ArrayListUnmanaged(*sdk.sync_instr.StandardUpDownCounter(f64)),
    gauges_i64: std.ArrayListUnmanaged(*sdk.sync_instr.StandardGauge(i64)),
    gauges_f64: std.ArrayListUnmanaged(*sdk.sync_instr.StandardGauge(f64)),
    histograms_i64: std.ArrayListUnmanaged(*sdk.sync_instr.StandardHistogram(i64)),
    histograms_f64: std.ArrayListUnmanaged(*sdk.sync_instr.StandardHistogram(f64)),

    // Observable instruments
    observable_counters_i64: std.ArrayListUnmanaged(*sdk.async_instr.ObservableCounter(i64)),
    observable_counters_f64: std.ArrayListUnmanaged(*sdk.async_instr.ObservableCounter(f64)),
    observable_gauges_i64: std.ArrayListUnmanaged(*sdk.async_instr.ObservableGauge(i64)),
    observable_gauges_f64: std.ArrayListUnmanaged(*sdk.async_instr.ObservableGauge(f64)),
    observable_updown_counters_i64: std.ArrayListUnmanaged(*sdk.async_instr.ObservableUpDownCounter(i64)),
    observable_updown_counters_f64: std.ArrayListUnmanaged(*sdk.async_instr.ObservableUpDownCounter(f64)),

    // Configuration for async instruments
    async_config: sdk.AsyncInstrumentConfig,

    pub fn init(
        allocator: std.mem.Allocator,
        scope: api.InstrumentationScope,
        resource: sdk.Resource,
    ) !Meter {
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
            .observable_counters_i64 = .empty,
            .observable_counters_f64 = .empty,
            .observable_gauges_i64 = .empty,
            .observable_gauges_f64 = .empty,
            .observable_updown_counters_i64 = .empty,
            .observable_updown_counters_f64 = .empty,
            .async_config = .default,
        };
    }

    pub fn meter(self: *Meter) api.metrics.Meter {
        return api.metrics.Meter{ .bridge = api.metrics.MeterBridge.init(self) };
    }

    pub fn deinit(self: *Meter) void {
        const instruments = .{
            self.counters_i64,
            self.counters_f64,
            self.up_down_counters_i64,
            self.up_down_counters_f64,
            self.gauges_i64,
            self.gauges_f64,
            self.histograms_i64,
            self.histograms_f64,
            self.observable_counters_i64,
            self.observable_counters_f64,
            self.observable_gauges_i64,
            self.observable_gauges_f64,
            self.observable_updown_counters_i64,
            self.observable_updown_counters_f64,
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
            // TODO: why can't this just capture the pointer?
            var mutable_list = list;
            mutable_list.deinit(self.allocator);
        }
    }

    pub fn shutdown(self: *Meter) void {
        self.is_shutdown.store(true, .release);
    }

    pub fn createCounterI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Counter(i64) {
        _ = advisory; // Ignore advisory parameters for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.Counter(i64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const counter = try self.allocator.create(sdk.sync_instr.StandardCounter(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try sdk.sync_instr.StandardCounter(i64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit();

        try self.counters_i64.append(self.allocator, counter);

        return api.metrics.Counter(i64){
            .bridge = api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createCounterF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Counter(f64) {
        _ = advisory; // Ignore advisory parameters for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.Counter(f64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const counter = try self.allocator.create(sdk.sync_instr.StandardCounter(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try sdk.sync_instr.StandardCounter(f64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit();

        try self.counters_f64.append(self.allocator, counter);

        return api.metrics.Counter(f64){
            .bridge = api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createUpDownCounterI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.UpDownCounter(i64) {
        _ = advisory; // Ignore advisory parameters for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.UpDownCounter(i64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const counter = try self.allocator.create(sdk.sync_instr.StandardUpDownCounter(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try sdk.sync_instr.StandardUpDownCounter(i64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit();

        try self.up_down_counters_i64.append(self.allocator, counter);

        return api.metrics.UpDownCounter(i64){
            .bridge = api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createUpDownCounterF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.UpDownCounter(f64) {
        _ = advisory; // Ignore advisory parameters for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.UpDownCounter(f64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const counter = try self.allocator.create(sdk.sync_instr.StandardUpDownCounter(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try sdk.sync_instr.StandardUpDownCounter(f64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit();

        try self.up_down_counters_f64.append(self.allocator, counter);

        return api.metrics.UpDownCounter(f64){
            .bridge = api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createGaugeI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Gauge(i64) {
        _ = advisory; // Ignore advisory parameters for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.Gauge(i64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const counter = try self.allocator.create(sdk.sync_instr.StandardGauge(i64));
        errdefer self.allocator.destroy(counter);

        counter.* = try sdk.sync_instr.StandardGauge(i64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit();

        try self.gauges_i64.append(self.allocator, counter);

        return api.metrics.Gauge(i64){
            .bridge = api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createGaugeF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Gauge(f64) {
        _ = advisory; // Ignore advisory parameters for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.Gauge(f64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const counter = try self.allocator.create(sdk.sync_instr.StandardGauge(f64));
        errdefer self.allocator.destroy(counter);

        counter.* = try sdk.sync_instr.StandardGauge(f64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit();

        try self.gauges_f64.append(self.allocator, counter);

        return api.metrics.Gauge(f64){
            .bridge = api.metrics.InstrumentBridge.init(counter),
        };
    }

    pub fn createHistogramI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Histogram(i64) {
        _ = advisory; // Ignore advisory parameters for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.Histogram(i64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const histogram = try self.allocator.create(sdk.sync_instr.StandardHistogram(i64));
        errdefer self.allocator.destroy(histogram);

        histogram.* = try sdk.sync_instr.StandardHistogram(i64).init(
            self.allocator,
            validated_name,
            validated_description,
            validated_unit,
            self,
            .{}, // Use default config
        );
        errdefer histogram.deinit();

        try self.histograms_i64.append(self.allocator, histogram);

        return api.metrics.Histogram(i64){
            .bridge = api.metrics.InstrumentBridge.init(histogram),
        };
    }

    pub fn createHistogramF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Histogram(f64) {
        _ = advisory; // Ignore advisory parameters for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.Histogram(f64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const histogram = try self.allocator.create(sdk.sync_instr.StandardHistogram(f64));
        errdefer self.allocator.destroy(histogram);

        histogram.* = try sdk.sync_instr.StandardHistogram(f64).init(
            self.allocator,
            validated_name,
            validated_description,
            validated_unit,
            self,
            .{}, // Use default config
        );
        errdefer histogram.deinit();

        try self.histograms_f64.append(self.allocator, histogram);

        return api.metrics.Histogram(f64){
            .bridge = api.metrics.InstrumentBridge.init(histogram),
        };
    }

    // Observable instrument creation methods

    pub fn createObservableCounterI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback,
    ) !api.metrics.ObservableCounter(i64) {
        _ = advisory; // Ignore advisory parameters for now
        _ = callbacks; // Ignore creation-time callbacks for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.ObservableCounter(i64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const observable_counter = try self.allocator.create(sdk.async_instr.ObservableCounter(i64));
        errdefer self.allocator.destroy(observable_counter);

        observable_counter.* = sdk.async_instr.ObservableCounter(i64).init(
            self.allocator,
            validated_name,
            validated_description,
            validated_unit,
            self.async_config,
        );
        errdefer observable_counter.deinit();

        try self.observable_counters_i64.append(self.allocator, observable_counter);

        return api.metrics.ObservableCounter(i64){
            .bridge = api.metrics.AsyncInstrumentBridge.init(observable_counter),
        };
    }

    pub fn createObservableCounterF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback,
    ) !api.metrics.ObservableCounter(f64) {
        _ = advisory; // Ignore advisory parameters for now
        _ = callbacks; // Ignore creation-time callbacks for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.ObservableCounter(f64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const observable_counter = try self.allocator.create(sdk.async_instr.ObservableCounter(f64));
        errdefer self.allocator.destroy(observable_counter);

        observable_counter.* = sdk.async_instr.ObservableCounter(f64).init(
            self.allocator,
            validated_name,
            validated_description,
            validated_unit,
            self.async_config,
        );
        errdefer observable_counter.deinit();

        try self.observable_counters_f64.append(self.allocator, observable_counter);

        return api.metrics.ObservableCounter(f64){
            .bridge = api.metrics.AsyncInstrumentBridge.init(observable_counter),
        };
    }

    pub fn createObservableGaugeI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback,
    ) !api.metrics.ObservableGauge(i64) {
        _ = advisory; // Ignore advisory parameters for now
        _ = callbacks; // Ignore creation-time callbacks for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.ObservableGauge(i64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const observable_gauge = try self.allocator.create(sdk.async_instr.ObservableGauge(i64));
        errdefer self.allocator.destroy(observable_gauge);

        observable_gauge.* = sdk.async_instr.ObservableGauge(i64).init(
            self.allocator,
            validated_name,
            validated_description,
            validated_unit,
            self.async_config,
        );
        errdefer observable_gauge.deinit();

        try self.observable_gauges_i64.append(self.allocator, observable_gauge);

        return api.metrics.ObservableGauge(i64){
            .bridge = api.metrics.AsyncInstrumentBridge.init(observable_gauge),
        };
    }

    pub fn createObservableGaugeF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback,
    ) !api.metrics.ObservableGauge(f64) {
        _ = advisory; // Ignore advisory parameters for now
        _ = callbacks; // Ignore creation-time callbacks for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.ObservableGauge(f64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const observable_gauge = try self.allocator.create(sdk.async_instr.ObservableGauge(f64));
        errdefer self.allocator.destroy(observable_gauge);

        observable_gauge.* = sdk.async_instr.ObservableGauge(f64).init(
            self.allocator,
            validated_name,
            validated_description,
            validated_unit,
            self.async_config,
        );
        errdefer observable_gauge.deinit();

        try self.observable_gauges_f64.append(self.allocator, observable_gauge);

        return api.metrics.ObservableGauge(f64){
            .bridge = api.metrics.AsyncInstrumentBridge.init(observable_gauge),
        };
    }

    pub fn createObservableUpDownCounterI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback,
    ) !api.metrics.ObservableUpDownCounter(i64) {
        _ = advisory; // Ignore advisory parameters for now
        _ = callbacks; // Ignore creation-time callbacks for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.ObservableUpDownCounter(i64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const observable_counter = try self.allocator.create(sdk.async_instr.ObservableUpDownCounter(i64));
        errdefer self.allocator.destroy(observable_counter);

        observable_counter.* = sdk.async_instr.ObservableUpDownCounter(i64).init(
            self.allocator,
            validated_name,
            validated_description,
            validated_unit,
            self.async_config,
        );
        errdefer observable_counter.deinit();

        try self.observable_updown_counters_i64.append(self.allocator, observable_counter);

        return api.metrics.ObservableUpDownCounter(i64){
            .bridge = api.metrics.AsyncInstrumentBridge.init(observable_counter),
        };
    }

    pub fn createObservableUpDownCounterF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback,
    ) !api.metrics.ObservableUpDownCounter(f64) {
        _ = advisory; // Ignore advisory parameters for now
        _ = callbacks; // Ignore creation-time callbacks for now
        if (self.is_shutdown.load(.acquire)) {
            return api.metrics.ObservableUpDownCounter(f64){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        const observable_counter = try self.allocator.create(sdk.async_instr.ObservableUpDownCounter(f64));
        errdefer self.allocator.destroy(observable_counter);

        observable_counter.* = sdk.async_instr.ObservableUpDownCounter(f64).init(
            self.allocator,
            validated_name,
            validated_description,
            validated_unit,
            self.async_config,
        );
        errdefer observable_counter.deinit();

        try self.observable_updown_counters_f64.append(self.allocator, observable_counter);

        return api.metrics.ObservableUpDownCounter(f64){
            .bridge = api.metrics.AsyncInstrumentBridge.init(observable_counter),
        };
    }

    /// Collect metrics from all instruments managed by this meter
    pub fn collectMetrics(self: *Meter, allocator: std.mem.Allocator) ![]sdk.MetricData {
        var metrics = std.ArrayList(sdk.MetricData).init(allocator);
        errdefer metrics.deinit();

        const timestamp_ns = @as(u64, @intCast(std.time.nanoTimestamp()));

        // Collect from i64 counters
        for (self.counters_i64.items) |counter| {
            const value = counter.getValue();
            if (value == 0) continue; // Skip empty counters

            const data_points = try allocator.alloc(sdk.MetricDataPoint, 1);
            errdefer allocator.free(data_points);
            data_points[0] = sdk.MetricDataPoint{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]api.AttributeKeyValue{}, // MVP: no attribute support yet
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

            const data_point = try allocator.create(sdk.MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]api.AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .f64_sum = value },
            };

            const data_points = try allocator.alloc(sdk.MetricDataPoint, 1);
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

            const data_point = try allocator.create(sdk.MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]api.AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .i64_sum = value },
            };

            const data_points = try allocator.alloc(sdk.MetricDataPoint, 1);
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

            const data_point = try allocator.create(sdk.MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = counter.getStartTimestamp(),
                .attributes = &[_]api.AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .f64_sum = value },
            };

            const data_points = try allocator.alloc(sdk.MetricDataPoint, 1);
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

            const data_point = try allocator.create(sdk.MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = null, // Gauges don't have start times
                .attributes = &[_]api.AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .i64_gauge = value },
            };

            const data_points = try allocator.alloc(sdk.MetricDataPoint, 1);
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

            const data_point = try allocator.create(sdk.MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = null, // Gauges don't have start times
                .attributes = &[_]api.AttributeKeyValue{}, // MVP: no attribute support yet
                .value = .{ .f64_gauge = value },
            };

            const data_points = try allocator.alloc(sdk.MetricDataPoint, 1);
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

            const data_point = try allocator.create(sdk.MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = histogram.getStartTimestamp(),
                .attributes = &[_]api.AttributeKeyValue{}, // MVP: no attribute support yet
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

            const data_points = try allocator.alloc(sdk.MetricDataPoint, 1);
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

            const data_point = try allocator.create(sdk.MetricDataPoint);
            data_point.* = .{
                .timestamp_ns = timestamp_ns,
                .start_timestamp_ns = histogram.getStartTimestamp(),
                .attributes = &[_]api.AttributeKeyValue{}, // MVP: no attribute support yet
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

            const data_points = try allocator.alloc(sdk.MetricDataPoint, 1);
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

        // Collect from observable instruments
        try self.collectAsynchronousMetrics(allocator, &metrics);

        return metrics.toOwnedSlice();
    }

    /// Collect metrics from all observable instruments
    fn collectAsynchronousMetrics(self: *Meter, allocator: std.mem.Allocator, metrics: *std.ArrayList(sdk.MetricData)) !void {
        // Collect from i64 observable counters
        for (self.observable_counters_i64.items) |counter| {
            const data_points = try counter.collect(allocator);
            if (data_points.len == 0) continue; // Skip if no measurements

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

        // Collect from f64 observable counters
        for (self.observable_counters_f64.items) |counter| {
            const data_points = try counter.collect(allocator);
            if (data_points.len == 0) continue; // Skip if no measurements

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

        // Collect from i64 observable gauges
        for (self.observable_gauges_i64.items) |gauge| {
            const data_points = try gauge.collect(allocator);
            if (data_points.len == 0) continue; // Skip if no measurements

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

        // Collect from f64 observable gauges
        for (self.observable_gauges_f64.items) |gauge| {
            const data_points = try gauge.collect(allocator);
            if (data_points.len == 0) continue; // Skip if no measurements

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

        // Collect from i64 observable up-down counters
        for (self.observable_updown_counters_i64.items) |counter| {
            const data_points = try counter.collect(allocator);
            if (data_points.len == 0) continue; // Skip if no measurements

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

        // Collect from f64 observable up-down counters
        for (self.observable_updown_counters_f64.items) |counter| {
            const data_points = try counter.collect(allocator);
            if (data_points.len == 0) continue; // Skip if no measurements

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
    }
};
