const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const metrics = struct {
        const InstrumentType = @import("metadata.zig").InstrumentType;
        const MeterProvider = @import("meter_provider.zig").MeterProvider;
        const Reader = @import("reader.zig").Reader;
        const async_instr = @import("async_instruments.zig");
        const sync_instr = @import("instruments.zig");
    };
};

/// Basic meter implementation (formerly StandardMeter)
pub const Meter = struct {
    provider: *sdk.metrics.MeterProvider, // non-owning
    scope: api.InstrumentationScope, // non-owning
    is_shutdown: std.atomic.Value(bool),

    // Synchronous instruments
    counters_i64: std.ArrayList(*sdk.metrics.sync_instr.StandardCounter(i64)),
    counters_f64: std.ArrayList(*sdk.metrics.sync_instr.StandardCounter(f64)),
    up_down_counters_i64: std.ArrayList(*sdk.metrics.sync_instr.StandardUpDownCounter(i64)),
    up_down_counters_f64: std.ArrayList(*sdk.metrics.sync_instr.StandardUpDownCounter(f64)),
    gauges_i64: std.ArrayList(*sdk.metrics.sync_instr.StandardGauge(i64)),
    gauges_f64: std.ArrayList(*sdk.metrics.sync_instr.StandardGauge(f64)),
    histograms_i64: std.ArrayList(*sdk.metrics.sync_instr.StandardHistogram(i64)),
    histograms_f64: std.ArrayList(*sdk.metrics.sync_instr.StandardHistogram(f64)),

    // Observable instruments
    observables_i64: std.ArrayList(*sdk.metrics.async_instr.Observable(i64)),
    observables_f64: std.ArrayList(*sdk.metrics.async_instr.Observable(f64)),

    // Configuration for async instruments
    async_config: sdk.metrics.async_instr.AsyncInstrumentConfig,

    pub fn init(
        provider: *sdk.metrics.MeterProvider,
        scope: api.InstrumentationScope,
    ) !Meter {
        return .{
            .scope = scope,
            .provider = provider,
            .is_shutdown = .init(false),
            .counters_i64 = .empty,
            .counters_f64 = .empty,
            .up_down_counters_i64 = .empty,
            .up_down_counters_f64 = .empty,
            .gauges_i64 = .empty,
            .gauges_f64 = .empty,
            .histograms_i64 = .empty,
            .histograms_f64 = .empty,
            .observables_i64 = .empty,
            .observables_f64 = .empty,
            .async_config = .default,
        };
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
            self.observables_i64,
            self.observables_f64,
        };
        inline for (instruments) |list| {
            for (list.items) |instrument| {
                instrument.deinit(self.provider.allocator);
                self.provider.allocator.destroy(instrument);
            }
            // The captured var is const, which blocks calling
            // deinit. But ArrayLists are just pointers to memory
            // so I can get away with calling deinit on a mutable
            // copy.
            var mutable_list = list;
            mutable_list.deinit(self.provider.allocator);
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

        const counter = try self.provider.allocator.create(sdk.metrics.sync_instr.StandardCounter(i64));
        errdefer self.provider.allocator.destroy(counter);

        counter.* = try sdk.metrics.sync_instr.StandardCounter(i64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit(self.provider.allocator);

        try self.counters_i64.append(self.provider.allocator, counter);

        return api.metrics.Counter(i64){
            .bridge = .init(counter),
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

        const counter = try self.provider.allocator.create(sdk.metrics.sync_instr.StandardCounter(f64));
        errdefer self.provider.allocator.destroy(counter);

        counter.* = try sdk.metrics.sync_instr.StandardCounter(f64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit(self.provider.allocator);

        try self.counters_f64.append(self.provider.allocator, counter);

        return api.metrics.Counter(f64){
            .bridge = .init(counter),
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

        const counter = try self.provider.allocator.create(sdk.metrics.sync_instr.StandardUpDownCounter(i64));
        errdefer self.provider.allocator.destroy(counter);

        counter.* = try sdk.metrics.sync_instr.StandardUpDownCounter(i64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit(self.provider.allocator);

        try self.up_down_counters_i64.append(self.provider.allocator, counter);

        return api.metrics.UpDownCounter(i64){
            .bridge = .init(counter),
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

        const counter = try self.provider.allocator.create(sdk.metrics.sync_instr.StandardUpDownCounter(f64));
        errdefer self.provider.allocator.destroy(counter);

        counter.* = try sdk.metrics.sync_instr.StandardUpDownCounter(f64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit(self.provider.allocator);

        try self.up_down_counters_f64.append(self.provider.allocator, counter);

        return api.metrics.UpDownCounter(f64){
            .bridge = .init(counter),
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

        const counter = try self.provider.allocator.create(sdk.metrics.sync_instr.StandardGauge(i64));
        errdefer self.provider.allocator.destroy(counter);

        counter.* = try sdk.metrics.sync_instr.StandardGauge(i64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit(self.provider.allocator);

        try self.gauges_i64.append(self.provider.allocator, counter);

        return api.metrics.Gauge(i64){
            .bridge = .init(counter),
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

        const counter = try self.provider.allocator.create(sdk.metrics.sync_instr.StandardGauge(f64));
        errdefer self.provider.allocator.destroy(counter);

        counter.* = try sdk.metrics.sync_instr.StandardGauge(f64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer counter.deinit(self.provider.allocator);

        try self.gauges_f64.append(self.provider.allocator, counter);

        return api.metrics.Gauge(f64){
            .bridge = .init(counter),
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

        const histogram = try self.provider.allocator.create(sdk.metrics.sync_instr.StandardHistogram(i64));
        errdefer self.provider.allocator.destroy(histogram);

        histogram.* = try sdk.metrics.sync_instr.StandardHistogram(i64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer histogram.deinit(self.provider.allocator);

        try self.histograms_i64.append(self.provider.allocator, histogram);

        return api.metrics.Histogram(i64){
            .bridge = .init(histogram),
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

        const histogram = try self.provider.allocator.create(sdk.metrics.sync_instr.StandardHistogram(f64));
        errdefer self.provider.allocator.destroy(histogram);

        histogram.* = try sdk.metrics.sync_instr.StandardHistogram(f64).init(
            validated_name,
            validated_description,
            validated_unit,
            self,
        );
        errdefer histogram.deinit(self.provider.allocator);

        try self.histograms_f64.append(self.provider.allocator, histogram);

        return api.metrics.Histogram(f64){
            .bridge = .init(histogram),
        };
    }

    // Observable instrument creation methods

    pub fn createObservableCounterI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback(i64),
    ) !api.metrics.ObservableInstrument(i64) {
        return self.internalCreateObservable(
            i64,
            name,
            description,
            unit,
            .ObservableCounter,
            advisory,
            callbacks,
        );
    }

    pub fn createObservableCounterF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback(f64),
    ) !api.metrics.ObservableInstrument(f64) {
        return self.internalCreateObservable(
            f64,
            name,
            description,
            unit,
            .ObservableCounter,
            advisory,
            callbacks,
        );
    }

    pub fn createObservableGaugeI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback(i64),
    ) !api.metrics.ObservableInstrument(i64) {
        return self.internalCreateObservable(
            i64,
            name,
            description,
            unit,
            .ObservableGauge,
            advisory,
            callbacks,
        );
    }

    pub fn createObservableGaugeF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback(f64),
    ) !api.metrics.ObservableInstrument(f64) {
        return self.internalCreateObservable(
            f64,
            name,
            description,
            unit,
            .ObservableGauge,
            advisory,
            callbacks,
        );
    }

    pub fn createObservableUpDownCounterI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback(i64),
    ) !api.metrics.ObservableInstrument(i64) {
        return self.internalCreateObservable(
            i64,
            name,
            description,
            unit,
            .ObservableUpDownCounter,
            advisory,
            callbacks,
        );
    }

    /// Create an f64 ObservableUpDownCounter.
    pub fn createObservableUpDownCounterF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback(f64),
    ) !api.metrics.ObservableInstrument(f64) {
        return self.internalCreateObservable(
            f64,
            name,
            description,
            unit,
            .ObservableUpDownCounter,
            advisory,
            callbacks,
        );
    }

    fn internalCreateObservable(
        self: *Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        instrument_type: sdk.metrics.InstrumentType,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback(T),
    ) !api.metrics.ObservableInstrument(T) {
        _ = advisory; // Ignore advisory parameters for now

        // short ciruit if the meter is shutdown.
        if (self.is_shutdown.load(.monotonic)) {
            return api.metrics.ObservableInstrument(T){ .noop = name };
        }

        // Validate parameters in debug mode
        const validated_name = api.metrics.validateInstrumentName(name);
        const validated_description = api.metrics.validateInstrumentDescription(description);
        const validated_unit = api.metrics.validateInstrumentUnit(unit);

        // Allocate memory.
        const observable = try self.provider.allocator.create(sdk.metrics.async_instr.Observable(T));
        errdefer self.provider.allocator.destroy(observable);

        // Initialize.
        observable.* = try sdk.metrics.async_instr.Observable(T).init(
            validated_name,
            validated_description,
            validated_unit,
            instrument_type,
            self,
            self.async_config,
        );
        errdefer observable.deinit(self.provider.allocator);

        // Register the creation time callbacks.
        for (callbacks) |cb| {
            _ = observable.registerCallback(cb);
        }

        // store in the right collection
        switch (T) {
            i64 => try self.observables_i64.append(self.provider.allocator, observable),
            f64 => try self.observables_f64.append(self.provider.allocator, observable),
            else => @compileError("ObservableInstrument must be of type i64 or f64"),
        }

        // erase the type.
        return api.metrics.ObservableInstrument(T){
            .bridge = api.metrics.AsyncInstrumentBridge(T).init(observable),
        };
    }

    pub inline fn meter(self: *Meter) api.metrics.Meter {
        return .{ .bridge = .init(self) };
    }

    pub fn triggerObservables(self: *const Meter, allocator: std.mem.Allocator, reader: sdk.metrics.Reader) void {
        // TODO this whole struct is missing a mutex? maybe 2: one for observables and one for sync instruments.

        for (self.observables_i64.items) |observable| observable.triggerObserve(allocator, reader);
        for (self.observables_f64.items) |observable| observable.triggerObserve(allocator, reader);
    }
};
