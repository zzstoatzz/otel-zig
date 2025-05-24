//! OpenTelemetry All-in-One Module
//!
//! This module provides a convenience import that re-exports all OpenTelemetry
//! modules for simple use cases where you want everything available.
//!
//! ## Usage
//! ```zig
//! const otel = @import("otel");
//! 
//! // Access API components
//! const logger = try otel.api.logs.getGlobalLogger("my.service");
//! 
//! // Access SDK components  
//! var provider = otel.sdk.logs.createProvider(allocator, handler);
//! 
//! // Access exporters
//! const exporter = otel.exporters.console.createLogExporter(.{});
//! 
//! // Access semantic conventions
//! const http_attrs = otel.semconv.http.client_request;
//! ```

// Re-export all main modules
pub const api = @import("otel-api");
pub const sdk = @import("otel-sdk");
pub const exporters = @import("otel-exporters");
pub const semconv = @import("otel-semconv");