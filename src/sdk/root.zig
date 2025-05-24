//! OpenTelemetry SDK
//!
//! This module provides concrete implementations of the OpenTelemetry API interfaces.
//! The SDK contains the actual implementation logic for telemetry collection, processing,
//! and exporting.
//!
//! ## Design Principles
//! - Implements all API interfaces with configurable behavior
//! - Provides processors, exporters, and samplers
//! - Manages telemetry pipelines and resource detection
//! - Offers performance optimizations and batching
//!
//! ## Components
//! - **logs**: Logging SDK with processors and exporters
//! - **trace**: Tracing SDK with span processors and samplers
//! - **metrics**: Metrics SDK with aggregation and readers
//! - **resource**: Resource detection and management
//! - **common**: Shared SDK utilities and configuration
//! - **bridge**: API/SDK integration adapters
//! - **setup**: Quick configuration utilities
//!
//! ## Usage
//! All functionality is accessed through namespaced modules for clear organization:
//!
//! ```zig
//! const otel_sdk = @import("otel-sdk");
//! 
//! // Setup telemetry pipeline
//! var logging_setup = try otel_sdk.setup.consoleLogging(allocator, .info);
//! defer logging_setup.deinit();
//! 
//! // Resource detection and management
//! const resource = try otel_sdk.resource.detectResource(allocator);
//! defer resource.deinitOwned(allocator);
//! 
//! // Working with specific components
//! const processor = otel_sdk.logs.SimpleLogProcessor.init(...);
//! const provider = try otel_sdk.bridge.wrapStandardProvider(allocator, sdk_provider);
//! 
//! // Advanced configurations
//! var custom_resource = try otel_sdk.resource.Resource.init(attrs, null);
//! var detector = otel_sdk.resource.ProcessDetector.init();
//! ```
//!
//! ## Module Organization
//! - **setup.**: Primary entry points for quick configuration
//! - **resource.**: Resource detection, creation, and management
//! - **logs.**: Logging processors, exporters, and providers
//! - **bridge.**: Integration adapters between API and SDK
//! - **common.**: Shared utilities across SDK components

const std = @import("std");

// Import API types
const otel_api = @import("otel-api");

// ============================================================================
// SDK MODULES
// ============================================================================

/// Logging SDK with processors and exporters
pub const logs = @import("logs/root.zig");

/// Tracing SDK with span processors and samplers
// pub const trace = @import("trace/root.zig");

/// Metrics SDK with aggregation and readers
pub const metrics = @import("metrics/root.zig");

/// Resource detection and management
pub const resource = @import("resource/root.zig");

/// Shared SDK utilities and configuration
pub const common = @import("common/root.zig");

/// Bridge adapters for API/SDK integration
pub const bridge = @import("bridge/root.zig");

/// Setup utilities for easy configuration
pub const setup = @import("setup/root.zig");

test "sdk module compilation" {
    _ = std.testing;
    _ = logs;
    // _ = trace;
    _ = metrics;
    _ = resource;
    _ = common;
    _ = bridge;
    _ = setup;
}