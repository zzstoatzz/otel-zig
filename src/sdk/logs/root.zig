//! OpenTelemetry Logs SDK
//!
//! This module provides concrete implementations of the OpenTelemetry Logs API.
//! Currently, this re-exports the existing mixed implementation from the main logs module.
//! In the future, this will be refactored to properly separate API and SDK concerns.
//!
//! ## Components
//! - `BasicLogger` - Concrete logger implementation with filtering and handlers
//! - `BasicLoggerProvider` - Provider with caching and configuration
//! - `LogProcessor` - Interface for processing log records
//! - `BasicLogProcessor` - Immediately exports each log record
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

// SDK Logger Provider types
pub const BasicLoggerProvider = @import("basic_provider.zig").BasicLoggerProvider;

// Re-export processor types
const processor_zig = @import("processor.zig");
pub const LogProcessor = processor_zig.LogProcessor;
pub const BridgeLogProcessor = processor_zig.BridgeLogProcessor;

// Re-export basic processor types
const basic_processor_zig = @import("basic_processor.zig");
pub const BasicLogProcessor = basic_processor_zig.BasicLogProcessor;

// Re-export exporter interface
const exporter_zig = @import("exporter.zig");
pub const LogExporter = exporter_zig.LogExporter;
pub const BridgeLogExporter = exporter_zig.BridgeLogExporter;

// Re-export the setup helper functions
const setup_zig = @import("setup.zig");
pub const setupGlobalProvider = setup_zig.setupGlobalProvider;

test "logs sdk module compilation" {
    std.testing.refAllDecls(@This());
}
