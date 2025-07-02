//! OpenTelemetry Console Trace Exporter
//!
//! This module provides a console exporter for trace spans that writes
//! JSON-formatted span output to stdout or stderr. The JSON format
//! follows the OpenTelemetry protocol buffer JSON representation.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const protobuf = @import("protobuf");

const ExportResult = otel_api.common.ExportResult;
const ConsoleExporterConfig = @import("root.zig").ConsoleExporterConfig;
const SpanExporter = otel_sdk.trace.SpanExporter;
const RecordingSpan = otel_sdk.trace.RecordingSpan;
const Resource = otel_sdk.resource.Resource;
const SpanContext = otel_api.trace.SpanContext;

// Import error handler for structured error reporting
const error_handler = otel_api.common;

// Import protobuf definitions
const trace_v1 = @import("../otlp/proto/opentelemetry/proto/trace/v1.pb.zig");
const common_v1 = @import("../otlp/proto/opentelemetry/proto/common/v1.pb.zig");
const resource_v1 = @import("../otlp/proto/opentelemetry/proto/resource/v1.pb.zig");

// Custom JSON serialization helpers for OTLP protobuf structures
const JsonError = std.json.WriteStream(std.ArrayList(u8).Writer, .assumed_correct).Error;

/// Console trace exporter implementation
pub const ConsoleTraceExporter = struct {
    pub const PipelineStep = otel_sdk.common.PipelineStepInstructions(
        Self,
        SpanExporter,
        ConsoleExporterConfig,
        spanExporter,
        _init,
        otel_sdk.common.PipelineDeinitConnection,
    );
    const Self = @This();

    pub fn _init(self: *Self, ctx: ConsoleExporterConfig, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, ctx);
    }

    allocator: std.mem.Allocator,
    config: ConsoleExporterConfig,
    writer: std.fs.File.Writer,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: ConsoleExporterConfig) ConsoleTraceExporter {
        const file = if (config.use_stderr) std.io.getStdErr() else std.io.getStdOut();
        return .{
            .allocator = allocator,
            .config = config,
            .writer = file.writer(),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ConsoleTraceExporter) void {
        _ = self;
        // No cleanup needed for console output
    }

    pub fn destroy(self: *ConsoleTraceExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportSpans(self: *ConsoleTraceExporter, spans: []const *RecordingSpan, resource: Resource) ExportResult {
        if (spans.len == 0) return .success;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Convert spans to OTLP format and serialize to JSON
        const result = self.exportSpansInternal(spans, resource) catch |err| {
            const first_span_name = if (spans.len > 0) spans[0].name else "(no spans)";
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "console_trace_export",
                .error_type = .serialization,
                .message = "Failed to export spans to console",
                .context = first_span_name,
                .source_error = err,
            });
            return .failure;
        };
        return result;
    }

    fn exportSpansInternal(self: *ConsoleTraceExporter, spans: []const *RecordingSpan, resource: Resource) !ExportResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Create OTLP TracesData
        var traces_data = trace_v1.TracesData.init(arena_allocator);

        // Group spans by instrumentation scope
        var scope_map = std.StringHashMap(std.ArrayList(*RecordingSpan)).init(arena_allocator);
        defer scope_map.deinit();

        // For now, we'll use a default scope since we don't have instrumentation scope in RecordingSpan
        const default_scope_name = "otel-zig-sdk";
        var span_list = try std.ArrayList(*RecordingSpan).initCapacity(arena_allocator, spans.len);
        try span_list.appendSlice(spans);
        try scope_map.put(default_scope_name, span_list);

        // Create ResourceSpans
        var resource_spans = trace_v1.ResourceSpans.init(arena_allocator);

        // Convert resource
        var proto_resource = resource_v1.Resource.init(arena_allocator);
        for (resource.attributes) |attr| {
            var kv = common_v1.KeyValue.init(arena_allocator);
            kv.key = protobuf.ManagedString.managed(attr.key);
            kv.value = try convertAttributeValue(arena_allocator, attr.value);
            try proto_resource.attributes.append(kv);
        }
        resource_spans.resource = proto_resource;

        // Create ScopeSpans
        var scope_iter = scope_map.iterator();
        while (scope_iter.next()) |entry| {
            var scope_spans = trace_v1.ScopeSpans.init(arena_allocator);

            // Set instrumentation scope
            var scope = common_v1.InstrumentationScope.init(arena_allocator);
            scope.name = protobuf.ManagedString.managed(entry.key_ptr.*);
            scope_spans.scope = scope;

            // Convert spans
            for (entry.value_ptr.items) |span| {
                const proto_span = try convertSpan(arena_allocator, span);
                try scope_spans.spans.append(proto_span);
            }

            try resource_spans.scope_spans.append(scope_spans);
        }

        try traces_data.resource_spans.append(resource_spans);

        // Serialize to JSON
        var buffer = std.ArrayList(u8).init(arena_allocator);
        try writeTracesData(buffer.writer(), traces_data);
        try self.writer.print("{s}\n", .{buffer.items});

        return .success;
    }

    pub fn forceFlush(self: *ConsoleTraceExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        return .success;
    }

    pub fn shutdown(self: *ConsoleTraceExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        return .success;
    }

    pub fn spanExporter(self: *ConsoleTraceExporter) SpanExporter {
        return SpanExporter{ .bridge = otel_sdk.trace.BridgeSpanExporter.init(self) };
    }
};

