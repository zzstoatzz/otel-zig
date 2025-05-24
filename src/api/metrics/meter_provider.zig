//! OpenTelemetry Meter Provider API
//!
//! This module defines the MeterProvider interface for creating Meter instances.
//! MeterProvider manages the lifecycle of meters and ensures consistent
//! meter instances for the same instrumentation scope.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/api.md#meterprovider

const std = @import("std");

// Forward declarations - these will be defined in other files
pub const Meter = @import("meter.zig").Meter;
const createNoopMeter = @import("meter.zig").createNoopMeter;

// Import from relative paths
const Context = @import("../context/root.zig").Context;
const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const KeyValue = @import("../common/root.zig").KeyValue;
const AttributeValue = @import("../common/root.zig").AttributeValue;

/// MeterProvider interface using tagged union for polymorphism
pub const MeterProvider = union(enum) {
    noop: NoopMeterProvider,
    sdk: SdkProviderBridge,

    /// Get or create a meter with direct parameters (OpenTelemetry API specification compliant)
    pub inline fn getMeter(
        self: *MeterProvider,
        name: []const u8,
        version: ?[]const u8,
        schema_url: ?[]const u8,
        attributes: []const KeyValue,
    ) !*Meter {
        return switch (self.*) {
            .noop => |*provider| provider.getMeter(name, version, schema_url, attributes),
            .sdk => |*bridge| bridge.vtable.getMeter(bridge.provider_ptr, name, version, schema_url, attributes),
        };
    }

    /// Get or create a meter for the given instrumentation scope
    pub inline fn getMeterWithScope(self: *MeterProvider, scope: InstrumentationScope) !*Meter {
        return switch (self.*) {
            .noop => |*provider| provider.getMeterWithScope(scope),
            .sdk => |*bridge| bridge.vtable.getMeterWithScope(bridge.provider_ptr, scope),
        };
    }

    /// Convenience method to get a meter with just a name
    pub inline fn getMeterWithName(self: *MeterProvider, name: []const u8) !*Meter {
        return self.getMeter(name, null, null, &[_]KeyValue{});
    }

    /// Convenience method to get a meter with name and version
    pub inline fn getMeterWithVersion(
        self: *MeterProvider,
        name: []const u8,
        version: []const u8,
    ) !*Meter {
        return self.getMeter(name, version, null, &[_]KeyValue{});
    }

    /// Clean up provider resources
    pub fn deinit(self: *MeterProvider) void {
        switch (self.*) {
            .noop => |*provider| provider.deinit(),
            .sdk => |*bridge| bridge.vtable.deinit(bridge.provider_ptr),
        }
    }
};

/// No-operation meter provider that creates noop meters
pub const NoopMeterProvider = struct {
    allocator: std.mem.Allocator,
    meters: std.ArrayList(*Meter),

    pub fn init(allocator: std.mem.Allocator) NoopMeterProvider {
        return .{
            .allocator = allocator,
            .meters = std.ArrayList(*Meter).init(allocator),
        };
    }

    pub fn deinit(self: *NoopMeterProvider) void {
        for (self.meters.items) |meter| {
            meter.deinit();
            self.allocator.destroy(meter);
        }
        self.meters.deinit();
    }

    pub fn getMeter(
        self: *NoopMeterProvider,
        name: []const u8,
        version: ?[]const u8,
        schema_url: ?[]const u8,
        attributes: []const KeyValue,
    ) !*Meter {
        const scope = try InstrumentationScope.init(name, version, schema_url, attributes);
        return self.getMeterWithScope(scope);
    }

    pub fn getMeterWithScope(self: *NoopMeterProvider, scope: InstrumentationScope) !*Meter {
        const meter = try self.allocator.create(Meter);
        errdefer self.allocator.destroy(meter);

        meter.* = createNoopMeter(self.allocator, scope);
        try self.meters.append(meter);

        return meter;
    }
};

/// Create a no-operation meter provider
pub fn createNoopProvider(allocator: std.mem.Allocator) MeterProvider {
    return .{ .noop = NoopMeterProvider.init(allocator) };
}

/// Virtual table for SDK meter provider implementations
pub const SdkProviderVTable = struct {
    getMeter: *const fn (provider_ptr: *anyopaque, name: []const u8, version: ?[]const u8, schema_url: ?[]const u8, attributes: []const KeyValue) anyerror!*Meter,
    getMeterWithScope: *const fn (provider_ptr: *anyopaque, scope: InstrumentationScope) anyerror!*Meter,
    deinit: *const fn (provider_ptr: *anyopaque) void,
};

/// Bridge structure that holds SDK provider pointer and vtable
pub const SdkProviderBridge = struct {
    provider_ptr: *anyopaque,
    vtable: SdkProviderVTable,
};

test "NoopMeterProvider basic creation and cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test 1: Create provider without getting any meters
    {
        var provider = createNoopProvider(allocator);
        defer provider.deinit();
    }

    // Test 2: Create provider and get one meter
    {
        var provider = createNoopProvider(allocator);
        defer provider.deinit();
        
        const meter = try provider.getMeterWithName("test.meter");
        try testing.expect(meter.* == .noop);
    }
}

test "NoopMeterProvider operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = createNoopProvider(allocator);
    defer provider.deinit();

    // Get meter with different scopes
    const meter1 = try provider.getMeterWithName("test.meter1");
    const meter2 = try provider.getMeterWithName("test.meter2");

    // Both should be noop meters
    try testing.expect(meter1.* == .noop);
    try testing.expect(meter2.* == .noop);
}

test "MeterProvider convenience methods" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = createNoopProvider(allocator);
    defer provider.deinit();

    // Test getMeterWithName
    const meter1 = try provider.getMeterWithName("simple.meter");
    try testing.expect(meter1.* == .noop);
    try testing.expectEqualStrings("simple.meter", meter1.getInstrumentationScope().name);

    // Test getMeterWithVersion
    const meter2 = try provider.getMeterWithVersion("versioned.meter", "1.0.0");
    try testing.expect(meter2.* == .noop);
    try testing.expectEqualStrings("versioned.meter", meter2.getInstrumentationScope().name);
    try testing.expectEqualStrings("1.0.0", meter2.getInstrumentationScope().version.?);
}

test "MeterProvider spec-compliant getMeter API" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = createNoopProvider(allocator);
    defer provider.deinit();

    // Test spec-compliant API with all parameters
    const attributes = [_]KeyValue{
        KeyValue.init("key1", AttributeValue{ .string = "value1" }),
        KeyValue.init("key2", AttributeValue{ .int = 42 }),
    };

    const meter1 = try provider.getMeter("test.service", "1.0.0", "https://schema.example.com", &attributes);
    try testing.expect(meter1.* == .noop);

    const scope1 = meter1.getInstrumentationScope();
    try testing.expectEqualStrings("test.service", scope1.name);
    try testing.expectEqualStrings("1.0.0", scope1.version.?);
    try testing.expectEqualStrings("https://schema.example.com", scope1.schema_url.?);
    try testing.expectEqual(@as(usize, 2), scope1.attributes.len);

    // Test with minimal parameters (only name)
    const meter2 = try provider.getMeter("minimal.service", null, null, &[_]KeyValue{});
    try testing.expect(meter2.* == .noop);

    const scope2 = meter2.getInstrumentationScope();
    try testing.expectEqualStrings("minimal.service", scope2.name);
    try testing.expect(scope2.version == null);
    try testing.expect(scope2.schema_url == null);
    try testing.expectEqual(@as(usize, 0), scope2.attributes.len);
}