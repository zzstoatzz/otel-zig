const std = @import("std");
const logs_api = @import("otel-api").logs;
const provider_registry = @import("otel-api").provider_registry;
const logs_processor = @import("processor.zig");
const logs_provider = @import("logger_provider.zig");
const Resource = @import("../resource/resource.zig").Resource;
const ResourceBuilder = @import("../resource/resource.zig").ResourceBuilder;
const detectResource = @import("../resource/detector.zig").detectResource;
const LogExporter = @import("exporter.zig").LogExporter;
const LogProcessor = @import("processor.zig").LogProcessor;

pub fn createSimpleSyncLogging(allocator: std.mem.Allocator, service_name: []const u8, exporter: LogExporter) !logs_api.LoggerProvider {
    var rb = ResourceBuilder.init(allocator);
    errdefer rb.deinit();
    const resource = try rb.addResource(Resource.default)
        .addKeyValue(.{ .key = "service.name", .value = .{ .string = service_name } })
        .finish(allocator);
    errdefer resource.deinitOwned(allocator);

    const simple_processor = try logs_processor.SimpleLogProcessor.init(allocator, exporter);
    var processor = simple_processor.logProcessor();
    errdefer processor.deinit();

    const standard_provider = try logs_provider.StandardLoggerProvider.init(allocator, resource, processor);
    var provider = standard_provider.loggerProvider();
    errdefer provider.deinit();

    return provider;
}

