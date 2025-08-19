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

/// Represents the identifying fields of an instrument per OTel spec.
/// Two instruments are "identical" if all these fields match.
/// Note: description is NOT part of identity per data-model.md spec
pub const InstrumentIdentity = struct {
    /// Instrument name (case-insensitive in comparisons)
    name: []const u8,
    /// Instrument unit (null treated as empty string)
    unit: []const u8,
    /// Instrument type (Counter, Gauge, etc.)
    instrument_type: sdk.metrics.InstrumentType,
};

/// HashMap context for InstrumentIdentity with case-insensitive name comparison
pub const InstrumentIdentityContext = struct {
    pub fn hash(_: @This(), identity: InstrumentIdentity) u64 {
        var hasher = std.hash.Wyhash.init(0);

        // Hash name case-insensitively by converting to lowercase during hash
        for (identity.name) |c| {
            hasher.update(&[_]u8{std.ascii.toLower(c)});
        }

        // Hash unit normally (already normalized to "" if null)
        hasher.update(identity.unit);

        // Hash instrument type
        hasher.update(std.mem.asBytes(&identity.instrument_type));

        return hasher.final();
    }

    pub fn eql(_: @This(), a: InstrumentIdentity, b: InstrumentIdentity) bool {
        // Case-insensitive name comparison
        if (!std.ascii.eqlIgnoreCase(a.name, b.name)) return false;

        // Exact comparison for unit (already normalized)
        if (!std.mem.eql(u8, a.unit, b.unit)) return false;

        // Type must match
        if (a.instrument_type != b.instrument_type) return false;

        return true;
    }
};

/// ArrayHashMap context for InstrumentIdentity (for observables with consistent iteration)
pub const InstrumentIdentityArrayContext = struct {
    pub fn hash(_: @This(), identity: InstrumentIdentity) u32 {
        var hasher = std.hash.Wyhash.init(0);

        // Hash name case-insensitively
        for (identity.name) |c| {
            hasher.update(&[_]u8{std.ascii.toLower(c)});
        }

        // Hash unit
        hasher.update(identity.unit);

        // Hash instrument type
        hasher.update(std.mem.asBytes(&identity.instrument_type));

        return @truncate(hasher.final());
    }

    pub fn eql(_: @This(), a: InstrumentIdentity, b: InstrumentIdentity, _: usize) bool {
        // Case-insensitive name comparison
        if (!std.ascii.eqlIgnoreCase(a.name, b.name)) return false;

        // Exact comparison for unit
        if (!std.mem.eql(u8, a.unit, b.unit)) return false;

        // Type must match
        if (a.instrument_type != b.instrument_type) return false;

        return true;
    }
};

