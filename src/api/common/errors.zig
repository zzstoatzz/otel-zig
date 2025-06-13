//! OpenTelemetry Common Errors
//!
//! This module defines common error types used across the OpenTelemetry API.
//! These errors represent validation failures and other API-level error conditions.

/// Common OpenTelemetry API errors
pub const OpenTelemetryError = error{
    /// Event name is invalid (empty or whitespace-only)
    InvalidEventName,

    /// Link contains invalid span context (invalid trace_id or span_id)
    InvalidLink,
};

/// Export the error type for convenience
pub const Error = OpenTelemetryError;
