const std = @import("std");
const trace_api = @import("otel-api").trace;
const provider_registry = @import("otel-api").provider_registry;
const trace_processor = @import("processor.zig");
const batch_processor = @import("batch_span_processor.zig");
const trace_provider = @import("tracer_provider.zig");
const Resource = @import("../resource/resource.zig").Resource;
const ResourceBuilder = @import("../resource/resource.zig").ResourceBuilder;
const detectResource = @import("../resource/detector.zig").detectResource;
const SpanExporter = @import("exporter.zig").SpanExporter;
const SpanProcessor = @import("processor.zig").SpanProcessor;
const IdGenerator = @import("id_generator.zig").IdGenerator;
const createDefaultIdGenerator = @import("id_generator.zig").createDefaultIdGenerator;
const samplers = @import("samplers/root.zig");

/// Configuration for tracer provider
const TracerProviderConfig = struct {
    sampler: ?trace_api.Sampler = null,
    id_generator: ?IdGenerator = null,
    span_limits: ?trace_api.SpanLimits = null,
};

/// Templated TracerProvider builder that uses typestate pattern to track which closures have been set.
/// Each context type parameter is the actual context type, and we use optionals on function fields to track whether they've been set.
fn TracerProviderBuilder(
    comptime ExporterCtx: type,
    comptime ProcessorCtx: type,
    comptime ResourceCtx: type,
    comptime ProviderCtx: type,
) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,

        // Context fields store actual values, function fields are optional to track if closures are set
        exporter_context: ExporterCtx,
        exporter_fn: ?*const fn (ExporterCtx, std.mem.Allocator) anyerror!SpanExporter,

        processor_context: ProcessorCtx,
        processor_fn: ?*const fn (ProcessorCtx, std.mem.Allocator, SpanExporter) anyerror!SpanProcessor,

        resource_context: ResourceCtx,
        resource_fn: ?*const fn (ResourceCtx, std.mem.Allocator) anyerror!Resource,

        provider_context: ProviderCtx,
        provider_fn: ?*const fn (ProviderCtx, std.mem.Allocator, Resource, SpanProcessor) anyerror!trace_api.TracerProvider,

        // Additional trace-specific configuration
        tracer_config: TracerProviderConfig,

        /// Set the exporter closure. Returns a new builder with the exporter context type filled in.
        pub fn withExporterClosure(
            self: Self,
            context: anytype,
            callFn: *const fn (@TypeOf(context), std.mem.Allocator) anyerror!SpanExporter,
        ) TracerProviderBuilder(@TypeOf(context), ProcessorCtx, ResourceCtx, ProviderCtx) {
            return TracerProviderBuilder(@TypeOf(context), ProcessorCtx, ResourceCtx, ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = context,
                .exporter_fn = callFn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
                .tracer_config = self.tracer_config,
            };
        }

        /// Set the processor closure. Returns a new builder with the processor context type filled in.
        pub fn withProcessorClosure(
            self: Self,
            context: anytype,
            callFn: *const fn (@TypeOf(context), std.mem.Allocator, SpanExporter) anyerror!SpanProcessor,
        ) TracerProviderBuilder(ExporterCtx, @TypeOf(context), ResourceCtx, ProviderCtx) {
            return TracerProviderBuilder(ExporterCtx, @TypeOf(context), ResourceCtx, ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = context,
                .processor_fn = callFn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
                .tracer_config = self.tracer_config,
            };
        }

        /// Use the SDK's basic processor. Returns a new builder with a void processor context.
        pub fn withBasicProcessor(self: Self) TracerProviderBuilder(ExporterCtx, void, ResourceCtx, ProviderCtx) {
            const BasicProcessor = struct {
                fn buildFn(_: void, allocator: std.mem.Allocator, exporter: SpanExporter) anyerror!SpanProcessor {
                    const resource = Resource{
                        .attributes = &.{},
                        .schema_url = null,
                    };
                    const processor = try trace_processor.SimpleSpanProcessor.init(allocator, exporter, resource);
                    return processor.spanProcessor();
                }
            };

            return TracerProviderBuilder(ExporterCtx, void, ResourceCtx, ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = {},
                .processor_fn = BasicProcessor.buildFn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
                .tracer_config = self.tracer_config,
            };
        }

        /// Batch processor configuration
        const BatchProcessorConfig = struct {
            export_interval_ms: ?u32 = null,
            max_queue_size: ?usize = null,
        };

        /// Use the SDK's batch processor. Returns a new builder with a BatchProcessorConfig context.
        pub fn withBatchProcessor(
            self: Self,
            export_interval_ms: ?u32,
            max_queue_size: ?usize,
        ) TracerProviderBuilder(ExporterCtx, BatchProcessorConfig, ResourceCtx, ProviderCtx) {
            const BatchProcessor = struct {
                fn buildFn(config: BatchProcessorConfig, allocator: std.mem.Allocator, exporter: SpanExporter) anyerror!SpanProcessor {
                    const resource = Resource{
                        .attributes = &.{},
                        .schema_url = null,
                    };
                    const processor = try batch_processor.BatchSpanProcessor.init(
                        allocator,
                        exporter,
                        resource,
                        config.export_interval_ms,
                        config.max_queue_size,
                    );
                    try processor.start();
                    return SpanProcessor{ .bridge = trace_processor.BridgeSpanProcessor.init(processor) };
                }
            };

            return TracerProviderBuilder(ExporterCtx, BatchProcessorConfig, ResourceCtx, ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = BatchProcessorConfig{
                    .export_interval_ms = export_interval_ms,
                    .max_queue_size = max_queue_size,
                },
                .processor_fn = BatchProcessor.buildFn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
                .tracer_config = self.tracer_config,
            };
        }

        /// Set the resource closure. Returns a new builder with the resource context type filled in.
        pub fn withResourceClosure(
            self: Self,
            context: anytype,
            callFn: *const fn (@TypeOf(context), std.mem.Allocator) anyerror!Resource,
        ) TracerProviderBuilder(ExporterCtx, ProcessorCtx, @TypeOf(context), ProviderCtx) {
            return TracerProviderBuilder(ExporterCtx, ProcessorCtx, @TypeOf(context), ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = context,
                .resource_fn = callFn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
                .tracer_config = self.tracer_config,
            };
        }

        /// Use the SDK detected Resource. Returns a new builder with a void resource context.
        pub fn withDefaultResource(self: Self) TracerProviderBuilder(ExporterCtx, ProcessorCtx, void, ProviderCtx) {
            const DefaultResourceFn = struct {
                fn buildFn(_: void, allocator: std.mem.Allocator) anyerror!Resource {
                    // Run the default host detection logic.
                    const detected = try detectResource(allocator);
                    defer detected.deinitOwned(allocator);

                    return try ResourceBuilder.init(allocator)
                        .withDefaults()
                        .addResource(detected)
                        .finish(allocator);
                }
            };

            return TracerProviderBuilder(ExporterCtx, ProcessorCtx, void, ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = {},
                .resource_fn = DefaultResourceFn.buildFn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
                .tracer_config = self.tracer_config,
            };
        }

        /// Use a pre-built Resource. Returns a new builder with a Resource context.
        pub fn withResource(self: Self, resource: Resource) TracerProviderBuilder(ExporterCtx, ProcessorCtx, Resource, ProviderCtx) {
            const ResourceFn = struct {
                fn buildFn(res: Resource, allocator: std.mem.Allocator) anyerror!Resource {
                    _ = allocator; // Resource is already built, just return it
                    return res;
                }
            };

            return TracerProviderBuilder(ExporterCtx, ProcessorCtx, Resource, ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = resource,
                .resource_fn = ResourceFn.buildFn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
                .tracer_config = self.tracer_config,
            };
        }

        /// Set the provider closure. Returns a new builder with the provider context type filled in.
        pub fn withProviderClosure(
            self: Self,
            context: anytype,
            callFn: *const fn (@TypeOf(context), std.mem.Allocator, Resource, SpanProcessor) anyerror!trace_api.TracerProvider,
        ) TracerProviderBuilder(ExporterCtx, ProcessorCtx, ResourceCtx, @TypeOf(context)) {
            return TracerProviderBuilder(ExporterCtx, ProcessorCtx, ResourceCtx, @TypeOf(context)){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = context,
                .provider_fn = callFn,
                .tracer_config = self.tracer_config,
            };
        }

        /// Use the SDK's basic provider. Returns a new builder with a void provider context.
        pub fn withBasicProvider(self: Self) TracerProviderBuilder(ExporterCtx, ProcessorCtx, ResourceCtx, void) {
            const BasicProviderFn = struct {
                fn buildFn(_: void, allocator: std.mem.Allocator, resource: Resource, processor: SpanProcessor) anyerror!trace_api.TracerProvider {
                    const provider = try trace_provider.StandardTracerProvider.init(
                        allocator,
                        resource,
                        createDefaultIdGenerator(),
                        samplers.always_on,
                        processor,
                        trace_api.SpanLimits.default,
                    );
                    return provider.tracerProvider();
                }
            };

            return TracerProviderBuilder(ExporterCtx, ProcessorCtx, ResourceCtx, void){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = {},
                .provider_fn = BasicProviderFn.buildFn,
                .tracer_config = self.tracer_config,
            };
        }

        /// Use the SDK's configurable provider. Returns a new builder with a TracerProviderConfig context.
        pub fn withConfigurableProvider(
            self: Self,
            sampler: ?trace_api.Sampler,
            id_generator: ?IdGenerator,
            span_limits: ?trace_api.SpanLimits,
        ) TracerProviderBuilder(ExporterCtx, ProcessorCtx, ResourceCtx, TracerProviderConfig) {
            const ConfigurableProviderFn = struct {
                fn buildFn(config: TracerProviderConfig, allocator: std.mem.Allocator, resource: Resource, processor: SpanProcessor) anyerror!trace_api.TracerProvider {
                    const provider = try trace_provider.StandardTracerProvider.init(
                        allocator,
                        resource,
                        config.id_generator orelse createDefaultIdGenerator(),
                        config.sampler orelse samplers.always_on,
                        processor,
                        config.span_limits orelse trace_api.SpanLimits.default,
                    );
                    return provider.tracerProvider();
                }
            };

            return TracerProviderBuilder(ExporterCtx, ProcessorCtx, ResourceCtx, TracerProviderConfig){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = TracerProviderConfig{
                    .sampler = sampler,
                    .id_generator = id_generator,
                    .span_limits = span_limits,
                },
                .provider_fn = ConfigurableProviderFn.buildFn,
                .tracer_config = self.tracer_config,
            };
        }

        /// Set the sampler for the tracer provider
        pub fn withSampler(self: Self, sampler: trace_api.Sampler) Self {
            var new_self = self;
            new_self.tracer_config.sampler = sampler;
            return new_self;
        }

        /// Set the ID generator for the tracer provider
        pub fn withIdGenerator(self: Self, id_generator: IdGenerator) Self {
            var new_self = self;
            new_self.tracer_config.id_generator = id_generator;
            return new_self;
        }

        /// Set the span limits for the tracer provider
        pub fn withSpanLimits(self: Self, span_limits: trace_api.SpanLimits) Self {
            var new_self = self;
            new_self.tracer_config.span_limits = span_limits;
            return new_self;
        }

        /// Build the TracerProvider. Only available when all four closures have been set.
        /// This ensures at compile time that all required closures have been set.
        pub fn build(self: Self) !trace_api.TracerProvider {
            if (self.exporter_fn == null) return error.MissingExporterClosure;
            if (self.processor_fn == null) return error.MissingProcessorClosure;
            if (self.resource_fn == null) return error.MissingResourceClosure;
            if (self.provider_fn == null) return error.MissingProviderClosure;

            // All functions are guaranteed to be non-null at this point
            const exporter = try self.exporter_fn.?(self.exporter_context, self.allocator);
            errdefer exporter.deinit();

            const processor = try self.processor_fn.?(self.processor_context, self.allocator, exporter);
            errdefer processor.deinit();

            const resource = try self.resource_fn.?(self.resource_context, self.allocator);
            errdefer resource.deinitOwned(self.allocator);

            return try self.provider_fn.?(self.provider_context, self.allocator, resource, processor);
        }

        /// Build the provider and set it on the global provider registry.
        /// Only available when all four closures have been set.
        pub fn finish(self: Self) !void {
            const provider = try std.heap.page_allocator.create(trace_api.TracerProvider);
            errdefer std.heap.page_allocator.destroy(provider);

            provider.* = try self.build();
            errdefer provider.deinit();

            const old_provider = provider_registry.setGlobalTracerProvider(provider);
            defer {
                if (old_provider) |op| {
                    op.deinit();
                    std.heap.page_allocator.destroy(op);
                }
            }
        }
    };
}

/// Initialize a new TracerProviderBuilder with all context types set to void and all closures unset.
/// Use the various `with*` methods to configure the builder before calling `build()`.
pub fn buildProvider(allocator: std.mem.Allocator) TracerProviderBuilder(void, void, void, void) {
    return TracerProviderBuilder(void, void, void, void){
        .allocator = allocator,
        .exporter_context = {},
        .exporter_fn = null,
        .processor_context = {},
        .processor_fn = null,
        .resource_context = {},
        .resource_fn = null,
        .provider_context = {},
        .provider_fn = null,
        .tracer_config = .{},
    };
}

/// Destroy the global tracer provider.
pub fn destroyProvider() void {
    const old_provider = provider_registry.setGlobalTracerProvider(null);
    if (old_provider) |op| {
        op.deinit();
        std.heap.page_allocator.destroy(op);
    }
}
