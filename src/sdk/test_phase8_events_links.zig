//! Phase 8 Event/Link Implementation Tests
//!
//! Tests the enhanced Event and Link functionality including:
//! - New addEvent API with Event struct
//! - New addLink API with Link struct
//! - Event name validation
//! - Link span context validation
//! - Dropped count tracking
//! - Enhanced limits enforcement

const std = @import("std");
const testing = std.testing;
const otel_api = @import("otel-api");

// Import SDK components
const trace_sdk = @import("trace/root.zig");
const RecordingSpan = @import("trace/data.zig").RecordingSpan;

// API types
const Event = otel_api.trace.Event;
const Link = otel_api.trace.Link;
const SpanContext = otel_api.trace.SpanContext;
const SpanKind = otel_api.trace.SpanKind;
const Status = otel_api.trace.Status;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const AttributeValue = otel_api.common.AttributeValue;
const TraceId = otel_api.common.TraceId;
const SpanId = otel_api.common.SpanId;
const SpanLimits = otel_api.trace.SpanLimits;
const OpenTelemetryError = otel_api.common.OpenTelemetryError;

// Mock processor for testing
fn mockProcessorOnEnd(processor: *anyopaque, span: *RecordingSpan) void {
    _ = processor;
    _ = span;
}

test "addEvent with Event struct" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    var recording_span = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        SpanKind.internal,
        1000,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        mockProcessorOnEnd,
    );
    defer recording_span.deinit();

    const span = recording_span.span();

    // Test adding event with attributes
    const test_event = Event{
        .name = "test.event",
        .timestamp_ns = 1234567890,
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "event.type", .value = AttributeValue{ .string = "test" } },
            .{ .key = "event.level", .value = AttributeValue{ .string = "info" } },
        },
    };

    try span.addEvent(test_event);

    // Verify event was added
    try testing.expect(recording_span.events != null);
    try testing.expectEqual(@as(usize, 1), recording_span.events.?.items.len);

    const added_event = recording_span.events.?.items[0];
    try testing.expectEqualStrings("test.event", added_event.name);
    try testing.expectEqual(@as(i64, 1234567890), added_event.timestamp_ns);
    try testing.expect(added_event.attributes != null);
    try testing.expectEqual(@as(usize, 2), added_event.attributes.?.len);
}

test "addEvent with empty attributes" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    var recording_span = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        SpanKind.internal,
        1000,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        mockProcessorOnEnd,
    );
    defer recording_span.deinit();

    const span = recording_span.span();

    // Test adding event without attributes
    const test_event = Event{
        .name = "simple.event",
        .timestamp_ns = 9876543210,
        .attributes = null,
    };

    try span.addEvent(test_event);

    // Verify event was added
    try testing.expect(recording_span.events != null);
    try testing.expectEqual(@as(usize, 1), recording_span.events.?.items.len);

    const added_event = recording_span.events.?.items[0];
    try testing.expectEqualStrings("simple.event", added_event.name);
    try testing.expectEqual(@as(i64, 9876543210), added_event.timestamp_ns);
    try testing.expect(added_event.attributes == null);
}

test "addEvent validates event name" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    var recording_span = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        SpanKind.internal,
        1000,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        mockProcessorOnEnd,
    );
    defer recording_span.deinit();

    const span = recording_span.span();

    // Test empty event name should return error
    const empty_event = Event{
        .name = "",
        .timestamp_ns = 1234567890,
        .attributes = null,
    };

    const result = span.addEvent(empty_event);
    try testing.expectError(OpenTelemetryError.InvalidEventName, result);

    // Verify no event was added
    try testing.expect(recording_span.events == null or recording_span.events.?.items.len == 0);
}

test "addEvent rejects when not recording" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    var recording_span = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        SpanKind.internal,
        1000,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        mockProcessorOnEnd,
    );
    defer recording_span.deinit();

    const span = recording_span.span();

    // End the span (makes it not recording)
    span.end(null);

    // Try to add event after ending
    const test_event = Event{
        .name = "late.event",
        .timestamp_ns = 1234567890,
        .attributes = null,
    };

    try span.addEvent(test_event); // Should not error, but should be ignored

    // Verify no event was added
    try testing.expect(recording_span.events == null or recording_span.events.?.items.len == 0);
}

