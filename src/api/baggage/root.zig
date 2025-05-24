//! OpenTelemetry Baggage API
//!
//! This module provides the baggage API according to the OpenTelemetry specification.
//! Baggage is used to propagate user-supplied key-value pairs across process boundaries.
//!
//! ## Components
//! - `Baggage` - Immutable container for string key-value pairs
//! - `BaggageEntry` - Individual baggage entry with value and optional metadata
//! - `BaggageBuilder` - Builder for creating baggage instances
//!
//! ## Usage
//! ```zig
//! const otel_api = @import("otel-api");
//! const baggage = otel_api.baggage.create(&.{
//!     .{ "user.id", "12345" },
//!     .{ "session.id", "abcdef" },
//! });
//! const user_id = baggage.getValue("user.id");
//! ```
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/baggage/api.md

const std = @import("std");

// Re-export baggage types
pub const Baggage = @import("baggage.zig").Baggage;
pub const BaggageEntry = @import("baggage.zig").BaggageEntry;
pub const BaggageBuilder = @import("baggage.zig").BaggageBuilder;
pub const EmptyBaggage = @import("baggage.zig").BaggageBuildFn;

// Re-export factory functions

test "baggage api module compilation" {
    _ = std.testing;
    _ = Baggage;
    _ = BaggageEntry;
    _ = BaggageBuilder;
}
