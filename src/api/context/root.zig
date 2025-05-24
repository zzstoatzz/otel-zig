//! OpenTelemetry Context API
//!
//! This module provides the context propagation API according to the OpenTelemetry specification.
//! Context is used to propagate values across API boundaries and between threads.
//!
//! The API provides a minimal interface for context management. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/context/context.md

const std = @import("std");

// Re-export context types
pub const Context = @import("context.zig").Context;
pub const ContextKey = @import("context_key.zig").ContextKey;


// Re-export propagation types
pub const TextMapCarrier = @import("propagation.zig").TextMapCarrier;
pub const TextMapPropagator = @import("propagation.zig").TextMapPropagator;
pub const NoopPropagator = @import("propagation.zig").NoopPropagator;

test "context api module compilation" {
    _ = std.testing;
    _ = Context;
    _ = ContextKey;

    _ = TextMapCarrier;
    _ = TextMapPropagator;
    _ = NoopPropagator;
}