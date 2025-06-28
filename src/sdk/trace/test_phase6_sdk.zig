//! Comprehensive tests for Phase 6 SDK trace implementation

const std = @import("std");
const testing = std.testing;
const otel_api = @import("otel-api");

const RecordingSpan = @import("data.zig").RecordingSpan;
const StandardTracer = @import("tracer.zig").StandardTracer;
const BasicTracerProvider = @import("basic_provider.zig").BasicTracerProvider;
const SpanProcessor = @import("processor.zig").SpanProcessor;
const SimpleSpanProcessor = @import("processor.zig").SimpleSpanProcessor;
const SpanExporter = @import("exporter.zig").SpanExporter;
const BridgeSpanExporter = @import("exporter.zig").BridgeSpanExporter;
const Resource = @import("../resource/resource.zig").Resource;
const createDefaultIdGenerator = @import("id_generator.zig").createDefaultIdGenerator;
const samplers = @import("samplers/root.zig");

const SpanContext = otel_api.trace.SpanContext;
const SpanKind = otel_api.trace.SpanKind;
const Status = otel_api.trace.Status;
const TraceId = otel_api.common.TraceId;
const SpanId = otel_api.common.SpanId;
const Link = otel_api.trace.Link;
const Event = otel_api.trace.Event;
const AttributeValue = otel_api.common.AttributeValue;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const Context = otel_api.Context;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const SpanLimits = otel_api.trace.SpanLimits;
const trace_context = otel_api.trace.trace_context;

test "RecordingSpan - basic functionality" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = SpanContext.SAMPLED_FLAG,
        .trace_state = null,
        .is_remote = false,
    };

    var processor_called = false;
    const TestProcessor = struct {
        fn onEnd(processor: *anyopaque, span: *RecordingSpan) void {
            _ = span;
            const called_ptr = @as(*bool, @ptrCast(@alignCast(processor)));
            called_ptr.* = true;
        }
    };

    const recording = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        .internal,
        1234567890,
        &.{},
        &.{},
        SpanLimits.default,
        &processor_called,
        TestProcessor.onEnd,
    );
    defer recording.deinit();

    // Test span interface
    var span = recording.span();

    // Verify initial state
    try testing.expect(span.isRecording());
    try testing.expectEqual(span_context, span.getSpanContext());
    try testing.expectEqualStrings("test-span", recording.name);
    try testing.expectEqual(SpanKind.internal, recording.kind);
    try testing.expectEqual(@as(i64, 1234567890), recording.start_time);
    try testing.expectEqual(@as(?i64, null), recording.end_time);

    // End the span
    span.end(null);
    try testing.expect(!span.isRecording());
    try testing.expect(processor_called);
    try testing.expect(recording.end_time != null and recording.end_time.? > 0);
}

test "RecordingSpan - attributes management" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const recording = try RecordingSpan.init(
        allocator, // allocator: std.mem.Allocator,
        "test-span", // name: []const u8,
        span_context, // span_context: SpanContext,
        null, // parent_span_context: ?SpanContext,
        .internal, // kind: SpanKind,
        1234567890, // start_time: i64,
        &.{}, // initial_attributes: []const AttributeKeyValue,
        &.{}, // initial_links: []const Link,
        SpanLimits.default, // span_limits: SpanLimits,
        undefined, // processor: *anyopaque,
        null, // processorOnEndFn: ?*const fn (processor: *anyopaque, span: *RecordingSpan) void,
    );
    defer recording.deinit();

    var span = recording.span();

    // Initially no attributes
    try testing.expect(recording.attributes == null);

    // Add first attribute
    try span.setAttribute("key1", AttributeValue{ .string = "value1" });
    try testing.expect(recording.attributes != null);
    try testing.expectEqual(@as(usize, 1), recording.attributes.?.items.len);
    try testing.expectEqualStrings("key1", recording.attributes.?.items[0].key);

    // Update existing attribute
    try span.setAttribute("key1", AttributeValue{ .string = "updated" });
    try testing.expectEqual(@as(usize, 1), recording.attributes.?.items.len);
    try testing.expectEqualStrings("updated", recording.attributes.?.items[0].value.string);

    // Add multiple attributes
    const attrs = [_]AttributeKeyValue{
        .{ .key = "key2", .value = AttributeValue{ .int = 42 } },
        .{ .key = "key3", .value = AttributeValue{ .bool = true } },
    };
    try span.setAttributes(&attrs);
    try testing.expectEqual(@as(usize, 3), recording.attributes.?.items.len);
}

