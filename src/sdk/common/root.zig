//! OpenTelemetry SDK Common Utilities
//!
//! This module provides common utilities and types used across the SDK implementation.
//! These utilities are not part of the stable API and are used internally by the SDK.
//!
//! ## Components
//! - `Clock` - Time utilities and timestamp generation
//! - `IdGenerator` - Trace and span ID generation
//! - `Config` - Common configuration structures
//! - `Limits` - Resource and attribute limits
//!
//! ## Usage
//! These utilities are primarily for SDK implementers and should not be used
//! directly by applications unless building custom SDK components.

const std = @import("std");

// Time utilities
pub const Clock = @import("clock.zig").Clock;
pub const MonotonicClock = @import("clock.zig").MonotonicClock;
pub const SystemClock = @import("clock.zig").SystemClock;
pub const getTimestamp = @import("clock.zig").getTimestamp;
pub const getMonotonicTime = @import("clock.zig").getMonotonicTime;

// Configuration
const config_zig = @import("config.zig");
pub const Config = config_zig.Config;
pub const Limits = config_zig.Limits;
pub const AttributeLimits = config_zig.AttributeLimits;
pub const SpanLimits = config_zig.SpanLimits;
pub const LogRecordLimits = config_zig.LogRecordLimits;
pub const parseEnvironmentVariable = config_zig.parseEnvironmentVariable;
pub const getEnvironmentVariable = config_zig.getEnvironmentVariable;

const pipeline_zig = @import("pipeline.zig");
pub const PipelineBuilder = pipeline_zig.PipelineBuilder;
pub const PipelineStepInstructions = pipeline_zig.PipelineStepInstructions;
pub const PipelineDeinitConnection = pipeline_zig.PipelineDeinitConnection;

test {
    std.testing.refAllDecls(@This());
}
