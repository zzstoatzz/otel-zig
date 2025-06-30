//! OpenTelemetry Logs API
//!
//! This module provides the logging API according to the OpenTelemetry specification.
//! The API contains only interfaces and no-op implementations, allowing libraries to
//! instrument their code without depending on a specific SDK implementation.
//!
//! ## Components
//! - `Severity` - Log severity levels with OpenTelemetry standard values
//! - `LogRecord` - Log record structure
//! - `Logger` - Logger interface with no-op implementation
//! - `LoggerProvider` - Factory for creating and managing loggers
//!
//! ## Usage
//! ```zig
//! const otel_api = @import("otel-api");
//! const logger = otel_api.logs.getGlobalLogger("my.library");
//! logger.info(ctx, "Operation completed");
//! ```

const std = @import("std");

// Core types
const severity_zig = @import("severity.zig");
pub const Severity = severity_zig.Severity;
pub const SeverityError = severity_zig.SeverityError;
pub const fromNumber = severity_zig.fromNumber;
pub const fromText = severity_zig.fromText;

// Logger types
const logger_zig = @import("logger.zig");
pub const Logger = logger_zig.Logger;
pub const LoggerBridge = logger_zig.LoggerBridge;

// Logger provider types
const logger_provider_zig = @import("logger_provider.zig");
pub const LoggerProvider = logger_provider_zig.LoggerProvider;
pub const LoggerProviderBridge = logger_provider_zig.LoggerProviderBridge;

test "logs api module compilation" {
    std.testing.refAllDecls(@This());
}