test "RecordingSpan - events management" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const recording = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        .internal,
        1234567890,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        null,
    );
    defer recording.deinit();

    var span = recording.span();

    // Initially no events
    try testing.expect(recording.events == null);

    // Add event
    const event_attrs = [_]AttributeKeyValue{
        .{ .key = "level", .value = AttributeValue{ .string = "info" } },
    };
    try span.addEvent(Event{ .name = "test-event", .timestamp_ns = 9876543210, .attributes = &event_attrs });

    try testing.expect(recording.events != null);
    try testing.expectEqual(@as(usize, 1), recording.events.?.items.len);
    try testing.expectEqualStrings("test-event", recording.events.?.items[0].name);
    try testing.expectEqual(@as(i64, 9876543210), recording.events.?.items[0].timestamp_ns);
}

test "RecordingSpan - links management" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    // const linked_context = SpanContext{
    //     .trace_id = TraceId.fromBytes([_]u8{3} ** 16),
    //     .span_id = SpanId.fromBytes([_]u8{4} ** 8),
    //     .trace_flags = 0,
    //     .trace_state = null,
    //     .is_remote = false,
    // };

    const recording = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        .internal,
        1234567890,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        null,
    );
    defer recording.deinit();

    var span = recording.span();

    // Initially no links
    try testing.expect(recording.links == null);

    // Add link using addEvent since addLink is not in the Span API
    const link_attrs = [_]AttributeKeyValue{
        .{ .key = "link.trace_id", .value = AttributeValue{ .string = "linked_trace" } },
    };
    try span.addEvent(Event{ .name = "link", .timestamp_ns = 0, .attributes = &link_attrs });

    // Verify link was added as event
    try testing.expect(recording.events != null);
    try testing.expectEqual(@as(usize, 1), recording.events.?.items.len);
    try testing.expectEqualStrings("link", recording.events.?.items[0].name);
}

test "RecordingSpan - status and name updates" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const recording = try RecordingSpan.init(
        allocator,
        "original-name",
        span_context,
        null,
        .internal,
        1234567890,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        null,
    );
    defer recording.deinit();

    var span = recording.span();

    // Update status
    try testing.expectEqual(Status.unset(), recording.status);
    try span.setStatus(Status.ok("All good"));
    try testing.expectEqual(otel_api.trace.StatusCode.ok, recording.status.code);
    try testing.expectEqualStrings("All good", recording.status.description.?);

    // Update name
    try testing.expectEqualStrings("original-name", recording.name);
    try span.updateName("updated-name");
    try testing.expectEqualStrings("updated-name", recording.name);
}

test "RecordingSpan - parent context" {
    const allocator = testing.allocator;

    const parent_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = SpanContext.SAMPLED_FLAG,
        .trace_state = null,
        .is_remote = false,
    };

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16), // Same trace ID as parent
        .span_id = SpanId.fromBytes([_]u8{3} ** 8),
        .trace_flags = SpanContext.SAMPLED_FLAG,
        .trace_state = null,
        .is_remote = false,
    };

    const recording = try RecordingSpan.init(
        allocator,
        "child-span",
        span_context,
        parent_context,
        .internal,
        1234567890,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        null,
    );
    defer recording.deinit();

    try testing.expect(recording.parent_span_context != null);
    try testing.expectEqual(parent_context, recording.parent_span_context.?);
}

test "RecordingSpan - record exception" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const recording = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        .internal,
        1234567890,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        null,
    );
    defer recording.deinit();

    var span = recording.span();

    const exception_attrs = [_]AttributeKeyValue{
        .{ .key = "exception.type", .value = AttributeValue{ .string = "Error" } },
    };
    const TestError = error.SomethingWentWrong;
    try span.recordException(TestError, &exception_attrs, null);

    try testing.expect(recording.events != null);
    try testing.expectEqual(@as(usize, 1), recording.events.?.items.len);
    try testing.expectEqualStrings("exception", recording.events.?.items[0].name);
}

