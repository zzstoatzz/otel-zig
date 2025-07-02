//! OpenTelemetry SDK Basic Tracer Provider Implementation
//!
//! This module provides the concrete implementation of the TracerProvider interface
//! for the SDK. BasicTracerProvider manages tracers and their lifecycle.

const std = @import("std");

const otel_api = @import("otel-api");
const ProcessResult = otel_api.common.ProcessResult;
const TracerProvider = otel_api.trace.TracerProvider;
const TracerProviderBridge = otel_api.trace.TracerProviderBridge;
const Tracer = otel_api.trace.Tracer;
const InstrumentationScope = otel_api.common.InstrumentationScope;

const FlushResult = otel_api.common.FlushResult;
const Sampler = otel_api.trace.Sampler;
const SpanLimits = otel_api.trace.SpanLimits;

// Import validation functions from API layer
const validateAttributeKey = otel_api.trace.validateAttributeKey;
const validateSpanName = otel_api.trace.validateSpanName;
const validateAttributeValue = otel_api.trace.validateAttributeValue;
const validateAttributes = otel_api.trace.validateAttributes;
const reportValidationError = otel_api.common.reportValidationError;

const IdGenerator = @import("id_generator.zig").IdGenerator;
const createDefaultIdGenerator = @import("id_generator.zig").createDefaultIdGenerator;
const Resource = @import("../resource/resource.zig").Resource;
const samplers = @import("samplers/root.zig");
const SpanProcessor = @import("processor.zig").SpanProcessor;
const StandardTracer = @import("tracer.zig").StandardTracer;

const PipelineBuilder = @import("../common/pipeline.zig").PipelineBuilder;

/// Context for meter cache HashMap
const TracerCacheContext = struct {
    pub fn hash(_: TracerCacheContext, key: InstrumentationScope) u64 {
        return key.hashCode();
    }

    pub fn eql(_: TracerCacheContext, a: InstrumentationScope, b: InstrumentationScope) bool {
        return InstrumentationScope.eql(a, b);
    }
};

/// Basic implementation of the TracerProvider interface
pub const BasicTracerProvider = struct {
    // internal state fields
    allocator: std.mem.Allocator,
    cache: std.HashMapUnmanaged(InstrumentationScope, *StandardTracer, TracerCacheContext, 80),
    processors: std.ArrayListUnmanaged(SpanProcessor),
    mutex: std.Thread.Mutex,
    is_shutdown: bool,

    // technically accessors.
    resource: Resource,
    id_generator: IdGenerator,
    sampler: Sampler,
    span_limits: SpanLimits,

    /// Create a new basic tracer provider
    pub fn init(
        allocator: std.mem.Allocator,
        resource: Resource,
        id_generator: IdGenerator,
        sampler: Sampler,
        span_limits: ?SpanLimits,
    ) BasicTracerProvider {
        return .{
            .allocator = allocator,
            .cache = .empty,
            .processors = .empty,
            .mutex = .{},
            .is_shutdown = false,
            .resource = resource,
            .id_generator = id_generator,
            .sampler = sampler,
            .span_limits = span_limits orelse SpanLimits.default,
        };
    }

    /// Clean up provider resources
    pub fn deinit(self: *BasicTracerProvider) void {
        // Given that we iterate over the cache, using the mutex here
        // Also, deinit shouldn't be that frequent.
        //
        // The mutex block is distinct because the mutex must be released before
        // self can be destroyed.
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Clean up tracers
            var iter = self.cache.iterator();
            while (iter.next()) |kv| {
                kv.key_ptr.deinitOwned(self.allocator);
                kv.value_ptr.*.deinit();
                self.allocator.destroy(kv.value_ptr.*);
            }
            self.cache.deinit(self.allocator);

            // Clean up processors
            for (self.processors.items) |processor| {
                processor.deinit();
                processor.destroy();
            }
            self.processors.deinit(self.allocator);

            self.resource.deinitOwned(self.allocator);
        }
    }

    pub fn destroy(self: *BasicTracerProvider) void {
        self.allocator.destroy(self);
    }

    /// Register a processor with this provider.
    ///
    /// This method is not thread-safe and should only be called during initialization.
    pub fn registerProcessor(self: *BasicTracerProvider, processor: SpanProcessor) !void {
        try self.processors.append(self.allocator, processor);
    }

    /// Generate a pipelinebuilder for this provider.
    pub fn pipelineBuilder(self: *BasicTracerProvider) PipelineBuilder(*BasicTracerProvider) {
        return .init(self);
    }

    // TracerProvider interface implementation
    pub fn getTracerWithScope(self: *BasicTracerProvider, scope: InstrumentationScope) !Tracer {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            // Return noop tracer if shutdown
            return Tracer{ .noop = {} };
        }

        // Check if tracer already exists
        if (self.cache.get(scope)) |tracer| {
            return tracer.tracer();
        }

        // Create a locally owned Scope for usage in the cache.
        const owned_scope = try InstrumentationScope.initOwned(self.allocator, scope);
        errdefer owned_scope.deinitOwned(self.allocator);

        // Create new tracer
        const new_tracer = try self.allocator.create(StandardTracer);
        errdefer self.allocator.destroy(new_tracer);

        new_tracer.* = StandardTracer.init(
            self.allocator,
            owned_scope,
            self,
        );

        // Cache the tracer
        try self.cache.put(self.allocator, owned_scope, new_tracer);

        return new_tracer.tracer();
    }

    pub fn forceFlush(self: *BasicTracerProvider, timeout_ms: ?u64) otel_api.common.FlushResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        for (self.processors.items) |*processor| {
            const flush_result = processor.forceFlush(timeout_ms);
            switch (flush_result) {
                .success => {},
                .failure => return .failure,
                .timeout => return .failure,
            }
        }
        return .success;
    }

    /// Shutdown the provider with optional timeout
    pub fn shutdown(self: *BasicTracerProvider, timeout_ms: ?u64) ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success; // Already shutdown
        }

        // Shutdown all processors
        for (self.processors.items) |*processor| {
            const shutdown_result = processor.shutdown(timeout_ms);
            switch (shutdown_result) {
                .success => {},
                .failure => return .failure,
                .timeout => return .timeout,
            }
        }

        // Mark as shutdown
        self.is_shutdown = true;
        return .success;
    }

    /// Create a TracerProvider interface for this basic provider
    pub fn tracerProvider(self: *BasicTracerProvider) TracerProvider {
        return TracerProvider{ .bridge = TracerProviderBridge.init(self) };
    }
};

