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
        const Self = @This();

        // None of these are owning fields.
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        meter: *sdk.Meter,
        metadata_hash: u64,

        // Owned slice of views that apply to this instrument.
        views: []sdk.ViewApplication,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
        ) !Self {
            // Precompute the hash values that don't change per datapoint.
            const metadata_hash = sdk.MetricMetadata.computeHash(
                name,
                unit orelse "",
                .Counter,
                &parent_meter.scope,
            );

            // Get the views that apply to this instrument.
            const view_applications = try parent_meter.provider.applyViews(
                name,
                .Counter,
                unit orelse "",
                description,
                parent_meter.scope.name,
                parent_meter.scope.version,
                parent_meter.scope.schema_url,
                parent_meter.allocator,
            );

            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .meter = parent_meter,
                .metadata_hash = metadata_hash,
                .views = view_applications,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.views);
        }

        pub fn getName(self: *const Self) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *Self, ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateCounterValue(i64, value)) {
                api.common.reportValidationError(.meter, "Counter.add", "Negative value provided", "counter values must be non-negative");
                return; // Return early in validation mode
            }
            _ = ctx;

            if (T == i64) {
                // Create an arena, so we don't have to keep track of which slices are
                // allocated here, and which are unowned.
                var arena = std.heap.ArenaAllocator.init(self.meter.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                // Process each view application
                for (self.views) |view| {
                    // Skip drop aggregations
                    if (view.drops()) continue;

                    // Transform attributes according to view
                    const attrs = view.transformAttributes(attributes, allocator) catch |e| blk: {
                        api.common.reportErrorWithAllocator(.{
                            .component = .meter,
                            .context = null,
                            .error_type = .internal,
                            .message = "Unable to transform attributes with view",
                            .operation = "StandardCounter.addI64()",
                            .source_error = e,
                        }, allocator);
                        break :blk attributes; // On error, use original attributes
                    };

                    // Create transformed metadata
                    const metadata = sdk.MetricMetadata{
                        .name = view.getName(self.name),
                        .description = view.getDescription(self.description) orelse "",
                        .unit = self.unit orelse "", // Unit not transformable per spec
                        .instrument_type = .Counter,
                        .instrumentation_scope = self.meter.scope,
                    };

                    // Forward to all readers
                    for (self.meter.provider.readers.items) |*reader| {
                        reader.recordMeasurement(.{ .i64 = value }, attrs, metadata, self.metadata_hash);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn addF64(self: *Self, ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateCounterValue(f64, value)) {
                api.common.reportValidationError(.meter, "Counter.add", "Negative value provided", "counter values must be non-negative");
                return; // Return early in validation mode
            }
            _ = ctx;

            if (T == f64) {
                // Create an arena, so we don't have to keep track of which slices are
                // allocated here, and which are unowned.
                var arena = std.heap.ArenaAllocator.init(self.meter.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                // Process each view application
                for (self.views) |view| {
                    // Skip drop aggregations
                    if (view.drops()) continue;

                    // Transform attributes according to view
                    const attrs = view.transformAttributes(attributes, allocator) catch |e| blk: {
                        api.common.reportErrorWithAllocator(.{
                            .component = .meter,
                            .context = null,
                            .error_type = .internal,
                            .message = "Unable to transform attributes with view",
                            .operation = "StandardCounter.addF64()",
                            .source_error = e,
                        }, allocator);
                        break :blk attributes; // On error, use original attributes
                    };

                    // Create transformed metadata
                    const metadata = sdk.MetricMetadata{
                        .name = view.getName(self.name),
                        .description = view.getDescription(self.description) orelse "",
                        .unit = self.unit orelse "", // Unit not transformable per spec
                        .instrument_type = .Counter,
                        .instrumentation_scope = self.meter.scope,
                    };

                    // Forward to all readers
                    for (self.meter.provider.readers.items) |*reader| {
                        reader.recordMeasurement(.{ .f64 = value }, attrs, metadata, self.metadata_hash);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn recordI64(_: *Self, _: api.Context, _: i64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn recordF64(_: *Self, _: api.Context, _: f64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn enabled(_: *Self) bool {
            return true;
        }
    };
}

/// Standard UpDownCounter implementation that forwards measurements to readers (allowing negative)
pub fn StandardUpDownCounter(comptime T: type) type {
    return struct {
        const Self = @This();

        // None of these are owning fields.
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        meter: *sdk.Meter,
        metadata_hash: u64,

        // Owned slice of views that apply to this instrument.
        views: []sdk.ViewApplication,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
        ) !Self {
            // Precompute the hash values that don't change per datapoint.
            const metadata_hash = sdk.MetricMetadata.computeHash(
                name,
                unit orelse "",
                .UpDownCounter,
                &parent_meter.scope,
            );

            // Get the views that apply to this instrument.
            const view_applications = try parent_meter.provider.applyViews(
                name,
                .UpDownCounter,
                unit orelse "",
                description,
                parent_meter.scope.name,
                parent_meter.scope.version,
                parent_meter.scope.schema_url,
                parent_meter.allocator,
            );

            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .meter = parent_meter,
                .metadata_hash = metadata_hash,
                .views = view_applications,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.views);
        }

        pub fn getName(self: *const Self) []const u8 {
            return self.name;
        }

        pub fn addI64(self: *Self, ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            _ = ctx;

            if (T == i64) {
                // Create an arena, so we don't have to keep track of which slices are
                // allocated here, and which are unowned.
                var arena = std.heap.ArenaAllocator.init(self.meter.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                // Process each view application
                for (self.views) |view| {
                    // Skip drop aggregations
                    if (view.drops()) continue;

                    // Transform attributes according to view
                    const attrs = view.transformAttributes(attributes, allocator) catch |e| blk: {
                        api.common.reportErrorWithAllocator(.{
                            .component = .meter,
                            .context = null,
                            .error_type = .internal,
                            .message = "Unable to transform attributes with view",
                            .operation = "StandardUpDownCounter.addI64()",
                            .source_error = e,
                        }, allocator);
                        break :blk attributes; // On error, use original attributes
                    };

                    // Create transformed metadata
                    const metadata = sdk.MetricMetadata{
                        .name = view.getName(self.name),
                        .description = view.getDescription(self.description) orelse "",
                        .unit = self.unit orelse "", // Unit not transformable per spec
                        .instrument_type = .UpDownCounter,
                        .instrumentation_scope = self.meter.scope,
                    };

                    // Forward to all readers
                    for (self.meter.provider.readers.items) |*reader| {
                        reader.recordMeasurement(.{ .i64 = value }, attrs, metadata, self.metadata_hash);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn addF64(self: *Self, ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            _ = ctx;

            if (T == f64) {
                // Create an arena, so we don't have to keep track of which slices are
                // allocated here, and which are unowned.
                var arena = std.heap.ArenaAllocator.init(self.meter.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                // Process each view application
                for (self.views) |view| {
                    // Skip drop aggregations
                    if (view.drops()) continue;

                    // Transform attributes according to view
                    const attrs = view.transformAttributes(attributes, allocator) catch |e| blk: {
                        api.common.reportErrorWithAllocator(.{
                            .component = .meter,
                            .context = null,
                            .error_type = .internal,
                            .message = "Unable to transform attributes with view",
                            .operation = "StandardUpDownCounter.addF64()",
                            .source_error = e,
                        }, allocator);
                        break :blk attributes; // On error, use original attributes
                    };

                    // Create transformed metadata
                    const metadata = sdk.MetricMetadata{
                        .name = view.getName(self.name),
                        .description = view.getDescription(self.description) orelse "",
                        .unit = self.unit orelse "", // Unit not transformable per spec
                        .instrument_type = .UpDownCounter,
                        .instrumentation_scope = self.meter.scope,
                    };

                    // Forward to all readers
                    for (self.meter.provider.readers.items) |*reader| {
                        reader.recordMeasurement(.{ .f64 = value }, attrs, metadata, self.metadata_hash);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn recordI64(_: *Self, _: api.Context, _: i64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn recordF64(_: *Self, _: api.Context, _: f64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn enabled(self: *Self) bool {
            _ = self;
            return true;
        }
    };
}

/// Standard Gauge implementation that forwards measurements to readers
pub fn StandardGauge(comptime T: type) type {
    return struct {
        const Self = @This();

        // None of these are owning fields.
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        meter: *sdk.Meter,
        metadata_hash: u64,

        // Owned slice of views that apply to this instrument.
        views: []sdk.ViewApplication,

        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
        ) !Self {
            // Precompute the hash values that don't change per datapoint.
            const metadata_hash = sdk.MetricMetadata.computeHash(
                name,
                unit orelse "",
                .Gauge,
                &parent_meter.scope,
            );

            // Get the views that apply to this instrument.
            const view_applications = try parent_meter.provider.applyViews(
                name,
                .Gauge,
                unit orelse "",
                description,
                parent_meter.scope.name,
                parent_meter.scope.version,
                parent_meter.scope.schema_url,
                parent_meter.allocator,
            );

            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .meter = parent_meter,
                .metadata_hash = metadata_hash,
                .views = view_applications,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.views);
        }

        pub fn getName(self: *const Self) []const u8 {
            return self.name;
        }

        pub fn addI64(_: *Self, _: api.Context, _: i64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn addF64(_: *Self, _: api.Context, _: f64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn recordI64(self: *Self, ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            _ = ctx;

            if (T == i64) {
                // Create an arena, so we don't have to keep track of which slices are
                // allocated here, and which are unowned.
                var arena = std.heap.ArenaAllocator.init(self.meter.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                // Process each view application
                for (self.views) |view| {
                    // Skip drop aggregations
                    if (view.drops()) continue;

                    // Transform attributes according to view
                    const attrs = view.transformAttributes(attributes, allocator) catch |e| blk: {
                        api.common.reportErrorWithAllocator(.{
                            .component = .meter,
                            .context = null,
                            .error_type = .internal,
                            .message = "Unable to transform attributes with view",
                            .operation = "StandardGauge.recordI64()",
                            .source_error = e,
                        }, allocator);
                        break :blk attributes; // On error, use original attributes
                    };

                    // Create transformed metadata
                    const metadata = sdk.MetricMetadata{
                        .name = view.getName(self.name),
                        .description = view.getDescription(self.description) orelse "",
                        .unit = self.unit orelse "", // Unit not transformable per spec
                        .instrument_type = .Gauge,
                        .instrumentation_scope = self.meter.scope,
                    };

                    // Forward to all readers
                    for (self.meter.provider.readers.items) |*reader| {
                        reader.recordMeasurement(.{ .i64 = value }, attrs, metadata, self.metadata_hash);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn recordF64(self: *Self, ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            _ = ctx;

            if (T == f64) {
                // Create an arena, so we don't have to keep track of which slices are
                // allocated here, and which are unowned.
                var arena = std.heap.ArenaAllocator.init(self.meter.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                // Process each view application
                for (self.views) |view| {
                    // Skip drop aggregations
                    if (view.drops()) continue;

                    // Transform attributes according to view
                    const attrs = view.transformAttributes(attributes, allocator) catch |e| blk: {
                        api.common.reportErrorWithAllocator(.{
                            .component = .meter,
                            .context = null,
                            .error_type = .internal,
                            .message = "Unable to transform attributes with view",
                            .operation = "StandardGauge.recordF64()",
                            .source_error = e,
                        }, allocator);
                        break :blk attributes; // On error, use original attributes
                    };

                    // Create transformed metadata
                    const metadata = sdk.MetricMetadata{
                        .name = view.getName(self.name),
                        .description = view.getDescription(self.description) orelse "",
                        .unit = self.unit orelse "", // Unit not transformable per spec
                        .instrument_type = .Gauge,
                        .instrumentation_scope = self.meter.scope,
                    };

                    // Forward to all readers
                    for (self.meter.provider.readers.items) |*reader| {
                        reader.recordMeasurement(.{ .f64 = value }, attrs, metadata, self.metadata_hash);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn enabled(self: *Self) bool {
            _ = self;
            return true;
        }
    };
}

/// Standard Histogram implementation that forwards measurements to readers
pub fn StandardHistogram(comptime T: type) type {
    return struct {
        const Self = @This();

        // None of these are owning fields.
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        meter: *sdk.Meter,
        metadata_hash: u64,

        // Owned slice of views that apply to this instrument.
        views: []sdk.ViewApplication,

        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *sdk.Meter,
            config: sdk.aggregations.HistogramAggregationConfig,
        ) !Self {
            _ = allocator; // Unused in Phase 1
            _ = config;

            // Precompute the hash values that don't change per datapoint.
            const metadata_hash = sdk.MetricMetadata.computeHash(
                name,
                unit orelse "",
                .Histogram,
                &parent_meter.scope,
            );

            // Get the views that apply to this instrument.
            const view_applications = try parent_meter.provider.applyViews(
                name,
                .Gauge,
                unit orelse "",
                description,
                parent_meter.scope.name,
                parent_meter.scope.version,
                parent_meter.scope.schema_url,
                parent_meter.allocator,
            );

            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .meter = parent_meter,
                .metadata_hash = metadata_hash,
                .views = view_applications,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.views);
        }

        pub fn getName(self: *const Self) []const u8 {
            return self.name;
        }

        pub fn addI64(_: *Self, _: api.Context, _: i64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn addF64(_: *Self, _: api.Context, _: f64, _: []const api.AttributeKeyValue) void {
            unreachable;
        }

        pub fn recordI64(self: *Self, ctx: api.Context, value: i64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateHistogramValue(i64, value)) {
                api.common.reportValidationError(.meter, "Histogram.record", "Negative value provided", "histogram values must be non-negative");
                return; // Return early in validation mode
            }
            _ = ctx;

            if (T == i64) {
                // Create an arena, so we don't have to keep track of which slices are
                // allocated here, and which are unowned.
                var arena = std.heap.ArenaAllocator.init(self.meter.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                // Process each view application
                for (self.views) |view| {
                    // Skip drop aggregations
                    if (view.drops()) continue;

                    // Transform attributes according to view
                    const attrs = view.transformAttributes(attributes, allocator) catch |e| blk: {
                        api.common.reportErrorWithAllocator(.{
                            .component = .meter,
                            .context = null,
                            .error_type = .internal,
                            .message = "Unable to transform attributes with view",
                            .operation = "StandardHistogram.recordI64()",
                            .source_error = e,
                        }, allocator);
                        break :blk attributes; // On error, use original attributes
                    };

                    // Create transformed metadata
                    const metadata = sdk.MetricMetadata{
                        .name = view.getName(self.name),
                        .description = view.getDescription(self.description) orelse "",
                        .unit = self.unit orelse "", // Unit not transformable per spec
                        .instrument_type = .Histogram,
                        .instrumentation_scope = self.meter.scope,
                    };

                    // Forward to all readers
                    for (self.meter.provider.readers.items) |*reader| {
                        reader.recordMeasurement(.{ .i64 = value }, attrs, metadata, self.metadata_hash);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn recordF64(self: *Self, ctx: api.Context, value: f64, attributes: []const api.AttributeKeyValue) void {
            if (!api.metrics.validateHistogramValue(f64, value)) {
                api.common.reportValidationError(.meter, "Histogram.record", "Negative value provided", "histogram values must be non-negative");
                return; // Return early in validation mode
            }
            _ = ctx;

            if (T == f64) {
                // Create an arena, so we don't have to keep track of which slices are
                // allocated here, and which are unowned.
                var arena = std.heap.ArenaAllocator.init(self.meter.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                // Process each view application
                for (self.views) |view| {
                    // Skip drop aggregations
                    if (view.drops()) continue;

                    // Transform attributes according to view
                    const attrs = view.transformAttributes(attributes, allocator) catch |e| blk: {
                        api.common.reportErrorWithAllocator(.{
                            .component = .meter,
                            .context = null,
                            .error_type = .internal,
                            .message = "Unable to transform attributes with view",
                            .operation = "StandardHistogram.recordI64()",
                            .source_error = e,
                        }, allocator);
                        break :blk attributes; // On error, use original attributes
                    };

                    // Create transformed metadata
                    const metadata = sdk.MetricMetadata{
                        .name = view.getName(self.name),
                        .description = view.getDescription(self.description) orelse "",
                        .unit = self.unit orelse "", // Unit not transformable per spec
                        .instrument_type = .Histogram,
                        .instrumentation_scope = self.meter.scope,
                    };

                    // Forward to all readers
                    for (self.meter.provider.readers.items) |*reader| {
                        reader.recordMeasurement(.{ .f64 = value }, attrs, metadata, self.metadata_hash);
                    }
                }
            } else {
                unreachable;
            }
        }

        pub fn enabled(self: *Self) bool {
            _ = self;
            return true;
        }
    };
}
