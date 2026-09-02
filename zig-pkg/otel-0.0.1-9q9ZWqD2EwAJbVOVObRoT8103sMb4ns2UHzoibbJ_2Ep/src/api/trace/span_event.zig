//! OpenTelemetry Span Event
//!
//! Events are timestamped occurrences within a span that provide additional context
//! about what happened during the span's execution. Events are useful for logging
//! significant moments, exceptions, or other notable occurrences within a span.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#add-events

const std = @import("std");
const api = struct {
    const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
};

const Event = @This();

/// Event represents a timestamped occurrence within a span
/// Human-readable name for the event
name: []const u8,

/// Timestamp of the event in nanoseconds since Unix epoch
timestamp_ns: i64,

/// Optional attributes providing additional context about the event
attributes: []const api.AttributeKeyValue = &.{},