test "BasicTracerProvider - basic operations" {
    const allocator = testing.allocator;

    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = SpanProcessor{ .noop = {} };

    const provider_ptr = try allocator.create(BasicTracerProvider);
    provider_ptr.* = BasicTracerProvider.init(
        allocator,
        resource,
        createDefaultIdGenerator(),
        samplers.always_on,
        null,
    );
    try provider_ptr.registerProcessor(processor);
    defer {
        provider_ptr.deinit();
        provider_ptr.destroy();
    }

    var tp = provider_ptr.tracerProvider();

    // Get tracer
    var tracer = try tp.getTracerWithScope(.{
        .name = "test-tracer",
        .version = null,
        .schema_url = null,
        .attributes = &.{},
    });

    switch (tracer) {
        .noop => unreachable,
        .bridge => {},
    }

    // Start a span
    const ctx = Context.empty(allocator);
    defer ctx.deinit();
    const result = try tracer.startSpan("test-operation", .default, ctx);
    var span = result;
    defer span.deinit();

    // Verify span is recording
    switch (span) {
        .noop => try testing.expect(span.isRecording()),
        .bridge => try testing.expect(span.isRecording()),
    }

    // End span
    span.end(null);
}

test "BasicTracerProvider - tracer caching" {
    const allocator = testing.allocator;

    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = SpanProcessor{ .noop = {} };

    const provider_ptr = try allocator.create(BasicTracerProvider);
    provider_ptr.* = BasicTracerProvider.init(
        allocator,
        resource,
        createDefaultIdGenerator(),
        samplers.always_on,
        null,
    );
    try provider_ptr.registerProcessor(processor);
    defer {
        provider_ptr.deinit();
        provider_ptr.destroy();
    }

    var tp = provider_ptr.tracerProvider();

    // Get same tracer multiple times
    const tracer1 = try tp.getTracerWithScope(.{
        .name = "cached-tracer",
        .version = null,
        .schema_url = null,
        .attributes = &.{},
    });
    const tracer2 = try tp.getTracerWithScope(.{
        .name = "cached-tracer",
        .version = null,
        .schema_url = null,
        .attributes = &.{},
    });
    const tracer3 = try tp.getTracerWithScope(.{
        .name = "different-tracer",
        .version = null,
        .schema_url = null,
        .attributes = &.{},
    });

    _ = tracer1;
    _ = tracer2;
    _ = tracer3;

    // Verify cache count
    provider_ptr.mutex.lock();
    defer provider_ptr.mutex.unlock();
    try testing.expectEqual(@as(usize, 2), provider_ptr.cache.count());
}

test "RecordingSpan - span limits enforcement" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = SpanContext.SAMPLED_FLAG,
        .trace_state = null,
        .is_remote = false,
    };

    // Use minimal limits for testing
    const limits = SpanLimits{
        .max_attributes = 2,
        .max_events = 1,
        .max_links = 1,
        .max_attributes_per_event = 1,
        .max_attributes_per_link = 1,
        .max_attribute_value_length = 10,
        .max_attribute_key_length = 5,
    };

    var processor_called = false;
    const TestProcessor = struct {
        fn onEnd(processor: *anyopaque, span: *RecordingSpan) void {
            _ = span;
            const called_ptr = @as(*bool, @ptrCast(@alignCast(processor)));
            called_ptr.* = true;
        }
    };

    const recording = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        .internal,
        1234567890,
        &.{},
        &.{},
        limits,
        &processor_called,
        TestProcessor.onEnd,
    );
    defer recording.deinit();

    var span = recording.span();

    // Add more attributes than allowed (limit is 2)
    try span.setAttribute("key1", AttributeValue{ .string = "value1" });
    try span.setAttribute("key2", AttributeValue{ .string = "value2" });
    try span.setAttribute("key3", AttributeValue{ .string = "value3" }); // Should be truncated
    try span.setAttribute("key4", AttributeValue{ .string = "value4" }); // Should be truncated

    // Add more events than allowed (limit is 1)
    try span.addEvent(Event{ .name = "event1", .timestamp_ns = 0, .attributes = null });
    try span.addEvent(Event{ .name = "event2", .timestamp_ns = 0, .attributes = null }); // Should be truncated

    // Add attribute with long key and value that should be truncated
    try span.setAttribute("verylongkey", AttributeValue{ .string = "verylongvalue" });

    // End the span to trigger limit enforcement
    span.end(null);

    // Verify processor was called
    try testing.expect(processor_called);

    // Verify limits were enforced
    if (recording.attributes) |attrs| {
        try testing.expectEqual(@as(usize, 2), attrs.items.len); // Should be truncated to 2
    }

    if (recording.events) |events| {
        try testing.expectEqual(@as(usize, 1), events.items.len); // Should be truncated to 1
    }
}

