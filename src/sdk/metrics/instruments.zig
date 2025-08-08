//! OpenTelemetry Basic Meter Provider SDK Implementation
//!
//! This module provides the basic concrete implementation of MeterProvider for the SDK.
//! It manages meter lifecycle, caching, and configuration.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const Meter = @import("meter.zig").Meter;
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const MetricValue = @import("reader.zig").MetricValue;
    const aggregations = @import("aggregations.zig");
    const View = @import("view.zig").View;
    const ViewApplication = @import("view.zig").ViewApplication;
};

/// Standard Counter implementation that forwards measurements to readers
pub fn StandardCounter(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        meter: *sdk.Meter,
        metadata_hash: u64,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
        ) !@This() {
            const metadata_hash = sdk.MetricMetadata.computeHash(
                name,
                unit orelse "",
                .Counter,
                parent_meter.scope.name,
                parent_meter.scope.version orelse "",
                parent_meter.scope.schema_url orelse "",
            );

            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .meter = parent_meter,
                .metadata_hash = metadata_hash,
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateCounterValue(i64, value)) {
                api.common.reportValidationError(.meter, "Counter.add", "Negative value provided", "counter values must be non-negative");
                return; // Return early in validation mode
            }
            _ = ctx;

            if (T == i64) {
                // Apply views and forward to readers
                if (self.meter.provider) |provider| {
                    // Apply all matching views to this instrument
                    const view_applications = provider.applyViews(
                        self.name,
                        .Counter,
                        self.unit orelse "",
                        self.description,
                        self.meter.scope.name,
                        self.meter.scope.version,
                        self.meter.scope.schema_url,
                        provider.allocator,
                    ) catch &[_]sdk.ViewApplication{.{ .view = sdk.View.default }};
                    defer provider.allocator.free(view_applications);

                    // Process each view application
                    for (view_applications) |view_app| {
                        // Skip drop aggregations
                        if (view_app.drops()) continue;

                        // Transform attributes according to view
                        const transformed_attrs = view_app.transformAttributes(
                            attributes,
                            provider.allocator,
                        ) catch attributes; // On error, use original attributes
                        defer if (transformed_attrs.ptr != attributes.ptr) provider.allocator.free(transformed_attrs);

                        // Create transformed metadata
                        const transformed_metadata = sdk.MetricMetadata{
                            .name = view_app.getName(self.name),
                            .description = view_app.getDescription(self.description) orelse "",
                            .unit = self.unit orelse "", // Unit not transformable per spec
                            .instrument_type = .Counter,
                            .meter_name = self.meter.scope.name,
                            .meter_version = self.meter.scope.version orelse "",
                            .meter_schema_url = self.meter.scope.schema_url orelse "",
                            .metadata_hash = self.metadata_hash, // TODO: Recalculate for transformed metadata
                        };

                        // Forward to all readers
                        for (provider.readers.items) |*reader| {
                            reader.recordMeasurement(self, .{ .i64 = value }, transformed_attrs, transformed_metadata);
                        }
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn addF64(self: *@This(), ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateCounterValue(f64, value)) {
                api.common.reportValidationError(.meter, "Counter.add", "Negative value provided", "counter values must be non-negative");
                return; // Return early in validation mode
            }
            _ = ctx;

            if (T == f64) {
                const metadata = sdk.MetricMetadata{
                    .name = self.name,
                    .description = self.description orelse "",
                    .unit = self.unit orelse "",
                    .instrument_type = .Counter,
                    .meter_name = self.meter.scope.name,
                    .meter_version = self.meter.scope.version orelse "",
                    .meter_schema_url = self.meter.scope.schema_url orelse "",
                    .metadata_hash = self.metadata_hash,
                };

                // Forward to all readers via meter.provider.readers
                if (self.meter.provider) |provider| {
                    for (provider.readers.items) |*reader| {
                        reader.recordMeasurement(self, .{ .f64 = value }, attributes, metadata);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn recordI64(_: *@This(), _: api.Context, _: i64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn recordF64(_: *@This(), _: api.Context, _: f64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn enabled(self: *@This()) bool {
            _ = self;
            return true;
        }
    };
}

/// Standard UpDownCounter implementation that forwards measurements to readers (allowing negative)
pub fn StandardUpDownCounter(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        meter: *sdk.Meter,
        metadata_hash: u64,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
        ) !@This() {
            const metadata_hash = sdk.MetricMetadata.computeHash(
                name,
                unit orelse "",
                .UpDownCounter,
                parent_meter.scope.name,
                parent_meter.scope.version orelse "",
                parent_meter.scope.schema_url orelse "",
            );

            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .meter = parent_meter,
                .metadata_hash = metadata_hash,
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            _ = ctx;

            if (T == i64) {
                const metadata = sdk.MetricMetadata{
                    .name = self.name,
                    .description = self.description orelse "",
                    .unit = self.unit orelse "",
                    .instrument_type = .UpDownCounter,
                    .meter_name = self.meter.scope.name,
                    .meter_version = self.meter.scope.version orelse "",
                    .meter_schema_url = self.meter.scope.schema_url orelse "",
                    .metadata_hash = self.metadata_hash,
                };

                // Forward to all readers via meter.provider.readers
                if (self.meter.provider) |provider| {
                    for (provider.readers.items) |*reader| {
                        reader.recordMeasurement(self, .{ .i64 = value }, attributes, metadata);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn addF64(self: *@This(), ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            _ = ctx;

            if (T == f64) {
                const metadata = sdk.MetricMetadata{
                    .name = self.name,
                    .description = self.description orelse "",
                    .unit = self.unit orelse "",
                    .instrument_type = .UpDownCounter,
                    .meter_name = self.meter.scope.name,
                    .meter_version = self.meter.scope.version orelse "",
                    .meter_schema_url = self.meter.scope.schema_url orelse "",
                    .metadata_hash = self.metadata_hash,
                };

                // Forward to all readers via meter.provider.readers
                if (self.meter.provider) |provider| {
                    for (provider.readers.items) |*reader| {
                        reader.recordMeasurement(self, .{ .f64 = value }, attributes, metadata);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn recordI64(_: *@This(), _: api.Context, _: i64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn recordF64(_: *@This(), _: api.Context, _: f64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn enabled(self: *@This()) bool {
            _ = self;
            return true;
        }
    };
}

/// Standard Gauge implementation that forwards measurements to readers
pub fn StandardGauge(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        meter: *sdk.Meter,
        metadata_hash: u64,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
        ) !@This() {
            const metadata_hash = sdk.MetricMetadata.computeHash(
                name,
                unit orelse "",
                .Gauge,
                parent_meter.scope.name,
                parent_meter.scope.version orelse "",
                parent_meter.scope.schema_url orelse "",
            );

            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .meter = parent_meter,
                .metadata_hash = metadata_hash,
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *@This(), ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn addF64(self: *@This(), ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            _ = self;
            _ = ctx;
            _ = attributes;
            _ = value;
            unreachable;
        }

        pub fn recordI64(self: *@This(), ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            _ = ctx;

            if (T == i64) {
                const metadata = sdk.MetricMetadata{
                    .name = self.name,
                    .description = self.description orelse "",
                    .unit = self.unit orelse "",
                    .instrument_type = .Gauge,
                    .meter_name = self.meter.scope.name,
                    .meter_version = self.meter.scope.version orelse "",
                    .meter_schema_url = self.meter.scope.schema_url orelse "",
                    .metadata_hash = self.metadata_hash,
                };

                // Forward to all readers via meter.provider.readers
                if (self.meter.provider) |provider| {
                    for (provider.readers.items) |*reader| {
                        reader.recordMeasurement(self, .{ .i64 = value }, attributes, metadata);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn recordF64(self: *@This(), ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            _ = ctx;

            if (T == f64) {
                const metadata = sdk.MetricMetadata{
                    .name = self.name,
                    .description = self.description orelse "",
                    .unit = self.unit orelse "",
                    .instrument_type = .Gauge,
                    .meter_name = self.meter.scope.name,
                    .meter_version = self.meter.scope.version orelse "",
                    .meter_schema_url = self.meter.scope.schema_url orelse "",
                    .metadata_hash = self.metadata_hash,
                };

                // Forward to all readers via meter.provider.readers
                if (self.meter.provider) |provider| {
                    for (provider.readers.items) |*reader| {
                        reader.recordMeasurement(self, .{ .f64 = value }, attributes, metadata);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn enabled(self: *@This()) bool {
            _ = self;
            return true;
        }
    };
}

/// Standard Histogram implementation that forwards measurements to readers
pub fn StandardHistogram(comptime T: type) type {
    return struct {
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        meter: *sdk.Meter,
        metadata_hash: u64,

        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
            config: sdk.aggregations.HistogramAggregationConfig,
        ) !@This() {
            _ = allocator; // Unused in Phase 1
            _ = config; // Unused in Phase 1

            const metadata_hash = sdk.MetricMetadata.computeHash(
                name,
                unit orelse "",
                .Histogram,
                parent_meter.scope.name,
                parent_meter.scope.version orelse "",
                parent_meter.scope.schema_url orelse "",
            );

            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .meter = parent_meter,
                .metadata_hash = metadata_hash,
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getName(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn addI64(_: *@This(), _: api.Context, _: i64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn addF64(_: *@This(), _: api.Context, _: f64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn recordI64(self: *@This(), ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateHistogramValue(i64, value)) {
                api.common.reportValidationError(.meter, "Histogram.record", "Negative value provided", "histogram values must be non-negative");
                return; // Return early in validation mode
            }
            _ = ctx;

            if (T == i64) {
                const metadata = sdk.MetricMetadata{
                    .name = self.name,
                    .description = self.description orelse "",
                    .unit = self.unit orelse "",
                    .instrument_type = .Histogram,
                    .meter_name = self.meter.scope.name,
                    .meter_version = self.meter.scope.version orelse "",
                    .meter_schema_url = self.meter.scope.schema_url orelse "",
                    .metadata_hash = self.metadata_hash,
                };

                // Forward to all readers via meter.provider.readers
                if (self.meter.provider) |provider| {
                    for (provider.readers.items) |*reader| {
                        reader.recordMeasurement(self, .{ .i64 = value }, attributes, metadata);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn recordF64(self: *@This(), ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateHistogramValue(f64, value)) {
                api.common.reportValidationError(.meter, "Histogram.record", "Negative value provided", "histogram values must be non-negative");
                return; // Return early in validation mode
            }
            _ = ctx;

            if (T == f64) {
                const metadata = sdk.MetricMetadata{
                    .name = self.name,
                    .description = self.description orelse "",
                    .unit = self.unit orelse "",
                    .instrument_type = .Histogram,
                    .meter_name = self.meter.scope.name,
                    .meter_version = self.meter.scope.version orelse "",
                    .meter_schema_url = self.meter.scope.schema_url orelse "",
                    .metadata_hash = self.metadata_hash,
                };

                // Forward to all readers via meter.provider.readers
                if (self.meter.provider) |provider| {
                    for (provider.readers.items) |*reader| {
                        reader.recordMeasurement(self, .{ .f64 = value }, attributes, metadata);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn enabled(self: *@This()) bool {
            _ = self;
            return true;
        }
    };
}
