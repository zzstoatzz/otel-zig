//! Meter Provider Bridge for SDK/API Integration
//!
//! This module provides the bridge implementation that allows SDK meter providers
//! to be used through the API meter provider interface.

const std = @import("std");
const otel_api = @import("otel-api");

const MeterProvider = otel_api.metrics.MeterProvider;
const Meter = otel_api.metrics.Meter;
const SdkProviderBridge = otel_api.metrics.SdkProviderBridge;
const SdkProviderVTable = otel_api.metrics.SdkProviderVTable;
const InstrumentationScope = otel_api.InstrumentationScope;
const KeyValue = otel_api.KeyValue;

const StandardMeterProvider = @import("../metrics/meter_provider.zig").StandardMeterProvider;

/// Global allocator for bridge operations
var bridge_allocator: ?std.mem.Allocator = null;

/// Set the allocator to be used for bridge operations
pub fn setBridgeAllocator(allocator: std.mem.Allocator) void {
    bridge_allocator = allocator;
}

/// Wrap a StandardMeterProvider for use with the API
pub fn wrapStandardMeterProvider(provider: *StandardMeterProvider) MeterProvider {
    return .{
        .sdk = SdkProviderBridge{
            .provider_ptr = provider,
            .vtable = standardProviderVTable,
        },
    };
}

/// VTable implementation for StandardMeterProvider
const standardProviderVTable = SdkProviderVTable{
    .getMeter = standardProviderGetMeter,
    .getMeterWithScope = standardProviderGetMeterWithScope,
    .deinit = standardProviderDeinit,
};

fn standardProviderGetMeter(
    provider_ptr: *anyopaque,
    name: []const u8,
    version: ?[]const u8,
    schema_url: ?[]const u8,
    attributes: []const KeyValue,
) anyerror!*Meter {
    const provider = @as(*StandardMeterProvider, @ptrCast(@alignCast(provider_ptr)));
    return provider.getMeter(name, version, schema_url, attributes);
}

fn standardProviderGetMeterWithScope(
    provider_ptr: *anyopaque,
    scope: InstrumentationScope,
) anyerror!*Meter {
    const provider = @as(*StandardMeterProvider, @ptrCast(@alignCast(provider_ptr)));
    return provider.getMeterWithScope(scope);
}

fn standardProviderDeinit(provider_ptr: *anyopaque) void {
    const provider = @as(*StandardMeterProvider, @ptrCast(@alignCast(provider_ptr)));
    provider.deinit();
}

// Tests

test "wrapStandardMeterProvider" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Set bridge allocator for tests
    setBridgeAllocator(allocator);

    var sdk_provider = try @import("../metrics/meter_provider.zig").createProvider(allocator);
    defer sdk_provider.deinit();

    var api_provider = wrapStandardMeterProvider(&sdk_provider);
    // Don't deinit api_provider - it's just a wrapper

    // Verify it's an SDK provider
    try testing.expect(api_provider == .sdk);

    // Test getting a meter
    const meter1 = try api_provider.getMeterWithName("test.meter");
    try testing.expect(meter1.* == .sdk);

    const scope = meter1.getInstrumentationScope();
    try testing.expectEqualStrings("test.meter", scope.name);
}

test "wrapped provider meter caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Set bridge allocator for tests
    setBridgeAllocator(allocator);

    var sdk_provider = try @import("../metrics/meter_provider.zig").createProvider(allocator);
    defer sdk_provider.deinit();

    var api_provider = wrapStandardMeterProvider(&sdk_provider);

    // Get same meter multiple times
    const meter1 = try api_provider.getMeterWithName("cached.meter");
    const meter2 = try api_provider.getMeterWithName("cached.meter");
    const meter3 = try api_provider.getMeterWithName("cached.meter");

    // Should return the same instance
    try testing.expectEqual(meter1, meter2);
    try testing.expectEqual(meter2, meter3);

    // Get different meter
    const meter4 = try api_provider.getMeterWithName("different.meter");

    // Should be different instance
    try testing.expect(meter1 != meter4);
}

test "wrapped provider with attributes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Set bridge allocator for tests
    setBridgeAllocator(allocator);

    var sdk_provider = try @import("../metrics/meter_provider.zig").createProvider(allocator);
    defer sdk_provider.deinit();

    var api_provider = wrapStandardMeterProvider(&sdk_provider);

    // Test with attributes
    const attributes = [_]KeyValue{
        KeyValue.init("service.name", .{ .string = "test-service" }),
        KeyValue.init("service.version", .{ .string = "1.0.0" }),
    };

    const meter = try api_provider.getMeter(
        "attributed.meter",
        "2.0.0",
        "https://schema.example.com",
        &attributes,
    );

    const scope = meter.getInstrumentationScope();
    try testing.expectEqualStrings("attributed.meter", scope.name);
    try testing.expectEqualStrings("2.0.0", scope.version.?);
    try testing.expectEqualStrings("https://schema.example.com", scope.schema_url.?);
    try testing.expectEqual(@as(usize, 2), scope.attributes.len);
}