fn convertSpan(allocator: std.mem.Allocator, span: *RecordingSpan) !trace_v1.Span {
    var proto_span = trace_v1.Span.init(allocator);

    // Convert IDs
    proto_span.trace_id = protobuf.ManagedString.managed(&span.span_context.trace_id.bytes);
    proto_span.span_id = protobuf.ManagedString.managed(&span.span_context.span_id.bytes);

    // Set parent span ID if present
    if (span.parent_span_context) |parent| {
        proto_span.parent_span_id = protobuf.ManagedString.managed(&parent.span_id.bytes);
    }

    // Set span name
    proto_span.name = protobuf.ManagedString.managed(span.name);

    // Convert span kind
    proto_span.kind = switch (span.kind) {
        .internal => .SPAN_KIND_INTERNAL,
        .server => .SPAN_KIND_SERVER,
        .client => .SPAN_KIND_CLIENT,
        .producer => .SPAN_KIND_PRODUCER,
        .consumer => .SPAN_KIND_CONSUMER,
    };

    // Set timestamps
    proto_span.start_time_unix_nano = @intCast(span.start_time);
    proto_span.end_time_unix_nano = @intCast(span.end_time orelse 0);

    // Set trace flags
    proto_span.flags = span.span_context.trace_flags & SpanContext.SAMPLED_FLAG;

    // Convert attributes
    if (span.attributes) |attrs| {
        for (attrs.items) |attr| {
            var kv = common_v1.KeyValue.init(allocator);
            kv.key = protobuf.ManagedString.managed(attr.key);
            kv.value = try convertAttributeValue(allocator, attr.value);
            try proto_span.attributes.append(kv);
        }
    }

    // Convert events
    if (span.events) |events| {
        for (events.items) |event| {
            var proto_event = trace_v1.Span.Event.init(allocator);
            proto_event.time_unix_nano = @intCast(event.timestamp_ns);
            proto_event.name = protobuf.ManagedString.managed(event.name);

            if (event.attributes) |attrs| {
                for (attrs) |attr| {
                    var kv = common_v1.KeyValue.init(allocator);
                    kv.key = protobuf.ManagedString.managed(attr.key);
                    kv.value = try convertAttributeValue(allocator, attr.value);
                    try proto_event.attributes.append(kv);
                }
            }

            try proto_span.events.append(proto_event);
        }
    }

    // Convert links
    if (span.links) |links| {
        for (links.items) |link| {
            var proto_link = trace_v1.Span.Link.init(allocator);
            proto_link.trace_id = protobuf.ManagedString.managed(&link.span_context.trace_id.bytes);
            proto_link.span_id = protobuf.ManagedString.managed(&link.span_context.span_id.bytes);

            if (link.attributes) |attrs| {
                for (attrs) |attr| {
                    var kv = common_v1.KeyValue.init(allocator);
                    kv.key = protobuf.ManagedString.managed(attr.key);
                    kv.value = try convertAttributeValue(allocator, attr.value);
                    try proto_link.attributes.append(kv);
                }
            }

            try proto_span.links.append(proto_link);
        }
    }

    // Convert status
    if (span.status.code != .unset) {
        var proto_status = trace_v1.Status.init(allocator);
        proto_status.code = switch (span.status.code) {
            .unset => .STATUS_CODE_UNSET,
            .ok => .STATUS_CODE_OK,
            .@"error" => .STATUS_CODE_ERROR,
        };
        if (span.status.description) |desc| {
            proto_status.message = protobuf.ManagedString.managed(desc);
        }
        proto_span.status = proto_status;
    }

    return proto_span;
}

