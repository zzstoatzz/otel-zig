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
pub const Severity = @import("severity.zig").Severity;
pub const SeverityError = @import("severity.zig").SeverityError;
pub const fromNumber = @import("severity.zig").fromNumber;
pub const fromText = @import("severity.zig").fromText;

// Log record types
pub const LogRecord = @import("log_record.zig").LogRecord;

// Logger types
pub const Logger = @import("logger.zig").Logger;
pub const NoopLogger = @import("logger.zig").NoopLogger;
pub const createNoopLogger = @import("logger.zig").createNoopLogger;

// Logger provider types
pub const LoggerProvider = @import("logger_provider.zig").LoggerProvider;
pub const NoopLoggerProvider = @import("logger_provider.zig").NoopLoggerProvider;
pub const createNoopProvider = @import("logger_provider.zig").createNoopProvider;

// SDK bridge types
pub const SdkLoggerVTable = @import("logger.zig").SdkLoggerVTable;
pub const SdkLoggerBridge = @import("logger.zig").SdkLoggerBridge;

pub const SdkProviderVTable = @import("logger_provider.zig").SdkProviderVTable;
pub const SdkProviderBridge = @import("logger_provider.zig").SdkProviderBridge;

// Global provider registry functions will be imported from the main provider_registry
pub const getGlobalLoggerProvider = @import("../provider_registry.zig").getGlobalLoggerProvider;
pub const setGlobalLoggerProvider = @import("../provider_registry.zig").setGlobalLoggerProvider;
pub const resetGlobalLoggerProvider = @import("../provider_registry.zig").resetGlobalLoggerProvider;
pub const getGlobalLogger = @import("../provider_registry.zig").getGlobalLogger;
pub const getGlobalLoggerWithVersion = @import("../provider_registry.zig").getGlobalLoggerWithVersion;

test "logs api module compilation" {
    _ = std.testing;
    _ = Severity;
    _ = LogRecord;
    _ = Logger;
    _ = LoggerProvider;
    _ = getGlobalLoggerProvider;
    _ = setGlobalLoggerProvider;
    _ = resetGlobalLoggerProvider;
}