//! SDK Setup Root Module
//!
//! This module provides convenient setup functions for configuring OpenTelemetry
//! SDK implementations with minimal boilerplate code.
//!
//! The setup functions use the bridge pattern to automatically integrate SDK
//! implementations with API interfaces and register them globally.
//!
//! ## Quick Start
//! ```zig
//! const otel_sdk = @import("otel-sdk");
//! 
//! // One-line console logging setup
//! var logging_setup = try otel_sdk.setup.consoleLogging(allocator, .info);
//! defer logging_setup.deinit();
//! 
//! // Get logger from global registry (now backed by SDK)
//! const logger = try otel.api.provider_registry.getGlobalLogger("my.app");
//! logger.info(ctx, "Hello, OpenTelemetry!", .{});
//! ```
//!
//! ## Available Configurations
//! - **Console Logging**: Simple stdout logging with structured output
//! - **OTLP Logging**: Export logs to OTLP-compatible collectors
//! - **Custom Handler**: Use your own log handler function
//! - **No-op Logging**: SDK-backed but silent logging (useful for testing)

const std = @import("std");

// Setup modules
pub const quick_setup = @import("quick_setup.zig");

// Re-export setup functions that actually exist
pub const consoleLogging = quick_setup.consoleLogging;
pub const otlpLogging = quick_setup.otlpLogging;
pub const setupWithHandler = quick_setup.setupWithHandler;
pub const noopLogging = quick_setup.noopLogging;

// Re-export types
pub const SetupError = quick_setup.SetupError;
pub const LoggingSetup = quick_setup.LoggingSetup;
pub const LogHandler = quick_setup.LogHandler;

test {
    // Import all setup tests
    _ = quick_setup;
}