/// Templated LoggerProvider builder that uses typestate pattern to track which closures have been set.
/// Each context type parameter is the actual context type, and we use optionals on function fields to track whether they've been set.
fn LoggerProviderBuilder(
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
        exporter_fn: ?*const fn (ExporterCtx, std.mem.Allocator) anyerror!LogExporter,

        processor_context: ProcessorCtx,
        processor_fn: ?*const fn (ProcessorCtx, std.mem.Allocator, LogExporter) anyerror!LogProcessor,

        resource_context: ResourceCtx,
        resource_fn: ?*const fn (ResourceCtx, std.mem.Allocator) anyerror!Resource,

        provider_context: ProviderCtx,
        provider_fn: ?*const fn (ProviderCtx, std.mem.Allocator, Resource, LogProcessor) anyerror!logs_api.LoggerProvider,

        /// Set the exporter closure. Returns a new builder with the exporter context type filled in.
        pub fn withExporterClosure(
            self: Self,
            context: anytype,
            callFn: *const fn (@TypeOf(context), std.mem.Allocator) anyerror!LogExporter,
        ) LoggerProviderBuilder(@TypeOf(context), ProcessorCtx, ResourceCtx, ProviderCtx) {
            return LoggerProviderBuilder(@TypeOf(context), ProcessorCtx, ResourceCtx, ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = context,
                .exporter_fn = callFn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
            };
        }

        /// Set the processor closure. Returns a new builder with the processor context type filled in.
        pub fn withProcessorClosure(
            self: Self,
            context: anytype,
            callFn: *const fn (@TypeOf(context), std.mem.Allocator, LogExporter) anyerror!LogProcessor,
        ) LoggerProviderBuilder(ExporterCtx, @TypeOf(context), ResourceCtx, ProviderCtx) {
            return LoggerProviderBuilder(ExporterCtx, @TypeOf(context), ResourceCtx, ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = context,
                .processor_fn = callFn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
            };
        }

        /// Use the SDK's basic processor. Returns a new builder with a void processor context.
        pub fn withBasicProcessor(self: Self) LoggerProviderBuilder(ExporterCtx, void, ResourceCtx, ProviderCtx) {
            const BasicProcessor = struct {
                fn buildFn(_: void, allocator: std.mem.Allocator, exporter: LogExporter) anyerror!LogProcessor {
                    const processor = try logs_processor.SimpleLogProcessor.init(allocator, exporter);
                    return processor.logProcessor();
                }
            };

            return LoggerProviderBuilder(ExporterCtx, void, ResourceCtx, ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = {},
                .processor_fn = BasicProcessor.buildFn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
            };
        }

        /// Set the resource closure. Returns a new builder with the resource context type filled in.
        pub fn withResourceClosure(
            self: Self,
            context: anytype,
            callFn: *const fn (@TypeOf(context), std.mem.Allocator) anyerror!Resource,
        ) LoggerProviderBuilder(ExporterCtx, ProcessorCtx, @TypeOf(context), ProviderCtx) {
            return LoggerProviderBuilder(ExporterCtx, ProcessorCtx, @TypeOf(context), ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = context,
                .resource_fn = callFn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
            };
        }

        /// Use the SDK detected Resource. Returns a new builder with a void resource context.
        pub fn withDefaultResource(self: Self) LoggerProviderBuilder(ExporterCtx, ProcessorCtx, void, ProviderCtx) {
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

            return LoggerProviderBuilder(ExporterCtx, ProcessorCtx, void, ProviderCtx){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = {},
                .resource_fn = DefaultResourceFn.buildFn,
                .provider_context = self.provider_context,
                .provider_fn = self.provider_fn,
            };
        }

        /// Set the provider closure. Returns a new builder with the provider context type filled in.
        pub fn withProviderClosure(
            self: Self,
            context: anytype,
            callFn: *const fn (@TypeOf(context), std.mem.Allocator, Resource, LogProcessor) anyerror!logs_api.LoggerProvider,
        ) LoggerProviderBuilder(ExporterCtx, ProcessorCtx, ResourceCtx, @TypeOf(context)) {
            return LoggerProviderBuilder(ExporterCtx, ProcessorCtx, ResourceCtx, @TypeOf(context)){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = context,
                .provider_fn = callFn,
            };
        }

        /// Use the SDK's basic provider. Returns a new builder with a void provider context.
        pub fn withBasicProvider(self: Self) LoggerProviderBuilder(ExporterCtx, ProcessorCtx, ResourceCtx, void) {
            const BasicProviderFn = struct {
                fn buildFn(_: void, allocator: std.mem.Allocator, resource: Resource, processor: LogProcessor) anyerror!logs_api.LoggerProvider {
                    const provider = try logs_provider.StandardLoggerProvider.init(allocator, resource, processor);
                    return provider.loggerProvider();
                }
            };

            return LoggerProviderBuilder(ExporterCtx, ProcessorCtx, ResourceCtx, void){
                .allocator = self.allocator,
                .exporter_context = self.exporter_context,
                .exporter_fn = self.exporter_fn,
                .processor_context = self.processor_context,
                .processor_fn = self.processor_fn,
                .resource_context = self.resource_context,
                .resource_fn = self.resource_fn,
                .provider_context = {},
                .provider_fn = BasicProviderFn.buildFn,
            };
        }

        /// Build the LoggerProvider. Only available when all four closures have been set.
        /// This ensures at compile time that all required closures have been set.
        pub fn build(self: Self) !logs_api.LoggerProvider {
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
            const provider = try std.heap.page_allocator.create(logs_api.LoggerProvider);
            errdefer std.heap.page_allocator.destroy(provider);

            provider.* = try self.build();
            errdefer provider.deinit();

            const old_provider = provider_registry.setGlobalLoggerProvider(provider);
            defer {
                if (old_provider) |op| {
                    op.deinit();
                    std.heap.page_allocator.destroy(op);
                }
            }
        }
    };
}

/// Initialize a new LoggerProviderBuilder with all context types set to void and all closures unset.
/// Use the various `with*` methods to configure the builder before calling `build()`.
pub fn buildProvider(allocator: std.mem.Allocator) LoggerProviderBuilder(void, void, void, void) {
    return LoggerProviderBuilder(void, void, void, void){
        .allocator = allocator,
        .exporter_context = {},
        .exporter_fn = null,
        .processor_context = {},
        .processor_fn = null,
        .resource_context = {},
        .resource_fn = null,
        .provider_context = {},
        .provider_fn = null,
    };
}

/// Destroy the global logger provider.
pub fn destroyProvider() void {
    const old_provider = provider_registry.setGlobalLoggerProvider(null);
    if (old_provider) |op| {
        op.deinit();
        std.heap.page_allocator.destroy(op);
    }
}
