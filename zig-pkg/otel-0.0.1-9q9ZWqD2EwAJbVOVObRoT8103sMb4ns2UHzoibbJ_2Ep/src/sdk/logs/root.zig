//! OpenTelemetry Logs SDK
//!
//! This module provides concrete implementations of the OpenTelemetry Logs API.
//! Currently, this re-exports the existing mixed implementation from the main logs module.
//! In the future, this will be refactored to properly separate API and SDK concerns.
//!
//! ## Components
//! - `Logger` - Concrete logger implementation with filtering and handlers
//! - `LoggerProvider` - Provider with caching and configuration
//! - `LogRecordProcessor` - Interface for processing log records
//! - `SimpleLogRecordProcessor` - Immediately exports each log record async.
//! - 'BridgeLogRecordProcessor' - VTable adaptor for implementing other Processors.
//! - `LogRecordExporter` - Interface for exporting log records
//! - `BridgeLogRecordExporter` - VTable adaptor for implementing other processors.\
//! - `MockLogRecordExporter` - Captures exported records for testing.
//! - `setupGlobalProvider` - Uses a pipeline to build a configured LoggerProvider and set it as the global provider.

const std = @import("std");

// Core log data type, for processors and exporters.
pub const LogRecord = @import("log_record.zig").LogRecord;

// SDK Logger types for integrations.
pub const LoggerProvider = @import("logger_provider.zig").LoggerProvider;
pub const Logger = @import("logger.zig").Logger;

// SDK Processor Types.
const processor_zig = @import("processor.zig");
pub const LogRecordProcessor = processor_zig.LogRecordProcessor;
pub const BridgeLogRecordProcessor = processor_zig.BridgeLogRecordProcessor;
pub const SimpleLogRecordProcessor = @import("simple_processor.zig").SimpleLogRecordProcessor;
pub const BatchLogRecordProcessor = @import("batch_processor.zig").BatchLogRecordProcessor;

// SDK Exporter Types.
const exporter_zig = @import("exporter.zig");
pub const LogRecordExporter = exporter_zig.LogRecordExporter;
pub const BridgeLogRecordExporter = exporter_zig.BridgeLogRecordExporter;
pub const MockLogRecordExporter = exporter_zig.MockLogRecordExporter;

// Re-export the setup helper functions
pub const setupGlobalProvider = @import("setup.zig").setupGlobalProvider;

// std.log bridge for integrating Zig's standard logging with OpenTelemetry
pub const std_log_bridge = @import("std_log_bridge.zig");

test "logs sdk module compilation" {
    _ = @import("tests.zig");
    std.testing.refAllDecls(@This());
}