/// Basic meter implementation (formerly StandardMeter)
pub const Meter = struct {
    provider: *sdk.metrics.MeterProvider, // non-owning
    scope: api.InstrumentationScope, // non-owning
    is_shutdown: std.atomic.Value(bool),

    // Synchronous instruments - HashMaps keyed by InstrumentIdentity
    counters_i64: std.HashMapUnmanaged(InstrumentIdentity, *sdk.metrics.sync_instr.StandardCounter(i64), InstrumentIdentityContext, 80),
    counters_f64: std.HashMapUnmanaged(InstrumentIdentity, *sdk.metrics.sync_instr.StandardCounter(f64), InstrumentIdentityContext, 80),
    up_down_counters_i64: std.HashMapUnmanaged(InstrumentIdentity, *sdk.metrics.sync_instr.StandardUpDownCounter(i64), InstrumentIdentityContext, 80),
    up_down_counters_f64: std.HashMapUnmanaged(InstrumentIdentity, *sdk.metrics.sync_instr.StandardUpDownCounter(f64), InstrumentIdentityContext, 80),
    gauges_i64: std.HashMapUnmanaged(InstrumentIdentity, *sdk.metrics.sync_instr.StandardGauge(i64), InstrumentIdentityContext, 80),
    gauges_f64: std.HashMapUnmanaged(InstrumentIdentity, *sdk.metrics.sync_instr.StandardGauge(f64), InstrumentIdentityContext, 80),
    histograms_i64: std.HashMapUnmanaged(InstrumentIdentity, *sdk.metrics.sync_instr.StandardHistogram(i64), InstrumentIdentityContext, 80),
    histograms_f64: std.HashMapUnmanaged(InstrumentIdentity, *sdk.metrics.sync_instr.StandardHistogram(f64), InstrumentIdentityContext, 80),

    // Observable instruments - ArrayHashMaps for consistent iteration order
    observables_i64: std.ArrayHashMapUnmanaged(InstrumentIdentity, *sdk.metrics.async_instr.Observable(i64), InstrumentIdentityArrayContext, false),
    observables_f64: std.ArrayHashMapUnmanaged(InstrumentIdentity, *sdk.metrics.async_instr.Observable(f64), InstrumentIdentityArrayContext, false),

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
        const all_maps = .{
            &self.counters_i64,
            &self.counters_f64,
            &self.up_down_counters_i64,
            &self.up_down_counters_f64,
            &self.gauges_i64,
            &self.gauges_f64,
            &self.histograms_i64,
            &self.histograms_f64,
            &self.observables_i64,
            &self.observables_f64,
        };
        inline for (all_maps) |map_ptr| {
            var iter = map_ptr.iterator();
            while (iter.next()) |entry| {
                // Free duped strings from identity
                self.provider.allocator.free(entry.key_ptr.name);
                self.provider.allocator.free(entry.key_ptr.unit);
                // Clean up instrument
                entry.value_ptr.*.deinit(self.provider.allocator);
                self.provider.allocator.destroy(entry.value_ptr.*);
            }
            map_ptr.deinit(self.provider.allocator);
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
        return self.internalCreateSyncInstrument(
            sdk.metrics.sync_instr.StandardCounter(i64),
            api.metrics.Counter(i64),
            &self.counters_i64,
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .Counter,
            },
            api.metrics.validateInstrumentDescription(description),
            advisory,
        );
    }

    pub fn createCounterF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Counter(f64) {
        return self.internalCreateSyncInstrument(
            sdk.metrics.sync_instr.StandardCounter(f64),
            api.metrics.Counter(f64),
            &self.counters_f64,
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .Counter,
            },
            api.metrics.validateInstrumentDescription(description),
            advisory,
        );
    }

    pub fn createUpDownCounterI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.UpDownCounter(i64) {
        return self.internalCreateSyncInstrument(
            sdk.metrics.sync_instr.StandardUpDownCounter(i64),
            api.metrics.UpDownCounter(i64),
            &self.up_down_counters_i64,
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .UpDownCounter,
            },
            api.metrics.validateInstrumentDescription(description),
            advisory,
        );
    }

    pub fn createUpDownCounterF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.UpDownCounter(f64) {
        return self.internalCreateSyncInstrument(
            sdk.metrics.sync_instr.StandardUpDownCounter(f64),
            api.metrics.UpDownCounter(f64),
            &self.up_down_counters_f64,
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .UpDownCounter,
            },
            api.metrics.validateInstrumentDescription(description),
            advisory,
        );
    }

    pub fn createGaugeI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Gauge(i64) {
        return self.internalCreateSyncInstrument(
            sdk.metrics.sync_instr.StandardGauge(i64),
            api.metrics.Gauge(i64),
            &self.gauges_i64,
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .Gauge,
            },
            api.metrics.validateInstrumentDescription(description),
            advisory,
        );
    }

    pub fn createGaugeF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Gauge(f64) {
        return self.internalCreateSyncInstrument(
            sdk.metrics.sync_instr.StandardGauge(f64),
            api.metrics.Gauge(f64),
            &self.gauges_f64,
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .Gauge,
            },
            api.metrics.validateInstrumentDescription(description),
            advisory,
        );
    }

    pub fn createHistogramI64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Histogram(i64) {
        return self.internalCreateSyncInstrument(
            sdk.metrics.sync_instr.StandardHistogram(i64),
            api.metrics.Histogram(i64),
            &self.histograms_i64,
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .Histogram,
            },
            api.metrics.validateInstrumentDescription(description),
            advisory,
        );
    }

    pub fn createHistogramF64(
        self: *Meter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !api.metrics.Histogram(f64) {
        return self.internalCreateSyncInstrument(
            sdk.metrics.sync_instr.StandardHistogram(f64),
            api.metrics.Histogram(f64),
            &self.histograms_f64,
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .Histogram,
            },
            api.metrics.validateInstrumentDescription(description),
            advisory,
        );
    }

    /// Internal helper to create synchronous instruments with common logic
    fn internalCreateSyncInstrument(
        self: *Meter,
        comptime SdkInstrument: type,
        comptime ApiInstrument: type,
        instrument_map: *std.HashMapUnmanaged(InstrumentIdentity, *SdkInstrument, InstrumentIdentityContext, 80),
        identity: InstrumentIdentity,
        description: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
    ) !ApiInstrument {
        if (self.is_shutdown.load(.acquire)) {
            return ApiInstrument{ .noop = identity.name };
        }

        // Check if identical instrument already exists
        if (instrument_map.get(identity)) |existing_instrument| {
            // Return new bridge wrapper around existing SDK instrument
            return ApiInstrument{ .bridge = .init(existing_instrument) };
        }

        // Create new instrument
        const instrument = try self.provider.allocator.create(SdkInstrument);
        errdefer self.provider.allocator.destroy(instrument);

        instrument.* = try SdkInstrument.init(
            identity.name,
            description,
            identity.unit,
            self,
            advisory,
        );
        errdefer instrument.deinit(self.provider.allocator);

        // Dupe strings for cache ownership
        const owned_identity = InstrumentIdentity{
            .name = try self.provider.allocator.dupe(u8, identity.name),
            .unit = try self.provider.allocator.dupe(u8, identity.unit),
            .instrument_type = identity.instrument_type,
        };
        errdefer {
            self.provider.allocator.free(owned_identity.name);
            self.provider.allocator.free(owned_identity.unit);
        }

        // Store in map using owned identity as key
        try instrument_map.put(self.provider.allocator, owned_identity, instrument);

        return ApiInstrument{ .bridge = .init(instrument) };
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
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .ObservableCounter,
            },
            api.metrics.validateInstrumentDescription(description),
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
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .ObservableCounter,
            },
            api.metrics.validateInstrumentDescription(description),
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
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .ObservableGauge,
            },
            api.metrics.validateInstrumentDescription(description),
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
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .ObservableGauge,
            },
            api.metrics.validateInstrumentDescription(description),
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
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .ObservableUpDownCounter,
            },
            api.metrics.validateInstrumentDescription(description),
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
            .{
                .name = api.metrics.validateInstrumentName(name),
                .unit = api.metrics.validateInstrumentUnit(unit) orelse "",
                .instrument_type = .ObservableUpDownCounter,
            },
            api.metrics.validateInstrumentDescription(description),
            advisory,
            callbacks,
        );
    }

    fn internalCreateObservable(
        self: *Meter,
        comptime T: type,
        identity: InstrumentIdentity,
        description: ?[]const u8,
        advisory: ?api.metrics.AdvisoryParams,
        callbacks: []const api.metrics.TypeErasedCallback(T),
    ) !api.metrics.ObservableInstrument(T) {
        // short circuit if the meter is shutdown.
        if (self.is_shutdown.load(.monotonic)) {
            return api.metrics.ObservableInstrument(T){ .noop = identity.name };
        }

        // Get the appropriate map
        const observable_map = switch (T) {
            i64 => &self.observables_i64,
            f64 => &self.observables_f64,
            else => @compileError("ObservableInstrument must be of type i64 or f64"),
        };

        // Check if identical instrument already exists
        if (observable_map.get(identity)) |existing_observable| {
            // Register the creation time callbacks on existing instrument
            for (callbacks) |cb| {
                _ = existing_observable.registerCallback(cb);
            }

            // Return new bridge wrapper around existing SDK instrument
            return api.metrics.ObservableInstrument(T){
                .bridge = api.metrics.AsyncInstrumentBridge(T).init(existing_observable),
            };
        }

        // Create new observable instrument
        const observable = try self.provider.allocator.create(sdk.metrics.async_instr.Observable(T));
        errdefer self.provider.allocator.destroy(observable);

        // Initialize.
        observable.* = try sdk.metrics.async_instr.Observable(T).init(
            identity.name,
            description,
            identity.unit,
            identity.instrument_type,
            self,
            self.async_config,
            advisory,
        );
        errdefer observable.deinit(self.provider.allocator);

        // Register the creation time callbacks.
        for (callbacks) |cb| {
            _ = observable.registerCallback(cb);
        }

        // Dupe strings for cache ownership
        const owned_identity = InstrumentIdentity{
            .name = try self.provider.allocator.dupe(u8, identity.name),
            .unit = try self.provider.allocator.dupe(u8, identity.unit),
            .instrument_type = identity.instrument_type,
        };
        errdefer {
            self.provider.allocator.free(owned_identity.name);
            self.provider.allocator.free(owned_identity.unit);
        }

        // Store in the appropriate map using owned identity as key
        try observable_map.put(self.provider.allocator, owned_identity, observable);

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

        var iter_i64 = self.observables_i64.iterator();
        while (iter_i64.next()) |entry| {
            entry.value_ptr.*.triggerObserve(allocator, reader);
        }

        var iter_f64 = self.observables_f64.iterator();
        while (iter_f64.next()) |entry| {
            entry.value_ptr.*.triggerObserve(allocator, reader);
        }
    }
};
