//! OpenTelemetry SDK
//!
//! This module provides concrete implementations of the OpenTelemetry API interfaces.
//! The SDK contains the actual implementation logic for telemetry collection, processing,
//! and exporting.

/// SDK Version
pub const sdk_version = "0.1.0";

/// Shared SDK utilities and configuration
pub const common = @import("common/root.zig");
pub const buildPipeline = common.buildPipeline;

/// Logging SDK with processors and exporters
pub const logs = @import("logs/root.zig");

/// Tracing SDK with span processors and samplers
pub const trace = @import("trace/root.zig");

/// Metrics SDK with aggregation and readers
pub const metrics = @import("metrics/root.zig");

/// Resource detection and management
pub const resource = @import("resource/root.zig");

/// Bridge for integrating std.log with OpenTelemetry logging
pub const std_log_bridge = @import("logs/std_log_bridge.zig");

test "sdk module compilation" {
    @import("std").testing.refAllDecls(@This());
}
