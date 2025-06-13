//! OpenTelemetry Logs SDK
//!
//! This module provides concrete implementations of the OpenTelemetry Logs API.
//! Currently, this re-exports the existing mixed implementation from the main logs module.
//! In the future, this will be refactored to properly separate API and SDK concerns.
//!
//! ## Components
//! - `StandardLogger` - Concrete logger implementation with filtering and handlers
//! - `StandardLoggerProvider` - Provider with caching and configuration
//! - `LogProcessor` - Interface for processing log records
//! - `SimpleLogProcessor` - Immediately exports each log record
//! - `LogExporter` - Interface for exporting log records
//!
//! ## Usage
//! ```zig
//! const otel_sdk = @import("otel-sdk");
//!
//! // Create a logging pipeline
//! const exporter = otel_sdk.logs.createConsoleExporter();
//! const processor = otel_sdk.logs.createSimpleProcessor(.{
//!     .exporter = exporter,
//! });
//!
//! var provider = otel_sdk.logs.createProvider(allocator, .{
//!     .processor = processor,
//! });
//! ```

const std = @import("std");

// Core log data types
pub const LogRecord = @import("log_record.zig").LogRecord;

// SDK Logger types
pub const StandardLogger = @import("logger.zig").StandardLogger;

// SDK Logger Provider types
pub const StandardLoggerProvider = @import("logger_provider.zig").StandardLoggerProvider;

// Re-export processor types
const processor_zig = @import("processor.zig");
pub const LogProcessor = processor_zig.LogProcessor;
pub const SimpleLogProcessor = processor_zig.SimpleLogProcessor;
pub const BridgeLogProcessor = processor_zig.BridgeLogProcessor;

// Re-export exporter interface
const exporter_zig = @import("exporter.zig");
pub const LogExporter = exporter_zig.LogExporter;
pub const BridgeLogExporter = exporter_zig.BridgeLogExporter;

// Re-export the setup helper functions
pub const buildProvider = @import("setup.zig").buildProvider;
pub const destroyProvider = @import("setup.zig").destroyProvider;
pub const createSimpleSyncLogging = @import("setup.zig").createSimpleSyncLogging;

test "logs sdk module compilation" {
    std.testing.refAllDecls(@This());
}
