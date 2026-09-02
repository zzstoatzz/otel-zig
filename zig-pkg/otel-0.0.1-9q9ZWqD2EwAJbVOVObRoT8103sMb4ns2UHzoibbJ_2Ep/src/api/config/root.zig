//! OpenTelemetry Configuration API
//!
//! This module provides the configuration API for OpenTelemetry instrumentation libraries.
//! It implements the instrumentation configuration API as specified by the OpenTelemetry
//! configuration specification.
//!
//! The configuration API consists of:
//! - ConfigProvider: Entry point for accessing configuration
//! - ConfigProperties: Programmatic representation of configuration mapping nodes
//! - ConfigValue: Type-safe representation of configuration values with navigation support
//!
//! ## Usage
//!
//! ```zig
//! // Access global configuration
//! const config_provider = otel_api.getGlobalConfigProvider();
//! if (config_provider.getInstrumentationConfig()) |config| {
//!     // Navigate configuration hierarchy
//!     const http_config = config.get("general").get("http").get("client");
//!
//!     // Extract typed values with defaults
//!     const timeout = config.get("timeout").asInt() orelse 30000;
//!     const headers = http_config.get("request_captured_headers").asStringArray() orelse &[_][]const u8{};
//!
//!     // Check configuration state
//!     const debug_setting = config.get("debug");
//!     if (debug_setting.isSet()) {
//!         if (debug_setting.isNull()) {
//!             // Explicitly set to null
//!         } else {
//!             const debug_enabled = debug_setting.asBool() orelse false;
//!         }
//!     }
//! }
//! ```
//!
//! ## Memory Management
//!
//! All configuration API types are non-owning and hold references to data owned by the SDK.
//! ConfigValue references should not outlive the ConfigProvider that created them.
//!
//! ## Three-State Null Handling
//!
//! The configuration API supports three distinct states as required by the OpenTelemetry specification:
//! - `not_set`: Property is not present in the configuration
//! - `null`: Property is present but explicitly set to null
//! - `value`: Property has an actual value
//!
//! Both `not_set` and `null` typically result in using default values, but the API allows
//! distinguishing between them when needed.

const std = @import("std");

// Re-export configuration types
pub const ConfigValue = @import("config_value.zig").ConfigValue;
pub const ConfigProperties = @import("config_properties.zig").ConfigProperties;
pub const ConfigPropertiesBridge = @import("config_properties.zig").ConfigPropertiesBridge;
pub const ConfigProvider = @import("config_provider.zig").ConfigProvider;
pub const ConfigProviderBridge = @import("config_provider.zig").ConfigProviderBridge;

test "config module compilation" {
    std.testing.refAllDecls(@This());
}
