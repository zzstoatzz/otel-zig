const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const InstrumentationScopeMapContext = @import("../common/scope_context.zig").InstrumentationScopeMapContext;
    const Resource = @import("../resource/resource.zig").Resource;
    const PipelineBuilder = @import("../common/pipeline.zig").PipelineBuilder;
    const Meter = @import("meter.zig").Meter;
    const Reader = @import("reader.zig").Reader;
};

/// Basic meter provider with caching and configuration
pub const MeterProvider = struct {
    // internal state fields
    allocator: std.mem.Allocator,
    resource: sdk.Resource,
    cache: std.HashMapUnmanaged(api.InstrumentationScope, *sdk.Meter, sdk.InstrumentationScopeMapContext, 80),
    readers: std.ArrayListUnmanaged(sdk.Reader),
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

        // Clean up the resource.
        self.resource.deinitOwned(self.allocator);
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

        sdk_meter.* = try sdk.Meter.init(self.allocator, owned_scope, self.resource);

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
