//! OpenTelemetry Console Exporters
//!
//! This module provides simple console exporters that write telemetry data
//! to stdout/stderr. These exporters are primarily useful for debugging and
//! development purposes.
//!
//! ## Components
//! - `ConsoleLogExporter` - Writes log records to console
//! - `ConsoleTraceExporter` - Writes spans to console
//! - `ConsoleMetricExporter` - Writes metrics to console
//!
//! ## Configuration
//! All console exporters support:
//! - `pretty_print` - Format output for human readability
//! - `use_stderr` - Write to stderr instead of stdout
//! - `include_timestamp` - Include timestamps in output
//!
//! ## Usage
//! ```zig
//! const console_exporter = createLogExporter(.{
//!     .pretty_print = true,
//!     .include_timestamp = true,
//! });
//! ```

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

const LogRecord = otel_api.logs.LogRecord;
const ExportResult = otel_sdk.logs.ExportResult;

// Re-export types
pub const ConsoleTraceExporter = @import("traces.zig").ConsoleTraceExporter;
pub const ConsoleMetricExporter = @import("metrics.zig").ConsoleMetricExporter;

// Re-export generic stream exporter
pub const StreamLogExporter = @import("logs.zig").StreamLogExporter;
pub const StreamLogExporterConfig = @import("logs.zig").StreamLogExporterConfig;

// Configuration structures
pub const ConsoleExporterConfig = struct {
    /// Format output for human readability
    pretty_print: bool = true,

    /// Write to stderr instead of stdout
    use_stderr: bool = false,

    /// Include timestamps in output
    include_timestamp: bool = true,

    /// Include attributes in output
    include_attributes: bool = true,

    /// Maximum attribute value length (0 = unlimited)
    max_attribute_length: usize = 128,
};

// Factory functions
pub const LogPipelineConfig = struct {
    pub const ConcreteType = StreamLogExporter(std.fs.File.Writer);
    pub const InterfaceType = otel_sdk.logs.LogRecordExporter;
    pub const ContextType = ConsoleExporterConfig;
    pub const converterFn = StreamLogExporter(std.fs.File.Writer).logRecordExporter;
    pub const initFn = init;

    ctx: ContextType,

    pub fn init(ctx: ContextType, allocator: std.mem.Allocator) !*ConcreteType {
        const file = if (ctx.use_stderr) std.io.getStdErr() else std.io.getStdOut();
        const stream_config = StreamLogExporterConfig{
            .pretty_print = ctx.pretty_print,
            .include_timestamp = ctx.include_timestamp,
            .include_attributes = ctx.include_attributes,
            .max_attribute_length = ctx.max_attribute_length,
        };

        return try StreamLogExporter(std.fs.File.Writer).init(allocator, stream_config, file.writer());
    }
};

pub const createMetricExporterWithConfig = @import("metrics.zig").createMetricExporterWithConfig;
pub const createTraceExporterWithConfig = @import("traces.zig").createTraceExporterWithConfig;

test {
    std.testing.refAllDecls(@This());
}
