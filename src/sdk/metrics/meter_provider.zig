//! OpenTelemetry Meter Provider SDK Implementation
//!
//! This module provides the concrete implementation of MeterProvider for the SDK.
//! It manages meter lifecycle, caching, and configuration.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md

const std = @import("std");
const otel_api = @import("otel-api");

const Meter = otel_api.metrics.Meter;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const KeyValue = otel_api.common.KeyValue;
const Context = otel_api.Context;

const StandardMeter = @import("meter.zig").StandardMeter;
const MetricData = @import("processor.zig").MetricData;
const MetricDataPoint = @import("processor.zig").MetricDataPoint;
const MetricType = @import("processor.zig").MetricType;
const MetricValue = @import("processor.zig").MetricValue;
const createStandardMeter = @import("meter.zig").createStandardMeter;
const bridge = @import("../bridge/root.zig");
const Resource = @import("../resource/resource.zig").Resource;
const getDefaultResource = @import("../resource/resource.zig").getDefaultResource;

/// Key for meter cache based on instrumentation scope
const MeterCacheKey = struct {
    name: []const u8,
    version: ?[]const u8,
    schema_url: ?[]const u8,

    fn hash(self: MeterCacheKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(self.name);
        if (self.version) |v| hasher.update(v);
        if (self.schema_url) |url| hasher.update(url);
        return hasher.final();
    }

    fn eql(a: MeterCacheKey, b: MeterCacheKey) bool {
        if (!std.mem.eql(u8, a.name, b.name)) return false;

        if (a.version != null and b.version != null) {
            if (!std.mem.eql(u8, a.version.?, b.version.?)) return false;
        } else if (a.version != null or b.version != null) {
            return false;
        }

        if (a.schema_url != null and b.schema_url != null) {
            if (!std.mem.eql(u8, a.schema_url.?, b.schema_url.?)) return false;
        } else if (a.schema_url != null or b.schema_url != null) {
            return false;
        }

        return true;
    }
};

/// Context for meter cache HashMap
const MeterCacheContext = struct {
    pub fn hash(_: MeterCacheContext, key: MeterCacheKey) u64 {
        return key.hash();
    }

    pub fn eql(_: MeterCacheContext, a: MeterCacheKey, b: MeterCacheKey) bool {
        return MeterCacheKey.eql(a, b);
    }
};

/// MeterProvider union for SDK implementations
pub const MeterProvider = union(enum) {
    standard: StandardMeterProvider,

    /// Get or create a meter with direct parameters
    pub inline fn getMeter(
        self: *MeterProvider,
        name: []const u8,
        version: ?[]const u8,
        schema_url: ?[]const u8,
        attributes: []const KeyValue,
    ) !*Meter {
        return switch (self.*) {
            .standard => |*provider| provider.getMeter(name, version, schema_url, attributes),
        };
    }

    /// Get or create a meter for the given instrumentation scope
    pub inline fn getMeterWithScope(self: *MeterProvider, scope: InstrumentationScope) !*Meter {
        return switch (self.*) {
            .standard => |*provider| provider.getMeterWithScope(scope),
        };
    }

    /// Convenience method to get a meter with just a name
    pub inline fn getMeterWithName(self: *MeterProvider, name: []const u8) !*Meter {
        return self.getMeter(name, null, null, &[_]KeyValue{});
    }

    /// Clean up provider resources
    pub fn deinit(self: *MeterProvider) void {
        switch (self.*) {
            .standard => |*provider| provider.deinit(),
        }
    }
};

