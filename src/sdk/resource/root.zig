//! OpenTelemetry SDK Resource
//!
//! This module provides concrete implementations of the Resource interface.
//! Resources represent the entity producing telemetry data, such as a process,
//! container, or cloud instance.
//!
//! ## Components
//! - `Resource` - Concrete resource implementation with attributes
//! - `ResourceDetector` - Interface for automatic resource detection
//! - `DefaultDetector` - Detects common resource attributes
//! - `ProcessDetector` - Detects process-related attributes
//! - `HostDetector` - Detects host-related attributes
//!
//! ## Usage
//! ```zig
//! const otel_sdk = @import("otel-sdk");
//!
//! // Create resource manually
//! const attrs = [_]KeyValue{
//!     KeyValue.init("service.name", .{ .string = "my-service" }),
//!     KeyValue.init("service.version", .{ .string = "1.0.0" }),
//! };
//! const resource = try otel_sdk.resource.Resource.init(allocator, &attrs, null);
//!
//! // Or use detectors
//! const resource = try otel_sdk.resource.detectResource(allocator);
//! ```

const std = @import("std");
const otel_api = @import("otel-api");

// Resource types
const resource_zig = @import("resource.zig");
pub const Resource = resource_zig.Resource;

// Resource detection
pub const ResourceDetector = @import("detector.zig").ResourceDetector;
pub const DefaultDetector = @import("detector.zig").DefaultDetector;
pub const ProcessDetector = @import("detector.zig").ProcessDetector;
pub const HostDetector = @import("detector.zig").HostDetector;
pub const detectResource = @import("detector.zig").detectResource;

test {
    std.testing.refAllDecls(@This());
}
