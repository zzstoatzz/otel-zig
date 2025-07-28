//! OpenTelemetry Protocol (OTLP) Trace Exporter
//!
//! This module provides an OTLP exporter for trace spans that sends
//! data to OTLP-compatible backends using HTTP/JSON transport.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

const ExportResult = otel_api.common.ExportResult;
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const RecordingSpan = otel_sdk.trace.RecordingSpan;
const Resource = otel_sdk.resource.Resource;
const SpanContext = otel_api.trace.SpanContext;

// Import error handler for structured error reporting
const error_handler = otel_api.common;
const SpanExporter = otel_sdk.trace.SpanExporter;

// OTLP data structures for JSON serialization
const OtlpTracesData = struct {
    resourceSpans: []OtlpResourceSpans,
};

const OtlpResourceSpans = struct {
    resource: OtlpResource,
    scopeSpans: []OtlpScopeSpans,
};

const OtlpResource = struct {
    attributes: []OtlpKeyValue,
};

const OtlpScopeSpans = struct {
    scope: OtlpInstrumentationScope,
    spans: []OtlpSpan,
};

const OtlpInstrumentationScope = struct {
    name: []const u8,
    version: ?[]const u8 = null,
};

const OtlpSpan = struct {
    traceId: []const u8,
    spanId: []const u8,
    parentSpanId: ?[]const u8 = null,
    name: []const u8,
    kind: u32,
    startTimeUnixNano: u64,
    endTimeUnixNano: u64,
    attributes: []OtlpKeyValue,
    events: []OtlpEvent,
    links: []OtlpLink,
    status: OtlpStatus,
    droppedAttributesCount: u32 = 0,
    droppedEventsCount: u32 = 0,
    droppedLinksCount: u32 = 0,
};

const OtlpEvent = struct {
    timeUnixNano: u64,
    name: []const u8,
    attributes: []OtlpKeyValue,
};

const OtlpLink = struct {
    traceId: []const u8,
    spanId: []const u8,
    attributes: []OtlpKeyValue,
};

const OtlpStatus = struct {
    code: u32,
    message: ?[]const u8 = null,
};

const OtlpKeyValue = struct {
    key: []const u8,
    value: OtlpAnyValue,
};

const OtlpAnyValue = union(enum) {
    stringValue: []const u8,
    intValue: i64,
    doubleValue: f64,
    boolValue: bool,
};

