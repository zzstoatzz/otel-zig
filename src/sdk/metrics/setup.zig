const std = @import("std");
const api = @import("otel-api");
const sdk = struct {
    const MeterProvider = @import("meter_provider.zig").MeterProvider;
    const ResourceBuilder = @import("../resource/resource.zig").ResourceBuilder;
    const detectResource = @import("../resource/detector.zig").detectResource;
};

const DefaultProvider = sdk.MeterProvider;

/// Create a default provider value with automatically detected resources.
/// Returns provider by value - used internally by setupGlobalProvider.
fn createDefaultProviderValue(allocator: std.mem.Allocator) !DefaultProvider {
    // Step 1: Detect resource
    const detected_resource = try sdk.detectResource(allocator);
    defer detected_resource.deinitOwned(allocator);

    // Step 2: Merge resources
    const merged_resource = try sdk.ResourceBuilder.init(allocator)
        .addResource(detected_resource)
        .withDefaults()
        .finish(allocator);
    errdefer merged_resource.deinitOwned(allocator);

    // Step 3: Create provider
    return .init(
        allocator,
        merged_resource,
    );
}

/// Setup a global meter provider with pipeline configuration.
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
    try api.provider_registry.setGlobalMeterProvider(provider_ptr.meterProvider());

    // 4. Return concrete provider pointer for caller management
    return provider_ptr;
}
