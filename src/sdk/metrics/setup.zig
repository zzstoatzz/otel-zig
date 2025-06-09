const std = @import("std");
const metrics_api = @import("otel-api").metrics;
const metrics_processor = @import("processor.zig");
const metrics_provider = @import("meter_provider.zig");
const AttributeKeyValue = @import("otel-api").AttributeKeyValue;
const Resource = @import("../resource/resource.zig").Resource;
const ResourceBuilder = @import("../resource/resource.zig").ResourceBuilder;
const MetricExporter = @import("exporter.zig").MetricExporter;

pub fn createSimpleSyncMetrics(allocator: std.mem.Allocator, service_name: []const u8, exporter: MetricExporter) !metrics_api.MeterProvider {
    var rb = ResourceBuilder.init(allocator);
    errdefer rb.deinit();
    const resource = try rb.addResource(Resource.default)
        .addKeyValue(.{ .key = "service.name", .value = .{ .string = service_name } })
        .finish(allocator);
    errdefer resource.deinitOwned(allocator);

    var simple_processor = try metrics_processor.SimpleMetricProcessor.init(allocator, exporter);
    var processor = simple_processor.metricProcessor();
    errdefer processor.deinit();

    const standard_provider = try metrics_provider.StandardMeterProvider.init(allocator, resource, processor);
    var provider = standard_provider.meterProvider();
    errdefer provider.deinit();

    return provider;
}
