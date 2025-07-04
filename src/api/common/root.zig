//! OpenTelemetry Common API Types
//!
//! This module provides common types used across all OpenTelemetry signals
//! (logs, traces, metrics). These types are part of the stable API.
//!
//! ## Components
//! - `AttributeValue` - Type-safe attribute values
//! - `KeyValue` - Key-value pairs for attributes
//! - `InstrumentationScope` - Metadata about instrumentation libraries
//! - `ExportResult` - Result of export operations
//! - `ProcessResult` - Result of processing operations
//! - `FlushResult` - Result of flush operations
//! - `ShutdownResult` - Result of shutdown operations
//! - `OperationResult` - Result of general operations
//! - `ErrorHandler` - Runtime configurable error handling

const std = @import("std");

// Re-export attribute types
const attributes_zig = @import("attributes.zig");
pub const AttributeValue = attributes_zig.AttributeValue;
pub const AttributeKeyValue = attributes_zig.AttributeKeyValue;
pub const AttributeBuilder = attributes_zig.AttributeBuilder;

// Re-export instrumentation scope
pub const InstrumentationScope = @import("instrumentation_scope.zig").InstrumentationScope;

// Re-export result types
const results_zig = @import("results.zig");
pub const ExportResult = results_zig.ExportResult;
pub const ProcessResult = results_zig.ProcessResult;
pub const FlushResult = results_zig.FlushResult;

const types_zig = @import("types.zig");
pub const TraceId = types_zig.TraceId;
pub const SpanId = types_zig.SpanId;
pub const validateTraceId = types_zig.validateTraceId;
pub const validateSpanId = types_zig.validateSpanId;
pub const validateTraceFlags = types_zig.validateTraceFlags;

// Re-export error types
const errors_zig = @import("errors.zig");
pub const OpenTelemetryError = errors_zig.OpenTelemetryError;
pub const Error = errors_zig.Error;

// Re-export error handler system
const error_handler_zig = @import("error_handler.zig");
pub const ErrorHandler = error_handler_zig.ErrorHandler;
pub const ErrorInfo = error_handler_zig.ErrorInfo;
pub const Component = error_handler_zig.Component;
pub const ErrorType = error_handler_zig.ErrorType;
pub const setGlobalErrorHandler = error_handler_zig.setGlobalErrorHandler;
pub const getGlobalErrorHandler = error_handler_zig.getGlobalErrorHandler;
pub const reportError = error_handler_zig.reportError;
pub const reportErrorWithAllocator = error_handler_zig.reportErrorWithAllocator;
pub const formatDetailedMessage = error_handler_zig.formatDetailedMessage;
pub const reportValidationError = error_handler_zig.reportValidationError;
pub const reportValidationErrorWithSource = error_handler_zig.reportValidationErrorWithSource;
pub const reportResourceExhaustedError = error_handler_zig.reportResourceExhaustedError;
pub const reportResourceExhaustedErrorWithSource = error_handler_zig.reportResourceExhaustedErrorWithSource;
pub const reportNetworkError = error_handler_zig.reportNetworkError;
pub const reportNetworkErrorWithSource = error_handler_zig.reportNetworkErrorWithSource;
pub const reportSerializationError = error_handler_zig.reportSerializationError;
pub const reportSerializationErrorWithSource = error_handler_zig.reportSerializationErrorWithSource;
pub const reportCallbackError = error_handler_zig.reportCallbackError;
pub const reportCallbackErrorWithSource = error_handler_zig.reportCallbackErrorWithSource;
pub const isValidatingMode = error_handler_zig.isValidatingMode;
pub const MockErrorHandler = error_handler_zig.MockErrorHandler;
pub const setMockErrorHandler = error_handler_zig.setMockErrorHandler;
pub const clearMockErrorHandler = error_handler_zig.clearMockErrorHandler;

test {
    std.testing.refAllDecls(@This());
}
