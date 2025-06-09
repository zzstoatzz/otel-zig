const std = @import("std");
const logs_api = @import("otel-api").logs;
const logs_processor = @import("processor.zig");
const logs_provider = @import("logger_provider.zig");
const AttributeKeyValue = @import("otel-api").AttributeKeyValue;
const Resource = @import("../resource/resource.zig").Resource;
const ResourceBuilder = @import("../resource/resource.zig").ResourceBuilder;
const LogExporter = @import("exporter.zig").LogExporter;

pub fn createSimpleSyncLogging(allocator: std.mem.Allocator, service_name: []const u8, exporter: LogExporter) !logs_api.LoggerProvider {
    var rb = ResourceBuilder.init(allocator);
    errdefer rb.deinit();
    const resource = try rb.addResource(Resource.default)
        .addKeyValue(.{ .key = "service.name", .value = .{ .string = service_name } })
        .finish(allocator);
    errdefer resource.deinitOwned(allocator);

    const simple_processor = try logs_processor.SimpleLogProcessor.init(allocator, exporter);
    var processor = simple_processor.logProcessor();
    errdefer processor.deinit();

    const standard_provider = try logs_provider.StandardLoggerProvider.init(allocator, resource, processor);
    var provider = standard_provider.loggerProvider();
    errdefer provider.deinit();

    return provider;
}
