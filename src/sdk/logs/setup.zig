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
const otel_api = @import("otel-api");

const DefaultProvider = logs_provider.LoggerProvider;

/// Create a default provider value with automatically detected resources.
/// Returns provider by value - used internally by setupGlobalProvider.
fn createDefaultProviderValue(allocator: std.mem.Allocator) !DefaultProvider {
    // Step 1: Detect resource
    const detected_resource = try detectResource(allocator);
    defer detected_resource.deinitOwned(allocator);

    // Step 2: Merge resources
    const merged_resource = try ResourceBuilder.init(allocator)
        .addResource(detected_resource)
        .withDefaults()
        .finish(allocator);
    errdefer merged_resource.deinitOwned(allocator);

    // Step 3: Create provider
    return DefaultProvider.init(
        allocator,
        merged_resource,
    );
}

/// Setup a global logger provider with pipeline configuration.
/// Creates a heap-allocated provider, configures the pipeline using the provided links,
/// registers it with the global registry, and returns the concrete provider pointer.
/// The caller is responsible for calling deinit() and destroy() on the returned provider.
pub fn setupGlobalProvider(allocator: std.mem.Allocator, links: anytype) !*DefaultProvider {
    // 1. Create heap-allocated concrete provider
    const provider_ptr = try allocator.create(DefaultProvider);
    errdefer allocator.destroy(provider_ptr);

    provider_ptr.* = try createDefaultProviderValue(allocator);
    errdefer provider_ptr.deinit();

    // 2. Configure pipeline using the links tuple
    var builder = provider_ptr.pipelineBuilder();
    inline for (links) |link| {
        builder = builder.with(link);
    }
    try builder.done();

    // 3. Register with global registry (it handles interface wrapper memory management)
    try provider_registry.setGlobalLoggerProvider(provider_ptr.loggerProvider());

    // 4. Return concrete provider pointer for caller management
    return provider_ptr;
}