/// OTLP trace exporter implementation
pub const OtlpTraceExporter = struct {
    pub const PipelineStep = otel_sdk.common.PipelineStepInstructions(
        OtlpTraceExporter,
        SpanExporter,
        OtlpExporterConfig,
        spanExporter,
        _init,
        otel_sdk.common.PipelineDeinitConnection,
    );

    pub fn _init(self: *OtlpTraceExporter, config: OtlpExporterConfig, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, config);
    }

    config: OtlpExporterConfig,
    allocator: std.mem.Allocator,
    is_shutdown: bool,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: OtlpExporterConfig) OtlpTraceExporter {
        return .{
            .config = config,
            .allocator = allocator,
            .is_shutdown = false,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *OtlpTraceExporter) void {
        _ = self;
    }

    pub fn destroy(self: *OtlpTraceExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportSpans(self: *OtlpTraceExporter, spans: []const *RecordingSpan, resource: Resource) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        if (spans.len == 0) {
            return .success;
        }

        // Local arena for the OTLP transform and network send
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const json_data = convertToOtlpFormat(arena.allocator(), spans, resource) catch |err| {
            const first_span_name = if (spans.len > 0) spans[0].name else "(no spans)";
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_trace_serialization",
                .error_type = .serialization,
                .message = "OTLP trace JSON conversion failed",
                .context = first_span_name,
                .source_error = err,
            });
            return .failure;
        };
        defer arena.allocator().free(json_data);

        const result = self.sendRequest(arena.allocator(), json_data) catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_trace_network",
                .error_type = .network,
                .message = "OTLP trace network request failed",
                .context = self.config.endpoint,
                .source_error = err,
            });
            return .failure;
        };

        return result;
    }

    pub fn forceFlush(self: *OtlpTraceExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        // For HTTP transport, no persistent connection to flush
        return .success;
    }

    pub fn shutdown(self: *OtlpTraceExporter, timeout_ms: ?u64) ExportResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;
        _ = timeout_ms;

        return .success;
    }

    pub fn spanExporter(self: *OtlpTraceExporter) SpanExporter {
        return SpanExporter{ .bridge = otel_sdk.trace.BridgeSpanExporter.init(self) };
    }

    fn sendRequest(self: *OtlpTraceExporter, allocator: std.mem.Allocator, data: []const u8) !ExportResult {
        // Create stack-based HTTP client
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Parse endpoint URL with detailed error context
        const uri = std.Uri.parse(self.config.endpoint) catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_url_parsing",
                .error_type = .configuration,
                .message = "OTLP URL parsing failed",
                .context = self.config.endpoint,
                .source_error = err,
            });
            return err;
        };

        // Build full URL with traces path
        const host_str = switch (uri.host.?) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        const scheme_str = if (uri.scheme.len > 0) uri.scheme else "http";
        const full_url = try std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ scheme_str, host_str, uri.port orelse 4318, self.config.protocol_config.traces_path });
        defer allocator.free(full_url);

        // Create HTTP request
        const full_uri = try std.Uri.parse(full_url);
        var server_header_buffer: [8192]u8 = undefined;
        var req = try client.open(.POST, full_uri, .{
            .server_header_buffer = &server_header_buffer,
        });
        defer req.deinit();

        // Set request headers
        req.headers.content_type = .{ .override = "application/json" };
        req.transfer_encoding = .{ .content_length = @intCast(data.len) };

        // Add custom headers from config
        if (self.config.headers.len > 0) {
            var extra_headers = try allocator.alloc(std.http.Header, self.config.headers.len);
            for (self.config.headers, 0..) |header, h| {
                extra_headers[h] = header;
            }
            req.extra_headers = extra_headers;
        }

        // Send request
        try req.send();
        try req.writeAll(data);
        try req.finish();
        try req.wait();

        // Check response status
        switch (req.response.status) {
            .ok => return .success,
            .bad_request, .unauthorized, .forbidden, .not_found => {
                error_handler.reportError(.{
                    .component = .exporter,
                    .operation = "otlp_trace_response",
                    .error_type = .authentication,
                    .message = "OTLP trace export failed with HTTP error",
                    .context = self.config.endpoint,
                });
                return .failure;
            },
            else => {
                return .failure;
            },
        }
    }
};

/// Convert RecordingSpans to OTLP format JSON
fn convertToOtlpFormat(allocator: std.mem.Allocator, spans: []const *RecordingSpan, resource: Resource) ![]u8 {
    // Group spans by instrumentation scope
    var scope_map = std.StringHashMap(std.ArrayList(*const RecordingSpan)).init(allocator);
    defer {
        var iterator = scope_map.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit();
        }
        scope_map.deinit();
    }

    // For now, use a default scope since we don't have instrumentation scope in RecordingSpan
    const default_scope_name = "otel-zig-sdk";
    var span_list = try std.ArrayList(*const RecordingSpan).initCapacity(allocator, spans.len);
    try span_list.appendSlice(spans);
    try scope_map.put(default_scope_name, span_list);

    // Convert to OTLP format
    var scope_spans_list = std.ArrayList(OtlpScopeSpans).init(allocator);
    defer scope_spans_list.deinit();

    var scope_iterator = scope_map.iterator();
    while (scope_iterator.next()) |entry| {
        const scope_spans = entry.value_ptr.items;

        // Convert spans for this scope
        var otlp_spans = try allocator.alloc(OtlpSpan, scope_spans.len);
        for (scope_spans, 0..) |span, i| {
            otlp_spans[i] = try convertSpan(allocator, span);
        }

        // Use default instrumentation scope
        const scope = OtlpInstrumentationScope{
            .name = default_scope_name,
            .version = null,
        };

        try scope_spans_list.append(OtlpScopeSpans{
            .scope = scope,
            .spans = otlp_spans,
        });
    }

    // Convert resource
    var resource_attributes = try allocator.alloc(OtlpKeyValue, resource.attributes.len);
    for (resource.attributes, 0..) |attr, i| {
        resource_attributes[i] = OtlpKeyValue{
            .key = attr.key,
            .value = convertAttributeValue(attr.value),
        };
    }

    const otlp_resource = OtlpResource{
        .attributes = resource_attributes,
    };

    const resource_spans = OtlpResourceSpans{
        .resource = otlp_resource,
        .scopeSpans = scope_spans_list.items,
    };

    var resource_spans_array = try allocator.alloc(OtlpResourceSpans, 1);
    resource_spans_array[0] = resource_spans;

    const traces_data = OtlpTracesData{
        .resourceSpans = resource_spans_array,
    };

    // Serialize to JSON
    var json_buffer = std.ArrayList(u8).init(allocator);
    defer json_buffer.deinit();

    try std.json.stringify(traces_data, .{}, json_buffer.writer());
    return json_buffer.toOwnedSlice();
}

