//! OpenTelemetry Configuration Provider API
//!
//! This module defines the ConfigProvider interface for accessing configuration
//! relevant to instrumentation libraries. ConfigProvider is the entry point
//! for the instrumentation configuration API.
//!
//! ConfigProvider follows the bridge pattern to allow SDK implementations
//! to provide concrete configuration sources while maintaining API stability.
//!
//! ## Usage
//!
//! ```zig
//! const config_provider = otel_api.getGlobalConfigProvider();
//! if (config_provider.getInstrumentationConfig()) |config| {
//!     const timeout = config.get("timeout").asInt() orelse 30000;
//!     const headers = config.get("http").get("client").get("request_captured_headers");
//! }
//! ```

const std = @import("std");
const ConfigProperties = @import("config_properties.zig").ConfigProperties;

/// ConfigProvider provides access to configuration properties relevant to instrumentation.
/// It uses a tagged union with bridge pattern to allow SDK implementations.
pub const ConfigProvider = union(enum) {
    /// No-operation implementation that returns null for all queries
    noop: void,

    /// Bridge to SDK implementation
    bridge: ConfigProviderBridge,

    /// Get configuration relevant to instrumentation libraries
    /// Returns ConfigProperties representing the .instrumentation configuration mapping node
    /// Returns null if the .instrumentation node is not set (per OpenTelemetry specification)
    pub inline fn getInstrumentationConfig(self: *const ConfigProvider) ?ConfigProperties {
        return switch (self.*) {
            .noop => null,
            .bridge => |*bridge| bridge.getInstrumentationConfigFn(bridge.ctx),
        };
    }
};

/// Bridge structure that holds SDK implementation pointer and vtable
/// This enables SDK implementations to plug into the API interface
pub const ConfigProviderBridge = struct {
    /// Opaque pointer to the SDK implementation
    ctx: *anyopaque,

    /// Function pointer to the SDK's getInstrumentationConfig implementation
    getInstrumentationConfigFn: *const fn (ctx: *anyopaque) ?ConfigProperties,

    /// Initialize a bridge from an SDK implementation
    /// The SDK implementation must have a `getInstrumentationConfig` method with signature:
    /// `fn getInstrumentationConfig(self: *const SdkType) ?ConfigProperties`
    pub fn init(ptr: anytype) ConfigProviderBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn getInstrumentationConfig(pointer: *anyopaque) ?ConfigProperties {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getInstrumentationConfig(self);
            }
        };

        return .{
            .ctx = @constCast(@ptrCast(ptr)),
            .getInstrumentationConfigFn = VTable.getInstrumentationConfig,
        };
    }
};
