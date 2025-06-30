//! Comprehensive Span Links Compliance Tests
//!
//! Tests the enhanced span links functionality for OpenTelemetry specification compliance:
//! - Updated link validation allowing zero IDs with attributes/trace_state
//! - Bulk addLinks API for adding multiple links at once
//! - Integration with existing span functionality
//! - Limits enforcement with bulk operations

const std = @import("std");
const testing = std.testing;

const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

// API types
const Link = otel_api.trace.Link;
const SpanContext = otel_api.trace.SpanContext;
const SpanKind = otel_api.trace.SpanKind;
const SpanLimits = otel_api.trace.SpanLimits;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const AttributeValue = otel_api.common.AttributeValue;
const TraceId = otel_api.trace.TraceId;
const SpanId = otel_api.trace.SpanId;
const OpenTelemetryError = otel_api.common.OpenTelemetryError;

// SDK types
const RecordingSpan = otel_sdk.trace.RecordingSpan;
const BasicLoggerProvider = otel_sdk.logs.BasicLoggerProvider;

fn createTestSpan(allocator: std.mem.Allocator, limits: SpanLimits) !*RecordingSpan {
    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    // Create a dummy logger provider to use as processor
    var provider = try BasicLoggerProvider.init(allocator);

    return try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null, // no parent
        SpanKind.internal,
        std.time.nanoTimestamp(),
        &.{}, // no initial attributes
        &.{}, // no initial links
        limits,
        &provider,
        null, // no processor callback
    );
}

test "Link validation - valid IDs should pass" {
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    var recording_span = try createTestSpan(allocator, SpanLimits{});
    defer recording_span.deinit();

    const span = recording_span.span();

    const valid_link = Link{
        .span_context = span_context,
        .attributes = null,
    };

    try span.addLink(valid_link);

    // Verify link was added
    try testing.expect(recording_span.links != null);
    try testing.expectEqual(@as(usize, 1), recording_span.links.?.items.len);
}

test "Link validation - zero trace_id with attributes should pass" {
    const allocator = testing.allocator;

    var recording_span = try createTestSpan(allocator, SpanLimits{});
    defer recording_span.deinit();

    const span = recording_span.span();

    // Link with zero trace_id but with attributes (should be valid per spec)
    const zero_trace_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
            .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
            .trace_flags = 0,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "link.type", .value = AttributeValue{ .string = "external" } },
        },
    };

    try span.addLink(zero_trace_link);

    // Verify link was added
    try testing.expect(recording_span.links != null);
    try testing.expectEqual(@as(usize, 1), recording_span.links.?.items.len);
}

test "Link validation - zero span_id with attributes should pass" {
    const allocator = testing.allocator;

    var recording_span = try createTestSpan(allocator, SpanLimits{});
    defer recording_span.deinit();

    const span = recording_span.span();

    // Link with zero span_id but with attributes (should be valid per spec)
    const zero_span_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
            .span_id = SpanId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0 }),
            .trace_flags = 0,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = &[_]AttributeKeyValue{
            .{ .key = "service.name", .value = AttributeValue{ .string = "external-service" } },
        },
    };

    try span.addLink(zero_span_link);

    // Verify link was added
    try testing.expect(recording_span.links != null);
    try testing.expectEqual(@as(usize, 1), recording_span.links.?.items.len);
}

test "Link validation - zero IDs with trace_state should pass" {
    const allocator = testing.allocator;

    var recording_span = try createTestSpan(allocator, SpanLimits{});
    defer recording_span.deinit();

    const span = recording_span.span();

    // Link with zero IDs but with trace_state (should be valid per spec)
    const zero_ids_with_state_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
            .span_id = SpanId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0 }),
            .trace_flags = 0,
            .trace_state = "key1=value1,key2=value2",
            .is_remote = true,
        },
        .attributes = null,
    };

    try span.addLink(zero_ids_with_state_link);

    // Verify link was added
    try testing.expect(recording_span.links != null);
    try testing.expectEqual(@as(usize, 1), recording_span.links.?.items.len);
}

test "Link validation - zero IDs without attributes or trace_state should fail" {
    const allocator = testing.allocator;

    var recording_span = try createTestSpan(allocator, SpanLimits{});
    defer recording_span.deinit();

    const span = recording_span.span();

    // Link with zero IDs and no attributes or trace_state (should be invalid)
    const invalid_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
            .span_id = SpanId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0 }),
            .trace_flags = 0,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = null,
    };

    try testing.expectError(OpenTelemetryError.InvalidLink, span.addLink(invalid_link));

    // Verify no link was added
    try testing.expect(recording_span.links == null or recording_span.links.?.items.len == 0);
}

