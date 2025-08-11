const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const InstrumentationScopeMapContext = @import("../common/scope_context.zig").InstrumentationScopeMapContext;
    const Resource = @import("../resource/resource.zig").Resource;
    const PipelineBuilder = @import("../common/pipeline.zig").PipelineBuilder;
    const Meter = @import("meter.zig").Meter;
    const Reader = @import("reader.zig").Reader;
    const View = @import("view.zig").View;
    const ViewApplication = @import("view.zig").ViewApplication;
    const AggregationType = @import("view.zig").AggregationType;
    const InstrumentType = @import("metadata.zig").InstrumentType;
};

/// Basic meter provider with caching and configuration
pub const MeterProvider = struct {
    // internal state fields
    allocator: std.mem.Allocator,
    resource: sdk.Resource,
    cache: std.HashMapUnmanaged(api.InstrumentationScope, *sdk.Meter, sdk.InstrumentationScopeMapContext, 80),
    readers: std.ArrayListUnmanaged(sdk.Reader),
    views: std.ArrayListUnmanaged(sdk.View),
    mutex: std.Thread.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        resource: sdk.Resource,
    ) MeterProvider {
        return .{
            .allocator = allocator,
            .resource = resource,
            .cache = .empty,
            .readers = .empty,
            .views = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *MeterProvider) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Iterate over the meters.
        var iter = self.cache.iterator();
        while (iter.next()) |kv| {
            // Unregister the meter from the processors
            for (self.readers.items) |*reader| reader.unregisterMeter(kv.value_ptr.*);

            // Clean up the meter.
            kv.key_ptr.deinitOwned(self.allocator);
            kv.value_ptr.*.deinit();
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.cache.deinit(self.allocator);

        // Iterate over the processors.
        for (self.readers.items) |reader| {
            // Clean up the processor.
            reader.deinit();
            reader.destroy();
        }
        self.readers.deinit(self.allocator);

        // Clean up views
        self.views.deinit(self.allocator);

        // Clean up the resource.
        self.resource.deinitOwned(self.allocator);
    }

    /// Add a view to this provider
    /// Views are immutable after setupGlobalProvider is called
    pub fn addView(self: *MeterProvider, view: sdk.View) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.views.append(self.allocator, view);
    }

    /// Apply all registered views to an instrument, returning view applications
    /// If no views match, returns a single default view application
    pub fn applyViews(
        self: *MeterProvider,
        instrument_name: []const u8,
        instrument_type: sdk.InstrumentType,
        instrument_unit: []const u8,
        instrument_description: ?[]const u8,
        meter_name: []const u8,
        meter_version: ?[]const u8,
        meter_schema_url: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]sdk.ViewApplication {
        _ = instrument_description; // TODO: Use in view validation
        self.mutex.lock();
        defer self.mutex.unlock();

        var applications = std.ArrayList(sdk.ViewApplication).init(allocator);
        defer applications.deinit();

        for (self.views.items) |view| {
            if (view.instrument_selector.matches(
                instrument_name,
                instrument_type,
                instrument_unit,
                meter_name,
                meter_version,
                meter_schema_url,
            )) {
                // Validate aggregation compatibility
                if (view.aggregation_override) |override_type| {
                    if (!isAggregationCompatible(instrument_type, override_type)) {
                        api.common.reportValidationError(.meter, "applyViews", "Incompatible aggregation type for instrument", null);
                        continue; // Skip this view
                    }
                }

                const app = sdk.ViewApplication{
                    .view = view,
                };
                try applications.append(app);
            }
        }

        // If no views matched, add default view
        if (applications.items.len == 0) {
            try applications.append(.{ .view = sdk.View.default });
        }

        return try applications.toOwnedSlice();
    }

    /// Check if an aggregation type is compatible with an instrument type
    fn isAggregationCompatible(instrument_type: sdk.InstrumentType, aggregation_type: sdk.AggregationType) bool {
        return switch (instrument_type) {
            .Counter, .UpDownCounter, .ObservableCounter, .ObservableUpDownCounter => switch (aggregation_type) {
                .sum, .drop => true,
                else => false,
            },
            .Gauge, .ObservableGauge => switch (aggregation_type) {
                .last_value, .drop => true,
                else => false,
            },
            .Histogram => switch (aggregation_type) {
                .histogram, .sum, .drop => true, // Histograms can be aggregated as sums
                else => false,
            },
        };
    }

    /// Destroys the provider instance (assumes deinit() was already called)
    pub fn destroy(self: *MeterProvider) void {
        self.allocator.destroy(self);
    }

    /// Interface defined method to get a meter.
    ///
    /// The provided scope is copied internally.
    pub fn getMeterWithScope(self: *MeterProvider, scope: api.InstrumentationScope) !api.metrics.Meter {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check cache first
        if (self.cache.get(scope)) |meter| {
            return meter.meter();
        }

        // Create a locally owned Scope.
        const owned_scope = try api.InstrumentationScope.initOwned(self.allocator, scope);
        errdefer owned_scope.deinitOwned(self.allocator);

        // Create new SDK meter
        const sdk_meter = try self.allocator.create(sdk.Meter);
        errdefer self.allocator.destroy(sdk_meter);

        sdk_meter.* = try sdk.Meter.init(self.allocator, owned_scope, self.resource, self);

        // Register the meter with the processor for collection
        //
        // Iterating over processors should be thread safe as they can
        // only be mutated at start-up / single threaded.
        for (self.readers.items) |*reader| reader.registerMeter(sdk_meter);

        try self.cache.put(self.allocator, owned_scope, sdk_meter);

        return sdk_meter.meter();
    }

    /// Interface defined method to force the attached processor to flush.
    pub fn forceFlush(self: *MeterProvider, timeout_ms: ?u64) api.common.FlushResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.readers.items) |*reader| {
            reader.collect();
            const flush_result = reader.forceFlush(timeout_ms);
            switch (flush_result) {
                .success => {},
                .failure => return .failure,
                .timeout => return .timeout,
            }
        }
        return .success;
    }

    pub fn shutdown(self: *MeterProvider, timeout_ms: ?u64) api.common.ProcessResult {
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
        const flush_result = self.forceFlush(timeout_ms);
        return switch (flush_result) {
            .success => .success,
            .failure => .failure,
            .timeout => .timeout,
        };
    }

    /// Attach a processor to this provider.
    ///
    /// This method is not thread-safe and should only be called during initialization.
    pub fn registerProcessor(self: *MeterProvider, processor: sdk.Reader) !void {
        try self.readers.append(self.allocator, processor);
    }

    /// Convert the provider into an API interface.
    pub fn meterProvider(self: *MeterProvider) api.metrics.MeterProvider {
        return api.metrics.MeterProvider{ .bridge = api.metrics.MeterProviderBridge.init(self) };
    }

    /// Generate a pipelinebuilder for this provider.
    pub fn pipelineBuilder(self: *MeterProvider) sdk.PipelineBuilder(*MeterProvider) {
        return .init(self);
    }
};
