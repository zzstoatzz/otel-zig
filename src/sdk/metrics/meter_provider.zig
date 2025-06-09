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
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const Context = otel_api.Context;

const Resource = @import("../resource/resource.zig").Resource;
const getDefaultResource = @import("../resource/resource.zig").getDefaultResource;
const createStandardMeter = @import("meter.zig").createStandardMeter;
const MetricData = @import("data.zig").MetricData;
const MetricDataPoint = @import("data.zig").MetricDataPoint;
const MetricType = @import("data.zig").MetricType;
const MetricValue = @import("data.zig").MetricValue;
const MetricProcessor = @import("processor.zig").MetricProcessor;
const StandardMeter = @import("meter.zig").StandardMeter;
const FlushResult = otel_api.common.FlushResult;

/// Context for meter cache HashMap
const MeterCacheContext = struct {
    pub fn hash(_: MeterCacheContext, key: InstrumentationScope) u64 {
        return key.hashCode();
    }

    pub fn eql(_: MeterCacheContext, a: InstrumentationScope, b: InstrumentationScope) bool {
        return InstrumentationScope.eql(a, b);
    }
};

/// Standard meter provider with caching and configuration
pub const StandardMeterProvider = struct {
    allocator: std.mem.Allocator,
    resource: Resource,
    cache: std.HashMapUnmanaged(InstrumentationScope, *StandardMeter, MeterCacheContext, 80),
    default_processor: MetricProcessor,

    pub fn init(
        allocator: std.mem.Allocator,
        resource: Resource,
        metric_processor: MetricProcessor,
    ) !*StandardMeterProvider {
        const self = try allocator.create(StandardMeterProvider);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .resource = resource,
            .cache = .empty,
            .default_processor = metric_processor,
        };
        return self;
    }

    pub fn deinit(self: *StandardMeterProvider) void {
        // Clean up all API meters
        var iter = self.cache.iterator();
        while (iter.next()) |kv| {
            // Unregister the meter from the processor
            self.default_processor.unregisterMeter(kv.value_ptr.*);
            kv.key_ptr.deinitOwned(self.allocator);
            kv.value_ptr.*.deinit();
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.cache.deinit(self.allocator);
        self.resource.deinitOwned(self.allocator);
        self.default_processor.deinit();
        self.allocator.destroy(self);
    }

    /// Interface defined method to get a meter.
    ///
    /// The provided scope is copied internally.
    pub fn getMeterWithScope(self: *StandardMeterProvider, scope: InstrumentationScope) !Meter {
        // Check cache first
        if (self.cache.get(scope)) |meter| {
            return otel_api.metrics.Meter{
                .bridge = otel_api.metrics.MeterBridge.init(meter),
            };
        }

        // Create a locally owned Scope.
        const owned_scope = try InstrumentationScope.init(
            try self.allocator.dupe(u8, scope.name),
            if (scope.version) |version| try self.allocator.dupe(u8, version) else null,
            if (scope.schema_url) |url| try self.allocator.dupe(u8, url) else null,
            try otel_api.AttributeKeyValue.initOwnedSlice(self.allocator, scope.attributes),
        );
        errdefer owned_scope.deinitOwned(self.allocator);

        // Create new SDK meter
        const std_meter = try self.allocator.create(StandardMeter);
        errdefer self.allocator.destroy(std_meter);

        std_meter.* = try StandardMeter.init(self.allocator, scope, self.resource, self.default_processor);

        // Register the meter with the processor for collection
        self.default_processor.registerMeter(std_meter);

        try self.cache.put(self.allocator, owned_scope, std_meter);

        return otel_api.metrics.Meter{
            .bridge = otel_api.metrics.MeterBridge.init(std_meter),
        };
    }

    /// Interface defined method to force the attached processor to flush.
    pub fn forceFlush(self: *StandardMeterProvider, timeout_ms: ?u64) FlushResult {
        self.default_processor.collect();
        return if (self.default_processor.forceFlush(timeout_ms).isSuccess()) .success else .failure;
    }

    pub fn meterProvider(self: *StandardMeterProvider) otel_api.metrics.MeterProvider {
        return otel_api.metrics.MeterProvider{ .bridge = otel_api.metrics.MeterProviderBridge.init(self) };
    }
};