fn convertAttributeValue(allocator: std.mem.Allocator, value: otel_api.common.AttributeValue) !common_v1.AnyValue {
    var any_value = common_v1.AnyValue.init(allocator);

    switch (value) {
        .string => |s| {
            any_value.value = .{ .string_value = protobuf.ManagedString.managed(s) };
        },
        .bool => |b| {
            any_value.value = .{ .bool_value = b };
        },
        .int => |i| {
            any_value.value = .{ .int_value = i };
        },
        .float => |f| {
            any_value.value = .{ .double_value = f };
        },
        .string_array => |arr| {
            var array_value = common_v1.ArrayValue.init(allocator);
            for (arr) |s| {
                var elem = common_v1.AnyValue.init(allocator);
                elem.value = .{ .string_value = protobuf.ManagedString.managed(s) };
                try array_value.values.append(elem);
            }
            any_value.value = .{ .array_value = array_value };
        },
        .bool_array => |arr| {
            var array_value = common_v1.ArrayValue.init(allocator);
            for (arr) |b| {
                var elem = common_v1.AnyValue.init(allocator);
                elem.value = .{ .bool_value = b };
                try array_value.values.append(elem);
            }
            any_value.value = .{ .array_value = array_value };
        },
        .int_array => |arr| {
            var array_value = common_v1.ArrayValue.init(allocator);
            for (arr) |i| {
                var elem = common_v1.AnyValue.init(allocator);
                elem.value = .{ .int_value = i };
                try array_value.values.append(elem);
            }
            any_value.value = .{ .array_value = array_value };
        },
        .float_array => |arr| {
            var array_value = common_v1.ArrayValue.init(allocator);
            for (arr) |f| {
                var elem = common_v1.AnyValue.init(allocator);
                elem.value = .{ .double_value = f };
                try array_value.values.append(elem);
            }
            any_value.value = .{ .array_value = array_value };
        },
    }

    return any_value;
}

