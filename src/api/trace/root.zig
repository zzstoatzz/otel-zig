//! OpenTelemetry Trace API
//!
//! This module provides the tracing API according to the OpenTelemetry specification.
//! The API contains only interfaces and no-op implementations, allowing libraries to
//! instrument their code without depending on a specific SDK implementation.
//!
//! ## Components
//! - `Span` - Represents a unit of work within a trace
//! - `Tracer` - Creates spans
//! - `TracerProvider` - Factory for creating tracers
//! - `SpanContext` - Immutable span identifier
//! - `SpanKind` - Type of span (client, server, etc.)
//! - `StatusCode` - Span completion status
//!
//! ## Status
//! This is a placeholder implementation. Full trace support is planned for a future release.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md

const std = @import("std");

// TODO: Implement trace API types
// pub const Span = @import("span.zig").Span;
// pub const Tracer = @import("tracer.zig").Tracer;
// pub const TracerProvider = @import("tracer_provider.zig").TracerProvider;
// pub const SpanContext = @import("span_context.zig").SpanContext;
// pub const SpanKind = @import("span_kind.zig").SpanKind;
// pub const StatusCode = @import("status.zig").StatusCode;
// pub const Link = @import("link.zig").Link;

// Placeholder types until implementation
pub const Span = struct {};
pub const Tracer = struct {};
pub const TracerProvider = struct {};
pub const SpanContext = struct {};
pub const SpanKind = enum {
    internal,
    server,
    client,
    producer,
    consumer,
};
pub const StatusCode = enum {
    unset,
    ok,
    @"error",
};

test "trace api module compilation" {
    _ = std.testing;
    _ = Span;
    _ = Tracer;
    _ = TracerProvider;
    _ = SpanContext;
    _ = SpanKind;
    _ = StatusCode;
}