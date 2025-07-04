//! OpenTelemetry Async Instrument Configuration
//!
//! This module defines configuration types for async/observable instruments.
//! It includes error handling policies and configuration options for callback
//! execution and monitoring.

const std = @import("std");

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
    error_policy: CallbackErrorPolicy = .log_continue,

    /// Maximum number of measurements allowed per callback
    /// null means no limit
    max_measurements_per_callback: ?usize = null,

    /// Whether to warn when callbacks produce no measurements
    warn_on_no_measurements: bool = false,

    /// Whether to track callback performance metrics
    track_callback_metrics: bool = true,

    /// Default configuration with reasonable defaults
    pub fn default() AsyncInstrumentConfig {
        return AsyncInstrumentConfig{};
    }

    /// Configuration for production use (minimal overhead)
    pub fn production() AsyncInstrumentConfig {
        return AsyncInstrumentConfig{
            .error_policy = .silent_ignore,
            .max_measurements_per_callback = 100,
            .warn_on_no_measurements = false,
            .track_callback_metrics = false,
        };
    }

    /// Configuration for development/debugging
    pub fn development() AsyncInstrumentConfig {
        return AsyncInstrumentConfig{
            .error_policy = .log_continue,
            .max_measurements_per_callback = 10,
            .warn_on_no_measurements = true,
            .track_callback_metrics = true,
        };
    }
};

test "async instrument config creation" {
    const testing = std.testing;

    // Test default config
    const default_config = AsyncInstrumentConfig.default();
    try testing.expectEqual(CallbackErrorPolicy.log_continue, default_config.error_policy);
    try testing.expectEqual(@as(?usize, null), default_config.max_measurements_per_callback);
    try testing.expectEqual(false, default_config.warn_on_no_measurements);
    try testing.expectEqual(true, default_config.track_callback_metrics);

    // Test production config
    const prod_config = AsyncInstrumentConfig.production();
    try testing.expectEqual(CallbackErrorPolicy.silent_ignore, prod_config.error_policy);
    try testing.expectEqual(@as(?usize, 100), prod_config.max_measurements_per_callback);
    try testing.expectEqual(false, prod_config.warn_on_no_measurements);
    try testing.expectEqual(false, prod_config.track_callback_metrics);

    // Test development config
    const dev_config = AsyncInstrumentConfig.development();
    try testing.expectEqual(CallbackErrorPolicy.log_continue, dev_config.error_policy);
    try testing.expectEqual(@as(?usize, 10), dev_config.max_measurements_per_callback);
    try testing.expectEqual(true, dev_config.warn_on_no_measurements);
    try testing.expectEqual(true, dev_config.track_callback_metrics);
}