// JSON serialization functions
fn writeTracesData(writer: anytype, data: trace_v1.TracesData) JsonError!void {
    var jw = std.json.writeStream(writer, .{});
    try jw.beginObject();
    try jw.objectField("resourceSpans");
    try jw.beginArray();
    for (data.resource_spans.items) |rs| {
        try writeResourceSpans(&jw, rs);
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeResourceSpans(jw: anytype, rs: trace_v1.ResourceSpans) JsonError!void {
    try jw.beginObject();

    if (rs.resource) |resource| {
        try jw.objectField("resource");
        try writeResource(jw, resource);
    }

    try jw.objectField("scopeSpans");
    try jw.beginArray();
    for (rs.scope_spans.items) |ss| {
        try writeScopeSpans(jw, ss);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeResource(jw: anytype, resource: resource_v1.Resource) JsonError!void {
    try jw.beginObject();

    try jw.objectField("attributes");
    try jw.beginArray();
    for (resource.attributes.items) |attr| {
        try writeKeyValue(jw, attr);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeScopeSpans(jw: anytype, ss: trace_v1.ScopeSpans) JsonError!void {
    try jw.beginObject();

    if (ss.scope) |scope| {
        try jw.objectField("scope");
        try writeInstrumentationScope(jw, scope);
    }

    try jw.objectField("spans");
    try jw.beginArray();
    for (ss.spans.items) |span| {
        try writeSpan(jw, span);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeInstrumentationScope(jw: anytype, scope: common_v1.InstrumentationScope) JsonError!void {
    try jw.beginObject();

    if (!scope.name.isEmpty()) {
        try jw.objectField("name");
        try jw.write(scope.name.getSlice());
    }

    if (!scope.version.isEmpty()) {
        try jw.objectField("version");
        try jw.write(scope.version.getSlice());
    }

    try jw.endObject();
}

fn writeSpan(jw: anytype, span: trace_v1.Span) JsonError!void {
    try jw.beginObject();

    // Write IDs as hex strings
    try jw.objectField("traceId");
    try writeHexBytes(jw, span.trace_id.getSlice());

    try jw.objectField("spanId");
    try writeHexBytes(jw, span.span_id.getSlice());

    if (!span.parent_span_id.isEmpty()) {
        try jw.objectField("parentSpanId");
        try writeHexBytes(jw, span.parent_span_id.getSlice());
    }

    try jw.objectField("name");
    try jw.write(span.name.getSlice());

    try jw.objectField("kind");
    try jw.write(@intFromEnum(span.kind));

    try jw.objectField("startTimeUnixNano");
    try jw.print("\"{d}\"", .{span.start_time_unix_nano});

    try jw.objectField("endTimeUnixNano");
    try jw.print("\"{d}\"", .{span.end_time_unix_nano});

    if (span.attributes.items.len > 0) {
        try jw.objectField("attributes");
        try jw.beginArray();
        for (span.attributes.items) |attr| {
            try writeKeyValue(jw, attr);
        }
        try jw.endArray();
    }

    if (span.events.items.len > 0) {
        try jw.objectField("events");
        try jw.beginArray();
        for (span.events.items) |event| {
            try writeEvent(jw, event);
        }
        try jw.endArray();
    }

    if (span.links.items.len > 0) {
        try jw.objectField("links");
        try jw.beginArray();
        for (span.links.items) |link| {
            try writeLink(jw, link);
        }
        try jw.endArray();
    }

    if (span.status) |status| {
        try jw.objectField("status");
        try writeStatus(jw, status);
    }

    if (span.flags != 0) {
        try jw.objectField("flags");
        try jw.write(span.flags);
    }

    try jw.endObject();
}

fn writeEvent(jw: anytype, event: trace_v1.Span.Event) JsonError!void {
    try jw.beginObject();

    try jw.objectField("timeUnixNano");
    try jw.print("\"{d}\"", .{event.time_unix_nano});

    try jw.objectField("name");
    try jw.write(event.name.getSlice());

    if (event.attributes.items.len > 0) {
        try jw.objectField("attributes");
        try jw.beginArray();
        for (event.attributes.items) |attr| {
            try writeKeyValue(jw, attr);
        }
        try jw.endArray();
    }

    try jw.endObject();
}

fn writeLink(jw: anytype, link: trace_v1.Span.Link) JsonError!void {
    try jw.beginObject();

    try jw.objectField("traceId");
    try writeHexBytes(jw, link.trace_id.getSlice());

    try jw.objectField("spanId");
    try writeHexBytes(jw, link.span_id.getSlice());

    if (link.attributes.items.len > 0) {
        try jw.objectField("attributes");
        try jw.beginArray();
        for (link.attributes.items) |attr| {
            try writeKeyValue(jw, attr);
        }
        try jw.endArray();
    }

    try jw.endObject();
}

fn writeStatus(jw: anytype, status: trace_v1.Status) JsonError!void {
    try jw.beginObject();

    try jw.objectField("code");
    try jw.write(@intFromEnum(status.code));

    if (!status.message.isEmpty()) {
        try jw.objectField("message");
        try jw.write(status.message.getSlice());
    }

    try jw.endObject();
}

fn writeKeyValue(jw: anytype, kv: common_v1.KeyValue) JsonError!void {
    try jw.beginObject();

    try jw.objectField("key");
    try jw.write(kv.key.getSlice());

    try jw.objectField("value");
    try writeAnyValue(jw, kv.value.?);

    try jw.endObject();
}

fn writeAnyValue(jw: anytype, value: common_v1.AnyValue) JsonError!void {
    try jw.beginObject();

    switch (value.value.?) {
        .string_value => |s| {
            try jw.objectField("stringValue");
            try jw.write(s.getSlice());
        },
        .bool_value => |b| {
            try jw.objectField("boolValue");
            try jw.write(b);
        },
        .int_value => |i| {
            try jw.objectField("intValue");
            try jw.print("\"{d}\"", .{i});
        },
        .double_value => |f| {
            try jw.objectField("doubleValue");
            try jw.write(f);
        },
        .array_value => |arr| {
            try jw.objectField("arrayValue");
            try jw.beginObject();
            try jw.objectField("values");
            try jw.beginArray();
            for (arr.values.items) |elem| {
                try writeAnyValue(jw, elem);
            }
            try jw.endArray();
            try jw.endObject();
        },
        .kvlist_value => |kvlist| {
            try jw.objectField("kvlistValue");
            try jw.beginObject();
            try jw.objectField("values");
            try jw.beginArray();
            for (kvlist.values.items) |kv| {
                try writeKeyValue(jw, kv);
            }
            try jw.endArray();
            try jw.endObject();
        },
        .bytes_value => |bytes| {
            try jw.objectField("bytesValue");
            // Base64 encode bytes
            const encoder = std.base64.standard.Encoder;
            const bytes_slice = bytes.getSlice();

            // Use a reasonable static buffer for base64 encoding
            // For typical attribute values, 1KB should be sufficient
            var encode_buf: [1024]u8 = undefined;
            const encoded_len = encoder.calcSize(bytes_slice.len);

            if (encoded_len > encode_buf.len) {
                // Fall back to writing empty string for oversized values
                try jw.write("");
            } else {
                const encoded = encoder.encode(&encode_buf, bytes_slice);
                try jw.write(encoded);
            }
        },
    }

    try jw.endObject();
}

fn writeHexBytes(jw: anytype, bytes: []const u8) JsonError!void {
    var hex_buf: [64]u8 = undefined; // Max 32 bytes = 64 hex chars
    const hex = std.fmt.bufPrint(&hex_buf, "{}", .{std.fmt.fmtSliceHexLower(bytes)}) catch unreachable;
    try jw.write(hex);
}

/// Create a console trace exporter with default configuration
pub fn createTraceExporter(allocator: std.mem.Allocator) !SpanExporter {
    const exporter = try allocator.create(ConsoleTraceExporter);
    errdefer allocator.destroy(exporter);
    exporter.* = ConsoleTraceExporter.init(allocator, .{});
    return exporter.spanExporter();
}

/// Create a console trace exporter with custom configuration
pub fn createTraceExporterWithConfig(config: ConsoleExporterConfig, allocator: std.mem.Allocator) !SpanExporter {
    const exporter = try allocator.create(ConsoleTraceExporter);
    errdefer allocator.destroy(exporter);
    exporter.* = ConsoleTraceExporter.init(allocator, config);
    return exporter.spanExporter();
}