test "addLink with valid link" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    var recording_span = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        SpanKind.internal,
        1000,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        mockProcessorOnEnd,
    );
    defer recording_span.deinit();

    const span = recording_span.span();

    // Test adding link with attributes
    const test_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 10, 11, 12, 13, 14, 15, 16 }),
            .span_id = SpanId.fromBytes(.{ 9, 8, 7, 6, 5, 4, 3, 2 }),
            .trace_flags = 1,
            .trace_state = null,
            .is_remote = true,
        },
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "link.type", .value = AttributeValue{ .string = "cross-service" } },
            .{ .key = "link.source", .value = AttributeValue{ .string = "external-api" } },
        },
    };

    try span.addLink(test_link);

    // Verify link was added
    try testing.expect(recording_span.links != null);
    try testing.expectEqual(@as(usize, 1), recording_span.links.?.items.len);

    const added_link = recording_span.links.?.items[0];
    try testing.expect(std.mem.eql(u8, &added_link.span_context.trace_id.bytes, &test_link.span_context.trace_id.bytes));
    try testing.expect(std.mem.eql(u8, &added_link.span_context.span_id.bytes, &test_link.span_context.span_id.bytes));
    try testing.expect(added_link.attributes != null);
    try testing.expectEqual(@as(usize, 2), added_link.attributes.?.len);
}

test "addLink validates span context" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    var recording_span = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        SpanKind.internal,
        1000,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        mockProcessorOnEnd,
    );
    defer recording_span.deinit();

    const span = recording_span.span();

    // Test invalid trace_id (all zeros)
    const invalid_trace_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
            .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
            .trace_flags = 1,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = null,
    };

    try testing.expectError(OpenTelemetryError.InvalidLink, span.addLink(invalid_trace_link));

    // Test invalid span_id (all zeros)
    const invalid_span_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
            .span_id = SpanId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0 }),
            .trace_flags = 1,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = null,
    };

    try testing.expectError(OpenTelemetryError.InvalidLink, span.addLink(invalid_span_link));

    // Verify no links were added
    try testing.expect(recording_span.links == null or recording_span.links.?.items.len == 0);
}

test "addLink rejects when not recording" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    var recording_span = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        SpanKind.internal,
        1000,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        mockProcessorOnEnd,
    );
    defer recording_span.deinit();

    const span = recording_span.span();

    // End the span (makes it not recording)
    span.end(null);

    // Try to add link after ending
    const test_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 10, 11, 12, 13, 14, 15, 16 }),
            .span_id = SpanId.fromBytes(.{ 9, 8, 7, 6, 5, 4, 3, 2 }),
            .trace_flags = 1,
            .trace_state = null,
            .is_remote = true,
        },
        .attributes = null,
    };

    try span.addLink(test_link); // Should not error, but should be ignored

    // Verify no link was added
    try testing.expect(recording_span.links == null or recording_span.links.?.items.len == 0);
}