test "BasicTracerProvider basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = SpanProcessor{ .noop = {} };

    const provider_ptr = try allocator.create(BasicTracerProvider);
    provider_ptr.* = BasicTracerProvider.init(
        allocator,
        resource,
        createDefaultIdGenerator(),
        samplers.always_on,
        null,
    );
    try provider_ptr.registerProcessor(processor);
    defer {
        provider_ptr.deinit();
        provider_ptr.destroy();
    }

    var tp = provider_ptr.tracerProvider();

    // Get a tracer
    const tracer1 = try tp.getTracerWithScope(.{
        .name = "test-tracer",
        .version = null,
        .schema_url = null,
        .attributes = &.{},
    });
    _ = tracer1;

    // Get the same tracer again (should be cached)
    const tracer2 = try tp.getTracerWithScope(.{
        .name = "test-tracer",
        .version = null,
        .schema_url = null,
        .attributes = &.{},
    });
    _ = tracer2;

    // Force flush
    try testing.expectEqual(FlushResult.success, provider_ptr.forceFlush(null));
}

// TODO: Fix threading issue - temporarily disabled
// test "BasicTracerProvider thread safety" {
//     const testing = std.testing;
//     const allocator = testing.allocator;

//     const resource = Resource{
//         .attributes = &.{},
//         .schema_url = null,
//     };

//     const processor = SpanProcessor{ .noop = {} };

//     const provider = try BasicTracerProvider.init(
//         allocator,
//         resource,
//         processor,
//         samplers.defaultSampler(),
//         null,
//     );
//     defer provider.deinit();

//     var tp = provider.tracerProvider();

//     // Spawn multiple threads to get tracers concurrently
//     const ThreadContext = struct {
//         provider: *TracerProvider,
//         index: usize,

//         fn run(ctx: @This()) void {
//             var buf: [32]u8 = undefined;
//             const name = std.fmt.bufPrint(&buf, "tracer-{}", .{ctx.index}) catch return;
//             _ = ctx.provider.getTracerWithScope(.{
//                 .name = name,
//                 .version = null,
//                 .schema_url = null,
//                 .attributes = &.{},
//             }) catch return;
//         }
//     };

//     var threads: [10]std.Thread = undefined;
//     for (&threads, 0..) |*thread, i| {
//         thread.* = try std.Thread.spawn(.{}, ThreadContext.run, .{
//             ThreadContext{ .provider = &tp, .index = i },
//         });
//     }

//     for (&threads) |*thread| {
//         thread.join();
//     }

//     // Verify all tracers were created
//     provider.mutex.lock();
//     defer provider.mutex.unlock();
//     try testing.expectEqual(@as(usize, 10), provider.tracers.count());
// }
