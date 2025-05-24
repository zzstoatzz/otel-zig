//! OpenTelemetry Exporters
//!
//! This module provides exporters for sending telemetry data to various backends.
//! Exporters are responsible for serializing and transmitting data collected by
//! the SDK to external systems for storage and analysis.
//!
//! ## Available Exporters
//!
//! ### Console Exporters
//! Simple exporters that write telemetry data to stdout/stderr for debugging.
//! - `console.logs` - Exports log records to console
//! - `console.traces` - Exports spans to console
//! - `console.metrics` - Exports metrics to console
//!
//! ### OTLP Exporters
//! OpenTelemetry Protocol exporters for sending data to OTLP-compatible backends.
//! - `otlp.logs` - Exports logs via OTLP
//! - `otlp.traces` - Exports traces via OTLP
//! - `otlp.metrics` - Exports metrics via OTLP
//! - Supports both gRPC and HTTP transports
//!
//!
//! ## Usage Example
//! ```zig
//! const otel = @import("otel");
//! const exporters = otel.exporters;
//!
//! // Console exporter for debugging
//! const console_exporter = exporters.console.createLogExporter(.{
//!     .pretty_print = true,
//! });
//!
//! // OTLP exporter for production
//! const otlp_exporter = exporters.otlp.createLogExporter(.{
//!     .endpoint = "http://localhost:4317",
//!     .headers = &.{.{ "api-key", "secret" }},
//! });
//!
//! // Configure SDK with exporter
//! const processor = otel.sdk.logs.createSimpleProcessor(.{
//!     .exporter = otlp_exporter,
//! });
//! ```

const std = @import("std");

// Console exporters for simple output
pub const console = @import("console/root.zig");

// OTLP exporters for OpenTelemetry Protocol
pub const otlp = @import("otlp/root.zig");



// Common exporter utilities and types
pub const ExportResult = @import("common.zig").ExportResult;
pub const ExportError = @import("common.zig").ExportError;
pub const ExporterConfig = @import("common.zig").ExporterConfig;

// Re-export convenience functions for creating exporters
pub const createConsoleLogExporter = console.createLogExporter;
pub const createConsoleTraceExporter = console.createTraceExporter;
pub const createConsoleMetricExporter = console.createMetricExporter;

pub const createOtlpLogExporter = otlp.createLogExporter;
pub const createOtlpTraceExporter = otlp.createTraceExporter;
pub const createOtlpMetricExporter = otlp.createMetricExporter;



test "exporters module compilation" {
    _ = std.testing;
    _ = console;
    _ = otlp;
    _ = ExportResult;
    _ = ExportError;
    _ = ExporterConfig;
}