test "Bulk addLinks - multiple valid links" {
    const allocator = testing.allocator;

    var recording_span = try createTestSpan(allocator, SpanLimits{});
    defer recording_span.deinit();

    const span = recording_span.span();

    const links = [_]Link{
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
                .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
                .trace_flags = 1,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "link.type", .value = AttributeValue{ .string = "child" } },
            },
        },
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 10, 11, 12, 13, 14, 15, 16 }),
                .span_id = SpanId.fromBytes(.{ 9, 8, 7, 6, 5, 4, 3, 2 }),
                .trace_flags = 1,
                .trace_state = "vendor=test",
                .is_remote = true,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "link.type", .value = AttributeValue{ .string = "sibling" } },
            },
        },
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
                .span_id = SpanId.fromBytes(.{ 1, 1, 1, 1, 1, 1, 1, 1 }),
                .trace_flags = 0,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "external", .value = AttributeValue{ .bool = true } },
            },
        },
    };

    try span.addLinks(&links);

    // Verify all links were added
    try testing.expect(recording_span.links != null);
    try testing.expectEqual(@as(usize, 3), recording_span.links.?.items.len);

    // Verify link contents
    const added_links = recording_span.links.?.items;
    try testing.expect(std.mem.eql(u8, &added_links[0].span_context.trace_id.bytes, &links[0].span_context.trace_id.bytes));
    try testing.expect(std.mem.eql(u8, &added_links[1].span_context.trace_id.bytes, &links[1].span_context.trace_id.bytes));
    try testing.expect(std.mem.eql(u8, &added_links[2].span_context.trace_id.bytes, &links[2].span_context.trace_id.bytes));
}

test "Bulk addLinks - mix of valid and invalid links should fail" {
    const allocator = testing.allocator;

    var recording_span = try createTestSpan(allocator, SpanLimits{});
    defer recording_span.deinit();

    const span = recording_span.span();

    const links = [_]Link{
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
                .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
                .trace_flags = 1,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = null,
        },
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
                .span_id = SpanId.fromBytes(.{ 0, 0, 0, 0, 0, 0, 0, 0 }),
                .trace_flags = 0,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = null, // Invalid: zero IDs with no attributes or trace_state
        },
    };

    // Should fail due to invalid link
    try testing.expectError(OpenTelemetryError.InvalidLink, span.addLinks(&links));

    // Verify no links were added (all-or-nothing behavior)
    try testing.expect(recording_span.links == null or recording_span.links.?.items.len == 0);
}

test "Bulk addLinks - empty slice should succeed" {
    const allocator = testing.allocator;

    var recording_span = try createTestSpan(allocator, SpanLimits{});
    defer recording_span.deinit();

    const span = recording_span.span();

    const empty_links: []const Link = &.{};
    try span.addLinks(empty_links);

    // Should not have allocated the links array
    try testing.expect(recording_span.links == null);
}

test "Bulk addLinks - respect limits" {
    const allocator = testing.allocator;

    const limits = SpanLimits{
        .max_links = 2,
        .max_attributes_per_link = 1,
    };

    var recording_span = try createTestSpan(allocator, limits);
    defer recording_span.deinit();

    const span = recording_span.span();

    // Add initial links via bulk operation
    const links = [_]Link{
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
                .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
                .trace_flags = 1,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "type", .value = AttributeValue{ .string = "first" } },
            },
        },
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
                .span_id = SpanId.fromBytes(.{ 2, 2, 3, 4, 5, 6, 7, 8 }),
                .trace_flags = 1,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "type", .value = AttributeValue{ .string = "second" } },
            },
        },
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 3, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
                .span_id = SpanId.fromBytes(.{ 3, 2, 3, 4, 5, 6, 7, 8 }),
                .trace_flags = 1,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = &[_]AttributeKeyValue{
                .{ .key = "type", .value = AttributeValue{ .string = "third" } },
            },
        },
    };

    try span.addLinks(&links);

    // End span to trigger limits enforcement
    span.end(null);

    // Verify limits were enforced
    try testing.expect(recording_span.links != null);
    try testing.expectEqual(@as(usize, 2), recording_span.links.?.items.len); // Limited to max_links
    try testing.expectEqual(@as(u32, 1), recording_span.dropped_links_count); // One link dropped
}

test "addLinks integration with single addLink" {
    const allocator = testing.allocator;

    var recording_span = try createTestSpan(allocator, SpanLimits{});
    defer recording_span.deinit();

    const span = recording_span.span();

    // Add single link first
    const single_link = Link{
        .span_context = SpanContext{
            .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
            .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
            .trace_flags = 1,
            .trace_state = null,
            .is_remote = false,
        },
        .attributes = null,
    };

    try span.addLink(single_link);

    // Then add multiple links
    const bulk_links = [_]Link{
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
        },
    };

    try span.addLinks(&bulk_links);

    // Verify all links were added
    try testing.expect(recording_span.links != null);
    try testing.expectEqual(@as(usize, 3), recording_span.links.?.items.len);
}

test "addLinks when not recording should be ignored" {
    const allocator = testing.allocator;

    var recording_span = try createTestSpan(allocator, SpanLimits{});
    defer recording_span.deinit();

    const span = recording_span.span();

    // End the span to stop recording
    span.end(null);

    const links = [_]Link{
        Link{
            .span_context = SpanContext{
                .trace_id = TraceId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
                .span_id = SpanId.fromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
                .trace_flags = 1,
                .trace_state = null,
                .is_remote = false,
            },
            .attributes = null,
        },
    };

    // Should not error, but should be ignored
    try span.addLinks(&links);

    // Verify no links were added
    try testing.expect(recording_span.links == null or recording_span.links.?.items.len == 0);
}
