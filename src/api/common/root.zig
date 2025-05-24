//! OpenTelemetry Common API Types
//!
//! This module provides common types used across all OpenTelemetry signals
//! (logs, traces, metrics). These types are part of the stable API.
//!
//! ## Components
//! - `AttributeValue` - Type-safe attribute values
//! - `KeyValue` - Key-value pairs for attributes
//! - `InstrumentationScope` - Metadata about instrumentation libraries

const std = @import("std");

// Re-export attribute types
const attributes_zig = @import("attributes.zig");
pub const AttributeValue = attributes_zig.AttributeValue;
pub const KeyValue = attributes_zig.KeyValue;
pub const Attributes = attributes_zig.Attributes;
pub const AttributeBuilder = attributes_zig.AttributeBuilder;

// Re-export instrumentation scope
pub const InstrumentationScope = @import("instrumentation_scope.zig").InstrumentationScope;



test "common api module compilation" {
    _ = std.testing;
    _ = AttributeValue;
    _ = KeyValue;
    _ = InstrumentationScope;
    _ = Attributes;
    _ = AttributeBuilder;
}
