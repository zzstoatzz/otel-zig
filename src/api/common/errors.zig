//! OpenTelemetry Common Errors
//!
//! This module defines common error types used across the OpenTelemetry API.
//! These errors represent validation failures and other API-level error conditions.
//!
//! This module maintains backward compatibility with existing error types while
//! providing mapping functions to the new standardized error handling system.

const error_handler = @import("error_handler.zig");

/// Common OpenTelemetry API errors
pub const OpenTelemetryError = error{
    /// Event name is invalid (empty or whitespace-only)
    InvalidEventName,

    /// Link contains invalid span context (invalid trace_id or span_id)
    InvalidLink,
};

/// Export the error type for convenience
pub const Error = OpenTelemetryError;

/// Map OpenTelemetryError to the new ErrorType categorization
pub fn mapToErrorType(err: OpenTelemetryError) error_handler.ErrorType {
    return switch (err) {
        OpenTelemetryError.InvalidEventName => .validation,
        OpenTelemetryError.InvalidLink => .validation,
    };
}

/// Get a human-readable message for OpenTelemetryError
pub fn getErrorMessage(err: OpenTelemetryError) []const u8 {
    return switch (err) {
        OpenTelemetryError.InvalidEventName => "Event name is invalid (empty or whitespace-only)",
        OpenTelemetryError.InvalidLink => "Link contains invalid span context (invalid trace_id or span_id)",
    };
}

/// Convenience function to report OpenTelemetryError using the new error handler system
pub fn reportOpenTelemetryError(
    component: error_handler.Component,
    operation: []const u8,
    err: OpenTelemetryError,
    context: ?[]const u8,
) void {
    error_handler.reportError(.{
        .component = component,
        .operation = operation,
        .error_type = mapToErrorType(err),
        .message = getErrorMessage(err),
        .context = context,
    });
}