/// Standard meter provider with caching and configuration
pub const StandardMeterProvider = struct {
    allocator: std.mem.Allocator,
    resource: Resource,
    cache: std.HashMap(MeterCacheKey, *Meter, MeterCacheContext, 80),
    owned_keys: std.ArrayList(MeterCacheKey),
    meters: std.ArrayList(*Meter),
    sdk_meters: std.ArrayList(*StandardMeter),

    pub fn init(
        allocator: std.mem.Allocator,
        resource: ?Resource,
    ) !StandardMeterProvider {
        // Set bridge allocator for proper integration
        bridge.setBridgeAllocator(allocator);
        
        // Resolve resource: provided -> default -> error
        const resolved_resource = resource orelse try getDefaultResource(allocator);
        
        return .{
            .allocator = allocator,
            .resource = resolved_resource,
            .cache = std.HashMap(MeterCacheKey, *Meter, MeterCacheContext, 80).init(allocator),
            .owned_keys = std.ArrayList(MeterCacheKey).init(allocator),
            .meters = std.ArrayList(*Meter).init(allocator),
            .sdk_meters = std.ArrayList(*StandardMeter).init(allocator),
        };
    }

    pub fn deinit(self: *StandardMeterProvider) void {
        // Clean up all API meters
        for (self.meters.items) |meter| {
            meter.deinit();
            self.allocator.destroy(meter);
        }
        self.meters.deinit();
        
        // Clean up all SDK meters
        for (self.sdk_meters.items) |sdk_meter| {
            sdk_meter.deinit();
            self.allocator.destroy(sdk_meter);
        }
        self.sdk_meters.deinit();
        
        self.cache.deinit();

        // Clean up owned keys
        for (self.owned_keys.items) |key| {
            self.allocator.free(key.name);
            if (key.version) |v| self.allocator.free(v);
            if (key.schema_url) |url| self.allocator.free(url);
        }
        self.owned_keys.deinit();
        
        // Clean up owned resource
        self.resource.deinitOwned(self.allocator);
    }

    pub fn getMeter(
        self: *StandardMeterProvider,
        name: []const u8,
        version: ?[]const u8,
        schema_url: ?[]const u8,
        attributes: []const KeyValue,
    ) !*Meter {
        const scope = try InstrumentationScope.init(name, version, schema_url, attributes);
        return self.getMeterWithScope(scope);
    }

    pub fn getMeterWithScope(self: *StandardMeterProvider, scope: InstrumentationScope) !*Meter {
        const key = MeterCacheKey{
            .name = scope.name,
            .version = scope.version,
            .schema_url = scope.schema_url,
        };

        // Check cache first
        if (self.cache.get(key)) |meter| {
            return meter;
        }

        // Create new SDK meter
        const sdk_meter = try self.allocator.create(StandardMeter);
        errdefer self.allocator.destroy(sdk_meter);
        
        sdk_meter.* = try StandardMeter.init(self.allocator, scope, &self.resource);
        
        // Wrap SDK meter for API use
        const meter = try bridge.wrapStandardMeter(self.allocator, sdk_meter);

        // Create owned key for cache
        const owned_key = MeterCacheKey{
            .name = try self.allocator.dupe(u8, scope.name),
            .version = if (scope.version) |v| try self.allocator.dupe(u8, v) else null,
            .schema_url = if (scope.schema_url) |url| try self.allocator.dupe(u8, url) else null,
        };
        errdefer {
            self.allocator.free(owned_key.name);
            if (owned_key.version) |v| self.allocator.free(v);
            if (owned_key.schema_url) |url| self.allocator.free(url);
        }

        try self.cache.put(owned_key, meter);
        try self.owned_keys.append(owned_key);
        try self.meters.append(meter);
        try self.sdk_meters.append(sdk_meter);

        return meter;
    }

    /// Collect metrics from all meters managed by this provider
    pub fn collectMetrics(self: *StandardMeterProvider, allocator: std.mem.Allocator) ![]MetricData {
        var metrics = std.ArrayList(MetricData).init(allocator);
        errdefer metrics.deinit();

        // Iterate through all SDK meters and collect their metrics
        for (self.sdk_meters.items) |sdk_meter| {
            const meter_metrics = try sdk_meter.collectMetrics(allocator);
            defer allocator.free(meter_metrics);
            try metrics.appendSlice(meter_metrics);
        }

        return metrics.toOwnedSlice();
    }
};

/// Create a standard meter provider
pub fn createProvider(allocator: std.mem.Allocator) !StandardMeterProvider {
    return try StandardMeterProvider.init(allocator, null);
}

/// Create a standard meter provider with a resource
pub fn createProviderWithResource(
    allocator: std.mem.Allocator,
    resource: Resource,
) !StandardMeterProvider {
    return try StandardMeterProvider.init(allocator, resource);
}

// Tests

test "StandardMeterProvider caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = try createProvider(allocator);
    defer provider.deinit();

    // Get meter with same scope multiple times
    const scope = try InstrumentationScope.initWithName("test.meter");
    const meter1 = try provider.getMeterWithScope(scope);
    const meter2 = try provider.getMeterWithScope(scope);
    const meter3 = try provider.getMeterWithScope(scope);

    // Should return the same instance
    try testing.expectEqual(meter1, meter2);
    try testing.expectEqual(meter2, meter3);

    // Get meter with different scope
    const scope2 = try InstrumentationScope.initWithName("test.meter2");
    const meter4 = try provider.getMeterWithScope(scope2);

    // Should be different instance
    try testing.expect(meter1 != meter4);
}

test "StandardMeterProvider convenience methods" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = try createProvider(allocator);
    defer provider.deinit();

    // Test getMeter with name
    const meter1 = try provider.getMeter("simple.meter", null, null, &[_]KeyValue{});
    
    // Verify we got standard (SDK) meters, not noop meters
    try testing.expect(meter1.* == .sdk);
    
    // Test that we can access instrumentation scopes through the meter
    const scope1 = meter1.getInstrumentationScope();
    try testing.expectEqualStrings("simple.meter", scope1.name);
    
    // Test getMeter with version
    const meter2 = try provider.getMeter("versioned.meter", "1.0.0", null, &[_]KeyValue{});
    try testing.expect(meter2.* == .sdk);
    
    const scope2 = meter2.getInstrumentationScope();
    try testing.expectEqualStrings("versioned.meter", scope2.name);
    try testing.expectEqualStrings("1.0.0", scope2.version.?);
}

test "MeterProvider scope differentiation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = try createProvider(allocator);
    defer provider.deinit();

    // Same name, different versions
    const meter1 = try provider.getMeter("app.meter", "1.0.0", null, &[_]KeyValue{});
    const meter2 = try provider.getMeter("app.meter", "2.0.0", null, &[_]KeyValue{});
    const meter3 = try provider.getMeter("app.meter", "1.0.0", null, &[_]KeyValue{});

    // Different versions should get different meters
    try testing.expect(meter1 != meter2);
    // Same version should get cached meter
    try testing.expectEqual(meter1, meter3);

    // Test with schema URL
    const scope1 = try InstrumentationScope.init("test", "1.0", "http://schema.v1", &.{});
    const scope2 = try InstrumentationScope.init("test", "1.0", "http://schema.v2", &.{});
    const scope3 = try InstrumentationScope.init("test", "1.0", "http://schema.v1", &.{});

    const meter4 = try provider.getMeterWithScope(scope1);
    const meter5 = try provider.getMeterWithScope(scope2);
    const meter6 = try provider.getMeterWithScope(scope3);

    // Different schema URLs should get different meters
    try testing.expect(meter4 != meter5);
    // Same everything should get cached meter
    try testing.expectEqual(meter4, meter6);
}