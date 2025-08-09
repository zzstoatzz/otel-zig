//! Reader Aggregation State for OpenTelemetry Metrics SDK
//!
//! This module manages aggregation state per reader, allowing multiple readers
//! to maintain independent aggregation states for the same instruments.

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const InstrumentType = @import("metadata.zig").InstrumentType;
    const aggregations = @import("aggregations.zig");
    const MetricData = @import("data.zig").MetricData;
    const MetricDataPoint = @import("data.zig").MetricDataPoint;
    const MetricValue = @import("reader.zig").MetricValue;
    const AttributeAggregationMap = @import("attribute_aggregation_map.zig").AttributeAggregationMap;
    const Aggregation = @import("attribute_aggregation_map.zig").Aggregation;
    const AttributeAggregationEntry = @import("attribute_aggregation_map.zig").AttributeAggregationEntry;
    const Resource = @import("../resource/resource.zig").Resource;
};

/// Aggregation temporality for metric data points
pub const AggregationTemporality = enum {
    Delta,
    Cumulative,
};

/// Function type for selecting aggregation based on instrument type
pub const AggregationSelector = *const fn (instrument_type: sdk.InstrumentType) AggregationType;

/// Types of aggregations available
pub const AggregationType = enum {
    sum,
    last_value,
    histogram,
    drop, // Special case: don't aggregate at all
};

/// Default aggregation selector based on instrument type
pub fn defaultAggregationSelector(instrument_type: sdk.InstrumentType) AggregationType {
    return switch (instrument_type) {
        .Counter, .UpDownCounter, .ObservableCounter, .ObservableUpDownCounter => .sum,
        .Gauge, .ObservableGauge => .last_value,
        .Histogram, .ObservableHistogram => .histogram,
    };
}

