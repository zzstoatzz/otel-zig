//! OpenTelemetry Logs SDK
//!
//! This module provides concrete implementations of the OpenTelemetry Logs API.
//! Currently, this re-exports the existing mixed implementation from the main logs module.
//! In the future, this will be refactored to properly separate API and SDK concerns.
//!
//! ## Components
//! - `Logger` - Concrete logger implementation with filtering and handlers
//! - `LoggerProvider` - Provider with caching and configuration
//! - `LogProcessor` - Interface for processing log records
//! - `BasicLogProcessor` - Immediately exports each log record async.
//! - 'BridgeLogProcessor' - VTable adaptor for implementing other Processors.
//! - `LogExporter` - Interface for exporting log records
//! - `BridgeLogExporter` - VTable adaptor for implementing other processors.\
//! - `MockLogExporter` - Captures exported records for testing.
//! - `setupGlobalProvider` - Uses a pipeline to build a configured LoggerProvider and set it as the global provider.

const std = @import("std");

// Core log data type, for processors and exporters.
pub const LogRecord = @import("log_record.zig").LogRecord;

// SDK Logger types for integrations.
pub const LoggerProvider = @import("logger_provider.zig").LoggerProvider;
pub const Logger = @import("logger.zig").Logger;

// SDK Processor Types.
const processor_zig = @import("processor.zig");
pub const LogProcessor = processor_zig.LogProcessor;
pub const BridgeLogProcessor = processor_zig.BridgeLogProcessor;
pub const BasicLogProcessor = @import("basic_processor.zig").BasicLogProcessor;

// SDK Exporter Types.
const exporter_zig = @import("exporter.zig");
pub const LogExporter = exporter_zig.LogExporter;
pub const BridgeLogExporter = exporter_zig.BridgeLogExporter;
pub const MockLogExporter = exporter_zig.MockLogExporter;

// Re-export the setup helper functions
pub const setupGlobalProvider = @import("setup.zig").setupGlobalProvider;

test "logs sdk module compilation" {
    _ = @import("tests.zig");
    std.testing.refAllDecls(@This());
}
