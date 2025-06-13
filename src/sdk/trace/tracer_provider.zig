//! OpenTelemetry SDK Standard Tracer Provider Implementation
//!
//! This module provides the concrete implementation of the TracerProvider interface
//! for the SDK. StandardTracerProvider manages tracers and their lifecycle.

const std = @import("std");

const otel_api = @import("otel-api");
const TracerProvider = otel_api.trace.TracerProvider;
const TracerProviderBridge = otel_api.trace.TracerProviderBridge;
const Tracer = otel_api.trace.Tracer;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const ProcessResult = otel_api.common.ProcessResult;
const FlushResult = otel_api.common.FlushResult;
const Sampler = otel_api.trace.Sampler;
const SpanLimits = otel_api.trace.SpanLimits;

const IdGenerator = @import("id_generator.zig").IdGenerator;
const createDefaultIdGenerator = @import("id_generator.zig").createDefaultIdGenerator;
const Resource = @import("../resource/resource.zig").Resource;
const samplers = @import("samplers/root.zig");
const SpanProcessor = @import("processor.zig").SpanProcessor;
const StandardTracer = @import("tracer.zig").StandardTracer;

/// Context for meter cache HashMap
const TracerCacheContext = struct {
    pub fn hash(_: TracerCacheContext, key: InstrumentationScope) u64 {
        return key.hashCode();
    }

    pub fn eql(_: TracerCacheContext, a: InstrumentationScope, b: InstrumentationScope) bool {
        return InstrumentationScope.eql(a, b);
    }
};

/// Standard implementation of the TracerProvider interface
pub const StandardTracerProvider = struct {
    // internal state fields
    allocator: std.mem.Allocator,
    cache: std.HashMapUnmanaged(InstrumentationScope, *StandardTracer, TracerCacheContext, 80),
    mutex: std.Thread.Mutex,
    is_shutdown: bool,

    // technically accessors.
    resource: Resource,
    id_generator: IdGenerator,
    sampler: Sampler,
    default_processor: SpanProcessor,
    span_limits: SpanLimits,

    /// Create a new standard tracer provider
    pub fn init(
        allocator: std.mem.Allocator,
        resource: Resource,
        id_generator: IdGenerator,
        sampler: Sampler,
        processor: SpanProcessor,
        span_limits: ?SpanLimits,
    ) !*StandardTracerProvider {
        const self = try allocator.create(StandardTracerProvider);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .cache = .empty,
            .mutex = .{},
            .is_shutdown = false,
            .resource = resource,
            .id_generator = id_generator,
            .sampler = sampler,
            .default_processor = processor,
            .span_limits = span_limits orelse processor.spanLimits(),
        };
        return self;
    }

    /// Clean up provider resources
    pub fn deinit(self: *StandardTracerProvider) void {
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
            self.resource.deinitOwned(self.allocator);
            self.default_processor.deinit();
        }
        self.allocator.destroy(self);
    }

    // TracerProvider interface implementation
    pub fn getTracerWithScope(self: *StandardTracerProvider, scope: InstrumentationScope) !Tracer {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            // Return noop tracer if shutdown
            return Tracer{ .noop = scope };
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

    pub fn forceFlush(self: *StandardTracerProvider, timeout_ms: ?u64) otel_api.common.FlushResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        return if (self.default_processor.forceFlush(timeout_ms) == .success) .success else .failure;
    }

    /// Create a TracerProvider interface for this standard provider
    pub fn tracerProvider(self: *StandardTracerProvider) TracerProvider {
        return TracerProvider{ .bridge = TracerProviderBridge.init(self) };
    }
};

test "StandardTracerProvider basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = SpanProcessor{ .noop = {} };

    const provider = try StandardTracerProvider.init(
        allocator,
        resource,
        createDefaultIdGenerator(),
        samplers.always_on,
        processor,
        null,
    );
    defer provider.deinit();

    var tp = provider.tracerProvider();

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
    try testing.expectEqual(FlushResult.success, provider.forceFlush(null));
}

// TODO: Fix threading issue - temporarily disabled
// test "StandardTracerProvider thread safety" {
//     const testing = std.testing;
//     const allocator = testing.allocator;

//     const resource = Resource{
//         .attributes = &.{},
//         .schema_url = null,
//     };

//     const processor = SpanProcessor{ .noop = {} };

//     const provider = try StandardTracerProvider.init(
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