fn convertSpan(allocator: std.mem.Allocator, span: *const RecordingSpan) !OtlpSpan {
    // Convert trace and span IDs to hex strings
    var trace_id_hex: [32]u8 = undefined;
    var span_id_hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&trace_id_hex, "{}", .{std.fmt.fmtSliceHexLower(&span.span_context.trace_id.bytes)}) catch unreachable;
    _ = std.fmt.bufPrint(&span_id_hex, "{}", .{std.fmt.fmtSliceHexLower(&span.span_context.span_id.bytes)}) catch unreachable;

    // Handle parent span ID
    var parent_span_id_hex: ?[]const u8 = null;
    if (span.parent_span_context) |parent| {
        if (!std.mem.eql(u8, &parent.span_id.bytes, &[_]u8{0} ** 8)) {
            var parent_hex: [16]u8 = undefined;
            _ = std.fmt.bufPrint(&parent_hex, "{}", .{std.fmt.fmtSliceHexLower(&parent.span_id.bytes)}) catch unreachable;
            parent_span_id_hex = try allocator.dupe(u8, &parent_hex);
        }
    }

    // Convert attributes
    var attributes: []OtlpKeyValue = undefined;
    if (span.attributes) |attributes_list| {
        attributes = try allocator.alloc(OtlpKeyValue, attributes_list.items.len);
        for (attributes_list.items, 0..) |attr, i| {
            attributes[i] = OtlpKeyValue{
                .key = attr.key,
                .value = convertAttributeValue(attr.value),
            };
        }
    } else {
        attributes = try allocator.alloc(OtlpKeyValue, 0);
    }

    // Convert events
    var events: []OtlpEvent = undefined;
    if (span.events) |events_list| {
        events = try allocator.alloc(OtlpEvent, events_list.items.len);
        for (events_list.items, 0..) |event, i| {
            var event_attributes: []OtlpKeyValue = undefined;
            if (event.attributes) |attrs| {
                event_attributes = try allocator.alloc(OtlpKeyValue, attrs.len);
                for (attrs, 0..) |attr, j| {
                    event_attributes[j] = OtlpKeyValue{
                        .key = attr.key,
                        .value = convertAttributeValue(attr.value),
                    };
                }
            } else {
                event_attributes = try allocator.alloc(OtlpKeyValue, 0);
            }

            events[i] = OtlpEvent{
                .timeUnixNano = @as(u64, @intCast(event.timestamp_ns)),
                .name = event.name,
                .attributes = event_attributes,
            };
        }
    } else {
        events = try allocator.alloc(OtlpEvent, 0);
    }

    // Convert links
    var links: []OtlpLink = undefined;
    if (span.links) |links_list| {
        links = try allocator.alloc(OtlpLink, links_list.items.len);
        for (links_list.items, 0..) |link, i| {
            var link_trace_id_hex: [32]u8 = undefined;
            var link_span_id_hex: [16]u8 = undefined;
            _ = std.fmt.bufPrint(&link_trace_id_hex, "{}", .{std.fmt.fmtSliceHexLower(&link.span_context.trace_id.bytes)}) catch unreachable;
            _ = std.fmt.bufPrint(&link_span_id_hex, "{}", .{std.fmt.fmtSliceHexLower(&link.span_context.span_id.bytes)}) catch unreachable;

            var link_attributes: []OtlpKeyValue = undefined;
            if (link.attributes) |attrs| {
                link_attributes = try allocator.alloc(OtlpKeyValue, attrs.len);
                for (attrs, 0..) |attr, j| {
                    link_attributes[j] = OtlpKeyValue{
                        .key = attr.key,
                        .value = convertAttributeValue(attr.value),
                    };
                }
            } else {
                link_attributes = try allocator.alloc(OtlpKeyValue, 0);
            }

            links[i] = OtlpLink{
                .traceId = try allocator.dupe(u8, &link_trace_id_hex),
                .spanId = try allocator.dupe(u8, &link_span_id_hex),
                .attributes = link_attributes,
            };
        }
    } else {
        links = try allocator.alloc(OtlpLink, 0);
    }

    // Convert status
    const status = OtlpStatus{
        .code = @intFromEnum(span.status.code),
        .message = if (span.status.description) |desc| if (desc.len > 0) desc else null else null,
    };

    return OtlpSpan{
        .traceId = try allocator.dupe(u8, &trace_id_hex),
        .spanId = try allocator.dupe(u8, &span_id_hex),
        .parentSpanId = parent_span_id_hex,
        .name = span.name,
        .kind = @intFromEnum(span.kind),
        .startTimeUnixNano = @as(u64, @intCast(span.start_time)),
        .endTimeUnixNano = @as(u64, @intCast(span.end_time orelse 0)),
        .attributes = attributes,
        .events = events,
        .links = links,
        .status = status,
        .droppedAttributesCount = span.dropped_attributes_count,
        .droppedEventsCount = span.dropped_events_count,
        .droppedLinksCount = span.dropped_links_count,
    };
}