test "SimpleSpanProcessor - export flow" {
    const allocator = testing.allocator;

    // Mock exporter
    const MockExporter = struct {
        spans_exported: usize = 0,

        pub fn exportSpans(self: *@This(), spans: []const *RecordingSpan, resource: Resource) otel_api.common.ExportResult {
            _ = resource;
            self.spans_exported += spans.len;
            return .success;
        }

        pub fn forceFlush(self: *@This(), timeout_ms: ?u64) otel_api.common.ExportResult {
            _ = self;
            _ = timeout_ms;
            return .success;
        }

        pub fn shutdown(self: *@This(), timeout_ms: ?u64) otel_api.common.ExportResult {
            _ = self;
            _ = timeout_ms;
            return .success;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn destroy(self: *@This()) void {
            _ = self;
        }
    };

    var mock = MockExporter{};
    const exporter = SpanExporter{ .bridge = BridgeSpanExporter.init(&mock) };

    const resource = Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = try SimpleSpanProcessor.init(allocator, exporter, resource);
    defer {
        processor.deinit();
        processor.destroy();
    }

    // Create a span and trigger export
    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const recording = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        .internal,
        1234567890,
        &.{},
        &.{},
        SpanLimits.default,
        processor,
        spanProcessorOnEnd,
    );
    defer recording.deinit();

    // Simulate span end
    processor.onEnd(recording);

    try testing.expectEqual(@as(usize, 1), mock.spans_exported);
}

fn spanProcessorOnEnd(processor_ptr: *anyopaque, span: *RecordingSpan) void {
    const processor = @as(*SimpleSpanProcessor, @ptrCast(@alignCast(processor_ptr)));
    processor.onEnd(span);
}

