//! OpenTelemetry Common API Types
//!
//! This module provides common types used across all OpenTelemetry signals
//! (logs, traces, metrics). These types are part of the stable API.
//!
//! ## Components
//! - `AttributeValue` - Type-safe attribute values
//! - `KeyValue` - Key-value pairs for attributes
//! - `InstrumentationScope` - Metadata about instrumentation libraries
//! - `ExportResult` - Result of export operations
//! - `ProcessResult` - Result of processing operations
//! - `FlushResult` - Result of flush operations

const std = @import("std");

// Re-export attribute types
const attributes_zig = @import("attributes.zig");
pub const AttributeValue = attributes_zig.AttributeValue;
pub const AttributeKeyValue = attributes_zig.AttributeKeyValue;
pub const AttributeBuilder = attributes_zig.AttributeBuilder;

// Re-export instrumentation scope
pub const InstrumentationScope = @import("instrumentation_scope.zig").InstrumentationScope;

// Re-export result types
const results_zig = @import("results.zig");
pub const ExportResult = results_zig.ExportResult;
pub const ProcessResult = results_zig.ProcessResult;
pub const FlushResult = results_zig.FlushResult;

const types_zig = @import("types.zig");
pub const TraceId = types_zig.TraceId;
pub const SpanId = types_zig.SpanId;

// Re-export error types
const errors_zig = @import("errors.zig");
pub const OpenTelemetryError = errors_zig.OpenTelemetryError;
pub const Error = errors_zig.Error;

test {
    std.testing.refAllDecls(@This());
}
