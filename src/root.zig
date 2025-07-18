//! OpenTelemetry All-in-One Module
//!
//! This module provides a convenience import that re-exports all OpenTelemetry
//! modules for simple use cases where you want everything available.

// Re-export all main modules
pub const api = @import("otel-api");
pub const sdk = @import("otel-sdk");
pub const exporters = @import("otel-exporters");
pub const semconv = @import("otel-semconv");