test "dropped counts tracking" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    // Use low limits to force dropping
    const limits = SpanLimits{
        .max_attributes = 1,
        .max_events = 2,
        .max_links = 1,
        .max_attributes_per_event = 1,
        .max_attributes_per_link = 1,
        .max_attribute_value_length = 100,
        .max_attribute_key_length = 50,
    };

    var recording_span = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        SpanKind.internal,
        1000,
        &[_]AttributeKeyValue{
            .{ .key = "attr1", .value = AttributeValue{ .string = "value1" } },
            .{ .key = "attr2", .value = AttributeValue{ .string = "value2" } }, // This should be dropped
        },
        &[_]Link{
            Link{
                .span_context = SpanContext{
                    .trace_id = TraceId.fromBytes(.{ 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
                    .span_id = SpanId.fromBytes(.{ 2, 2, 3, 4, 5, 6, 7, 8 }),
                    .trace_flags = 1,
                    .trace_state = null,
                    .is_remote = false,
                },
                .attributes = null,
            },
            Link{
                .span_context = SpanContext{
                    .trace_id = TraceId.fromBytes(.{ 3, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
                    .span_id = SpanId.fromBytes(.{ 3, 2, 3, 4, 5, 6, 7, 8 }),
                    .trace_flags = 1,
                    .trace_state = null,
                    .is_remote = false,
                },
                .attributes = null,
            }, // This should be dropped
        },
        limits,
        undefined,
        mockProcessorOnEnd,
    );
    defer recording_span.deinit();

    const span = recording_span.span();

    // Add events beyond the limit
    const event1 = Event{ .name = "event1", .timestamp_ns = 1, .attributes = null };
    const event2 = Event{ .name = "event2", .timestamp_ns = 2, .attributes = null };
    const event3 = Event{ .name = "event3", .timestamp_ns = 3, .attributes = null }; // Should be dropped

    try span.addEvent(event1);
    try span.addEvent(event2);
    try span.addEvent(event3);

    // Add another link beyond the limit
    const extra_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 4, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
            .span_id = SpanId.fromBytes(.{ 4, 2, 3, 4, 5, 6, 7, 8 }),
            .trace_flags = 1,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = null,
    };
    try span.addLink(extra_link);

    // Verify counts before enforcing limits
    try testing.expectEqual(@as(u32, 0), recording_span.dropped_attributes_count);
    try testing.expectEqual(@as(u32, 0), recording_span.dropped_events_count);
    try testing.expectEqual(@as(u32, 0), recording_span.dropped_links_count);

    // End the span to trigger enforceLimits()
    span.end(null);

    // Verify dropped counts are tracked
    try testing.expectEqual(@as(u32, 1), recording_span.dropped_attributes_count); // 1 attribute dropped
    try testing.expectEqual(@as(u32, 1), recording_span.dropped_events_count); // 1 event dropped
    try testing.expectEqual(@as(u32, 2), recording_span.dropped_links_count); // 2 links dropped (1 initial + 1 added)

    // Verify items were actually truncated
    try testing.expectEqual(@as(usize, 1), recording_span.attributes.?.items.len);
    try testing.expectEqual(@as(usize, 2), recording_span.events.?.items.len);
    try testing.expectEqual(@as(usize, 1), recording_span.links.?.items.len);
}

test "link allows self-reference and same-trace" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    var recording_span = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        SpanKind.internal,
        1000,
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        mockProcessorOnEnd,
    );
    defer recording_span.deinit();

    const span = recording_span.span();

    // Test self-reference (link to same span)
    const self_link = Link{
        .span_context = span_context, // Same context as the span itself
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "link.type", .value = AttributeValue{ .string = "self-reference" } },
        },
    };

    try span.addLink(self_link); // Should succeed

    // Test same-trace link (different span in same trace)
    const same_trace_link = Link{
        .span_context = SpanContext{
            .trace_id = span_context.trace_id, // Same trace ID
            .span_id = SpanId.fromBytes(.{ 9, 8, 7, 6, 5, 4, 3, 2 }), // Different span ID
            .trace_flags = 1,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "link.type", .value = AttributeValue{ .string = "same-trace" } },
        },
    };

    try span.addLink(same_trace_link); // Should succeed

    // Verify both links were added
    try testing.expect(recording_span.links != null);
    try testing.expectEqual(@as(usize, 2), recording_span.links.?.items.len);
}

test "OTLP exporter includes dropped counts" {
    const allocator = testing.allocator;

    // Create a span with some dropped data
    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    const limits = SpanLimits{
        .max_attributes = 1,
        .max_events = 1,
        .max_links = 1,
        .max_attributes_per_event = 1,
        .max_attributes_per_link = 1,
        .max_attribute_value_length = 100,
        .max_attribute_key_length = 50,
    };

    var recording_span = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        SpanKind.internal,
        1000,
        &[_]AttributeKeyValue{
            .{ .key = "attr1", .value = AttributeValue{ .string = "value1" } },
            .{ .key = "attr2", .value = AttributeValue{ .string = "value2" } }, // Will be dropped
        },
        &[_]Link{
            Link{
                .span_context = SpanContext{
                    .trace_id = TraceId.fromBytes(.{ 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
                    .span_id = SpanId.fromBytes(.{ 2, 2, 3, 4, 5, 6, 7, 8 }),
                    .trace_flags = 1,
                    .trace_state = null,
                    .is_remote = false,
                },
                .attributes = null,
            },
            Link{
                .span_context = SpanContext{
                    .trace_id = TraceId.fromBytes(.{ 3, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
                    .span_id = SpanId.fromBytes(.{ 3, 2, 3, 4, 5, 6, 7, 8 }),
                    .trace_flags = 1,
                    .trace_state = null,
                    .is_remote = false,
                },
                .attributes = null,
            }, // Will be dropped
        },
        limits,
        undefined,
        mockProcessorOnEnd,
    );
    defer recording_span.deinit();

    const span = recording_span.span();

    // Add events to trigger dropping
    const event1 = Event{ .name = "event1", .timestamp_ns = 1, .attributes = null };
    const event2 = Event{ .name = "event2", .timestamp_ns = 2, .attributes = null }; // Will be dropped

    try span.addEvent(event1);
    try span.addEvent(event2);

    // End span to trigger limits
    span.end(null);

    // Verify dropped counts were set
    try testing.expectEqual(@as(u32, 1), recording_span.dropped_attributes_count);
    try testing.expectEqual(@as(u32, 1), recording_span.dropped_events_count);
    try testing.expectEqual(@as(u32, 1), recording_span.dropped_links_count);

    // Note: Full OTLP exporter test would require more complex setup
    // This test verifies the dropped counts are available for export
}
