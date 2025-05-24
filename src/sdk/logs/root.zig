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

// Import SDK-specific implementations
const otel_api = @import("otel-api");

// SDK Logger types  
pub const Logger = @import("logger.zig").Logger;
pub const StandardLogger = @import("logger.zig").StandardLogger;
pub const CustomLogger = @import("logger.zig").CustomLogger;

// SDK Logger Provider types
pub const LoggerProvider = @import("logger_provider.zig").LoggerProvider;
pub const StandardLoggerProvider = @import("logger_provider.zig").StandardLoggerProvider;
pub const createStandardLogger = @import("logger.zig").createStandardLogger;

// Re-export processor types (if they exist)
pub const LogProcessor = @import("processor.zig").LogProcessor;
pub const SimpleLogProcessor = @import("simple_processor.zig").SimpleLogProcessor;
pub const createSimpleProcessor = @import("simple_processor.zig").createSimpleProcessor;

// Re-export exporter interface
pub const LogExporter = @import("exporter.zig").LogExporter;
pub const ExportResult = @import("exporter.zig").ExportResult;

test "logs sdk module compilation" {
    _ = std.testing;
    _ = Logger;
    _ = StandardLogger;
    _ = CustomLogger;
    _ = LoggerProvider;
    _ = StandardLoggerProvider;
    _ = LogProcessor;
    _ = SimpleLogProcessor;
    _ = LogExporter;
}