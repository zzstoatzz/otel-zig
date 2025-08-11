//! OpenTelemetry Async Instrument Configuration
//!
//! This module defines configuration types for async/observable instruments.
//! It includes error handling policies and configuration options for callback
//! execution and monitoring.

const std = @import("std");

const sdk = struct {
    const AggregationTemporality = @import("aggregations.zig").AggregationTemporality;
};

/// Error handling policy for callback execution
pub const CallbackErrorPolicy = enum {
    /// Stop processing on first callback error
    fail_fast,
    /// Log errors and continue with other callbacks
    log_continue,
    /// Silently ignore errors and continue
    silent_ignore,
};

/// Configuration for async instrument behavior
pub const AsyncInstrumentConfig = struct {
    /// Policy for handling callback errors
    error_policy: CallbackErrorPolicy,

    /// Maximum number of measurements allowed per callback
    /// null means no limit
    max_measurements_per_callback: ?usize,

    /// Whether to warn when callbacks produce no measurements
    warn_on_no_measurements: bool,

    /// Whether to track callback performance metrics
    track_callback_metrics: bool,

    /// Default config used
    pub const default: AsyncInstrumentConfig = .{
        .error_policy = .log_continue,
        .max_measurements_per_callback = null,
        .track_callback_metrics = true,
        .warn_on_no_measurements = true,
    };

    pub const strict: AsyncInstrumentConfig = .{
        .error_policy = .fail_fast,
        .max_measurements_per_callback = 10,
        .track_callback_metrics = true,
        .warn_on_no_measurements = true,
    };

    /// Default config for up-down counters
    pub const production: AsyncInstrumentConfig = .{
        .error_policy = .silent_ignore,
        .max_measurements_per_callback = 100,
        .track_callback_metrics = false,
        .warn_on_no_measurements = false,
    };
};
