const AttributeKeyValue = @import("otel-api").AttributeKeyValue;
const InstrumentationScope = @import("otel-api").InstrumentationScope;
const Resource = @import("../resource/resource.zig").Resource;

/// Metric data point representing a single measurement
pub const MetricDataPoint = struct {
    /// Timestamp when the measurement was recorded
    timestamp_ns: u64,
    /// Start timestamp for monotonic counters (null for gauges)
    start_timestamp_ns: ?u64,
    /// Attributes associated with this data point
    attributes: []const AttributeKeyValue,
    /// The actual value
    value: MetricValue,
};

/// Possible metric values
pub const MetricValue = union(enum) {
    i64_sum: i64,
    f64_sum: f64,
    i64_gauge: i64,
    f64_gauge: f64,
    // Histogram support can be added later
};

/// Aggregated metric data
pub const MetricData = struct {
    /// Instrument name
    name: []const u8,
    /// Instrument description
    description: ?[]const u8,
    /// Unit of measurement
    unit: ?[]const u8,
    /// Type of metric
    type: MetricType,
    /// Aggregated data points
    data_points: []const MetricDataPoint,
    /// Instrumentation scope that created this metric
    scope: InstrumentationScope,
    /// Resource associated with this metric
    resource: Resource,
};

pub const MetricType = enum {
    sum,
    gauge,
    histogram,
};
