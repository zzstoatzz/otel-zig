//! OpenTelemetry API
//!
//! This module provides the stable API interfaces for OpenTelemetry instrumentation.
//! The API contains only interfaces, types, and no-op implementations, allowing
//! libraries to instrument their code without depending on a specific SDK implementation.
//!
//! ## Design Principles
//! - Minimal and stable interfaces
//! - No dependencies on SDK implementations
//! - Includes no-op implementations for zero-overhead when not configured
//! - Vendor-neutral instrumentation
//!
//! ## Components
//! - **logs**: Logging API with Logger and LoggerProvider interfaces
//! - **trace**: Tracing API with Tracer and TracerProvider interfaces
//! - **metrics**: Metrics API with Meter and MeterProvider interfaces
//! - **baggage**: Cross-cutting concern propagation
//! - **context**: Context propagation and management
//! - **common**: Shared types like attributes and instrumentation scope
//!
//! ## Usage
//! Libraries should depend only on this API module for instrumentation:
//! ```zig
//! const otel_api = @import("otel-api");
//! const logger = otel_api.logs.getGlobalLogger("my.library");
//! logger.info("Operation completed");
//! ```

const std = @import("std");

// Logs API
pub const logs = @import("logs/root.zig");

// Trace API
pub const trace = @import("trace/root.zig");

// Metrics API
pub const metrics = @import("metrics/root.zig");

// Baggage API
pub const baggage = @import("baggage/root.zig");

// Context API
pub const context = @import("context/root.zig");

// Common types
pub const common = @import("common/root.zig");

// Provider registry for global providers
pub const provider_registry = @import("provider_registry.zig");

// Re-export commonly used types at the root level for convenience
pub const Context = context.Context;
pub const Baggage = baggage.Baggage;
pub const AttributeValue = common.AttributeValue;
pub const KeyValue = common.KeyValue;
pub const InstrumentationScope = common.InstrumentationScope;

test "api module compilation" {
    _ = std.testing;
    _ = logs;
    _ = trace;
    _ = metrics;
    _ = baggage;
    _ = context;
    _ = common;
    _ = provider_registry;
}