fn convertAttributeValue(value: otel_api.common.AttributeValue) OtlpAnyValue {
    return switch (value) {
        .string => |s| OtlpAnyValue{ .stringValue = s },
        .bool => |b| OtlpAnyValue{ .boolValue = b },
        .int => |i| OtlpAnyValue{ .intValue = i },
        .float => |f| OtlpAnyValue{ .doubleValue = f },
        .string_array => |arr| OtlpAnyValue{ .stringValue = std.fmt.allocPrint(std.heap.page_allocator, "{any}", .{arr}) catch "[]" },
        .bool_array => |arr| OtlpAnyValue{ .stringValue = std.fmt.allocPrint(std.heap.page_allocator, "{any}", .{arr}) catch "[]" },
        .int_array => |arr| OtlpAnyValue{ .stringValue = std.fmt.allocPrint(std.heap.page_allocator, "{any}", .{arr}) catch "[]" },
        .float_array => |arr| OtlpAnyValue{ .stringValue = std.fmt.allocPrint(std.heap.page_allocator, "{any}", .{arr}) catch "[]" },
    };
}

/// Create an OTLP trace exporter with default configuration
pub fn createTraceExporter(allocator: std.mem.Allocator) !SpanExporter {
    const exporter = try allocator.create(OtlpTraceExporter);
    errdefer allocator.destroy(exporter);
    exporter.* = OtlpTraceExporter.init(allocator, .{});
    return exporter.spanExporter();
}

/// Create an OTLP trace exporter with custom configuration
pub fn createTraceExporterWithConfig(config: OtlpExporterConfig, allocator: std.mem.Allocator) !SpanExporter {
    const exporter = try allocator.create(OtlpTraceExporter);
    errdefer allocator.destroy(exporter);
    exporter.* = OtlpTraceExporter.init(allocator, config);
    return exporter.spanExporter();
}

test "OtlpTraceExporter basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var exporter = OtlpTraceExporter.init(allocator, .{});
    defer exporter.deinit();

    const result = exporter.forceFlush(5000);
    try testing.expectEqual(ExportResult.success, result);

    const shutdown_result = exporter.shutdown(5000);
    try testing.expectEqual(ExportResult.success, shutdown_result);
}
