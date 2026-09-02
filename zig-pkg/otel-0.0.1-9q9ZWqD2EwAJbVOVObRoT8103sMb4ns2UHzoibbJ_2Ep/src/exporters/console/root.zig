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

pub const initStream = @import("config.zig").initStream;

test {
    std.testing.refAllDecls(@This());
}