/// Per-reader aggregation state management
pub const ReaderAggregationState = struct {
    // Phase 1b: Attribute-based aggregation map with cardinality limits
    aggregations: sdk.AttributeAggregationMap,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    // Reader's configured temporality
    temporality: AggregationTemporality,

    // Aggregation selector (determines aggregation type per instrument)
    aggregation_selector: AggregationSelector,

    // For cumulative temporality, track last collection time
    last_collection_time_ns: u64,

    /// Initialize reader aggregation state
    pub fn init(
        allocator: std.mem.Allocator,
        temporality: AggregationTemporality,
        aggregation_selector: AggregationSelector,
    ) !@This() {
        return .{
            .aggregations = try sdk.AttributeAggregationMap.init(allocator),
            .allocator = allocator,
            .mutex = .{},
            .temporality = temporality,
            .aggregation_selector = aggregation_selector,
            .last_collection_time_ns = @intCast(std.time.nanoTimestamp()),
        };
    }

    /// Clean up all aggregations and resources
    pub fn deinit(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up the attribute aggregation map
        self.aggregations.deinit();
    }

    /// Record a measurement from an instrument (lock-free for aggregation updates)
    pub fn recordMeasurement(
        self: *@This(),
        value: sdk.MetricValue,
        attributes: []const api.AttributeKeyValue,
        metadata: sdk.MetricMetadata,
        metadata_hash: u64,
    ) void {
        // Phase 1c: Lock only for map access, aggregation updates are lock-free
        const agg = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            // Get or create aggregation for this instrument + attribute combination
            break :blk self.aggregations.getOrCreateAggregation(attributes, metadata, metadata_hash, value);
        };

        // Record the measurement lock-free (aggregations use atomic operations)
        switch (value) {
            .i64 => |v| agg.aggregation.record(v, self.allocator),
            .f64 => |v| agg.aggregation.record(v, self.allocator),
        }
    }

    /// Collect metrics from all aggregations (lock-free aggregation access)
    pub fn collect(self: *@This(), allocator: std.mem.Allocator) ![]sdk.MetricData {
        // Lock only for map iteration, aggregation data access is lock-free
        var entry_list = std.ArrayList(sdk.AttributeAggregationEntry).init(allocator);
        defer entry_list.deinit();

        // Copy aggregation entry pointers under lock
        try self.aggregations.snapshot(allocator, &entry_list);

        var metrics_list = std.ArrayList(sdk.MetricData).init(allocator);
        errdefer metrics_list.deinit();

        const current_timestamp = @as(u64, @intCast(std.time.nanoTimestamp()));

        // Process aggregation entries lock-free (atomic reads)
        for (entry_list.items) |*entry| {
            // Create metric data based on aggregation type (lock-free atomic reads)
            const metric_data = try self.createMetricDataFromAggregationEntry(
                allocator,
                entry,
                current_timestamp,
            );

            if (metric_data) |data| {
                try metrics_list.append(data);
            }
        }

        return metrics_list.toOwnedSlice();
    }

    /// Convert a single aggregation entry to MetricData
    fn createMetricDataFromAggregationEntry(
        self: *@This(),
        allocator: std.mem.Allocator,
        entry: *sdk.AttributeAggregationEntry,
        timestamp: u64,
    ) !?sdk.MetricData {
        _ = self; // Not used in this helper method

        // Create data points array with single point
        const data_points = try allocator.alloc(sdk.MetricDataPoint, 1);
        errdefer allocator.free(data_points);

        // Clone attributes from the entry for export
        // const export_attributes = try allocator.alloc(api.AttributeKeyValue, entry.attributes.len);
        // @memcpy(export_attributes, entry.attributes);
        const export_attributes = entry.attributes;

        switch (entry.aggregation) {
            .sum_i64 => |*sum| {
                data_points[0] = sdk.MetricDataPoint{
                    .timestamp_ns = timestamp,
                    .start_timestamp_ns = sum.start_timestamp_ns,
                    .attributes = export_attributes,
                    .value = .{ .i64_sum = sum.value.load(.monotonic) },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .sum,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = sdk.Resource.empty,
                };
            },
            .sum_f64 => |*sum| {
                data_points[0] = sdk.MetricDataPoint{
                    .timestamp_ns = timestamp,
                    .start_timestamp_ns = sum.start_timestamp_ns,
                    .attributes = export_attributes,
                    .value = .{ .f64_sum = sum.value.load(.monotonic) },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .sum,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = sdk.Resource.empty,
                };
            },
            .last_value_i64 => |*lv| {
                const value = lv.getValue();
                if (value == null) {
                    // No value recorded, skip this gauge
                    allocator.free(data_points);
                    allocator.free(export_attributes);
                    return null;
                }

                data_points[0] = sdk.MetricDataPoint{
                    .timestamp_ns = timestamp,
                    .start_timestamp_ns = 0, // Last value doesn't have start time
                    .attributes = export_attributes,
                    .value = .{ .i64_gauge = value.? },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .gauge,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = sdk.Resource.empty,
                };
            },
            .last_value_f64 => |*lv| {
                const value = lv.getValue();
                if (value == null) {
                    // No value recorded, skip this gauge
                    allocator.free(data_points);
                    allocator.free(export_attributes);
                    return null;
                }

                data_points[0] = sdk.MetricDataPoint{
                    .timestamp_ns = timestamp,
                    .start_timestamp_ns = 0, // Last value doesn't have start time
                    .attributes = export_attributes,
                    .value = .{ .f64_gauge = value.? },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .gauge,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = sdk.Resource.empty,
                };
            },
            .histogram_i64 => |*hist| {
                if (hist.getCount() == 0) {
                    // No data recorded, skip this histogram
                    allocator.free(data_points);
                    allocator.free(export_attributes);
                    return null;
                }

                // Copy atomic bucket counts to regular u64 array
                const bucket_counts = try allocator.alloc(u64, hist.counts.len);
                for (hist.counts, 0..) |*atomic_count, i| {
                    bucket_counts[i] = atomic_count.load(.monotonic);
                }

                data_points[0] = sdk.MetricDataPoint{
                    .timestamp_ns = timestamp,
                    .start_timestamp_ns = hist.start_timestamp_ns,
                    .attributes = export_attributes,
                    .value = .{
                        .i64_histogram = .{
                            .count = hist.getCount(),
                            .sum = hist.getSum(),
                            .min = hist.getMin(),
                            .max = hist.getMax(),
                            .boundaries = hist.boundaries,
                            .bucket_counts = bucket_counts,
                        },
                    },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .histogram,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = sdk.Resource.empty,
                };
            },
            .histogram_f64 => |*hist| {
                if (hist.getCount() == 0) {
                    // No data recorded, skip this histogram
                    allocator.free(data_points);
                    allocator.free(export_attributes);
                    return null;
                }

                // Copy atomic bucket counts to regular u64 array
                const bucket_counts = try allocator.alloc(u64, hist.counts.len);
                for (hist.counts, 0..) |*atomic_count, i| {
                    bucket_counts[i] = atomic_count.load(.monotonic);
                }

                data_points[0] = sdk.MetricDataPoint{
                    .timestamp_ns = timestamp,
                    .start_timestamp_ns = hist.start_timestamp_ns,
                    .attributes = export_attributes,
                    .value = .{
                        .f64_histogram = .{
                            .count = hist.getCount(),
                            .sum = hist.getSum(),
                            .min = hist.getMin(),
                            .max = hist.getMax(),
                            .boundaries = hist.boundaries,
                            .bucket_counts = bucket_counts,
                        },
                    },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .histogram,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = sdk.Resource.empty,
                };
            },
            .drop => {
                // Drop aggregation produces no metric data
                allocator.free(data_points);
                allocator.free(export_attributes);
                return null;
            },
        }
    }
};
