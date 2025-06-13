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
pub const Config = @import("config.zig").Config;
pub const Limits = @import("config.zig").Limits;
pub const AttributeLimits = @import("config.zig").AttributeLimits;
pub const SpanLimits = @import("config.zig").SpanLimits;
pub const LogRecordLimits = @import("config.zig").LogRecordLimits;

// Utilities
pub const parseEnvironmentVariable = @import("config.zig").parseEnvironmentVariable;
pub const getEnvironmentVariable = @import("config.zig").getEnvironmentVariable;

test {
    std.testing.refAllDecls(@This());
}