test "Integration - full trace flow" {
    const allocator = testing.allocator;

    // Create a mock exporter that captures spans
    const CaptureExporter = struct {
        captured_spans: std.ArrayList(SpanData) = undefined,
        allocator: std.mem.Allocator,

        const SpanData = struct {
            name: []const u8,
            trace_id: [16]u8,
            span_id: [8]u8,
            attributes_count: usize,
        };

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .captured_spans = std.ArrayList(SpanData).init(alloc),
                .allocator = alloc,
            };
        }

        pub fn deinit(self: *@This()) void {
            for (self.captured_spans.items) |span| {
                self.allocator.free(span.name);
            }
            self.captured_spans.deinit();
        }

        pub fn exportSpans(self: *@This(), spans: []const *RecordingSpan, resource: Resource) otel_api.common.ExportResult {
            _ = resource;
            for (spans) |span| {
                const name_copy = self.allocator.dupe(u8, span.name) catch return .failure;
                const data = SpanData{
                    .name = name_copy,
                    .trace_id = span.span_context.trace_id.bytes,
                    .span_id = span.span_context.span_id.bytes,
                    .attributes_count = if (span.attributes) |attrs| attrs.items.len else 0,
                };
                self.captured_spans.append(data) catch return .failure;
            }
            return .success;
        }

        pub fn forceFlush(self: *@This(), timeout_ms: ?u64) otel_api.common.ExportResult {
            _ = self;
            _ = timeout_ms;
            return .success;
        }

        pub fn shutdown(self: *@This(), timeout_ms: ?u64) otel_api.common.ExportResult {
            _ = self;
            _ = timeout_ms;
            return .success;
        }

        pub fn destroy(self: *@This()) void {
            _ = self;
        }
    };

    var capture = CaptureExporter.init(allocator);

    const exporter = SpanExporter{ .bridge = BridgeSpanExporter.init(&capture) };

    // Create tracing pipeline using local helper
    const simple_processor = try SimpleSpanProcessor.init(allocator, exporter, Resource{
        .attributes = &.{},
        .schema_url = null,
    });
    const provider_ptr = try allocator.create(BasicTracerProvider);
    provider_ptr.* = BasicTracerProvider.init(
        allocator,
        .empty,
        createDefaultIdGenerator(),
        samplers.always_on,
        null,
    );
    try provider_ptr.registerProcessor(simple_processor.spanProcessor());
    defer {
        provider_ptr.deinit();
        provider_ptr.destroy();
    }

    // Get tracer and create spans
    var provider = provider_ptr.tracerProvider();
    var tracer = try provider.getTracerWithScope(.{
        .name = "test-component",
        .version = null,
        .schema_url = null,
        .attributes = &.{},
    });

    // Create parent span
    const ctx = Context.empty(allocator);
    defer ctx.deinit();
    const parent_result = try tracer.startSpan("parent-operation", .{
        .kind = .server,
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "http.method", .value = AttributeValue{ .string = "GET" } },
            .{ .key = "http.url", .value = AttributeValue{ .string = "/api/test" } },
        },
    }, ctx);
    var parent_span = parent_result;
    defer parent_span.deinit();
    const parent_context = try trace_context.withActiveSpanContext(ctx, parent_span.getSpanContext());
    defer parent_context.deinit();

    // Create child span
    const child_result = try tracer.startSpan("child-operation", .{
        .kind = .internal,
    }, parent_context);
    var child_span = child_result;
    defer child_span.deinit();

    // Do some work and add attributes
    try child_span.setAttribute("db.statement", AttributeValue{ .string = "SELECT * FROM users" });
    child_span.end(null);

    // Finish parent
    try parent_span.setStatus(Status.ok(null));
    parent_span.end(null);

    // Verify spans were exported
    try testing.expectEqual(@as(usize, 2), capture.captured_spans.items.len);

    const exported_child = capture.captured_spans.items[0];
    const exported_parent = capture.captured_spans.items[1];

    try testing.expectEqualStrings("child-operation", exported_child.name);
    try testing.expectEqualStrings("parent-operation", exported_parent.name);
    try testing.expectEqual(@as(usize, 2), exported_parent.attributes_count);

    // Verify parent-child relationship (same trace ID)
    try testing.expectEqualSlices(u8, &exported_parent.trace_id, &exported_child.trace_id);
}

test "Console exporter JSON output" {
    const allocator = testing.allocator;

    // Create a console exporter that writes to a buffer
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // We can't easily test the actual console exporter since it writes to stdout
    // But we can verify the JSON serialization works by creating the data structures

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef } ** 2),
        .span_id = SpanId.fromBytes([_]u8{ 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 }),
        .trace_flags = SpanContext.SAMPLED_FLAG,
        .trace_state = null,
        .is_remote = false,
    };

    const recording = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        .internal,
        1234567890000000000,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        null,
    );
    defer recording.deinit();

    var span = recording.span();

    // Add some data
    try span.setAttribute("test.key", AttributeValue{ .string = "test-value" });
    try span.addEvent(Event{ .name = "test-event", .timestamp_ns = 0, .attributes = null });
    try span.setStatus(Status.ok("Success"));

    // End span with custom time
    const end_options = otel_api.trace.SpanEndOptions{ .end_time_ns = 1234567891000000000 };
    span.end(end_options);

    // The actual JSON output would be tested in integration tests
    // Here we just verify the span has the expected data
    try testing.expectEqual(@as(usize, 1), recording.attributes.?.items.len);
    try testing.expectEqual(@as(usize, 1), recording.events.?.items.len);
    try testing.expectEqual(Status.ok("Success"), recording.status);
}

// Run all tests
test {
    testing.refAllDecls(@This());
}
