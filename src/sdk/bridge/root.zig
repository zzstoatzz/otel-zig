//! SDK Bridge Root Module
//!
//! This module provides bridge adapters that allow SDK implementations
//! to work seamlessly with API interfaces through virtual tables.
//!
//! The bridge pattern solves the API/SDK integration problem by:
//! - Extending API unions to include SDK variants
//! - Using virtual tables for polymorphic dispatch
//! - Providing automatic wrapping of SDK implementations
//!
//! Usage:
//! ```zig
//! const otel_sdk = @import("otel-sdk");
//! const bridge = otel_sdk.bridge;
//! 
//! // Wrap SDK logger for API use
//! const api_logger = try bridge.wrapStandardLogger(allocator, &sdk_logger);
//! 
//! // Wrap SDK provider for API use  
//! const api_provider = try bridge.wrapStandardProvider(allocator, &sdk_provider);
//! ```

pub const logger_bridge = @import("logger_bridge.zig");
pub const provider_bridge = @import("provider_bridge.zig");
pub const meter_bridge = @import("meter_bridge.zig");
pub const meter_provider_bridge = @import("meter_provider_bridge.zig");

// Re-export key functions for convenience

// Logging bridges
pub const wrapStandardLogger = logger_bridge.wrapStandardLogger;
pub const wrapCustomLogger = logger_bridge.wrapCustomLogger;
pub const wrapStandardProvider = provider_bridge.wrapStandardProvider;
pub const setBridgeAllocator = provider_bridge.setBridgeAllocator;

// Metrics bridges
pub const wrapStandardMeter = meter_bridge.wrapStandardMeter;
pub const wrapStandardCounter = meter_bridge.wrapStandardCounter;
pub const wrapStandardUpDownCounter = meter_bridge.wrapStandardUpDownCounter;
pub const wrapStandardGauge = meter_bridge.wrapStandardGauge;
pub const wrapStandardMeterProvider = meter_provider_bridge.wrapStandardMeterProvider;

test {
    // Import all bridge tests
    _ = logger_bridge;
    _ = provider_bridge;
    _ = meter_bridge;
    _ = meter_provider_bridge;
}