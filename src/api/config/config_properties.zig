//! OpenTelemetry Configuration Properties API
//!
//! This module defines the ConfigProperties interface for accessing configuration
//! mapping nodes. ConfigProperties represents a programmatic interface to a
//! configuration mapping node (like a YAML mapping).
//!
//! ConfigProperties follows the bridge pattern to allow SDK implementations
//! to provide concrete implementations while maintaining API stability.
//!
//! ## Usage
//!
//! ```zig
//! const config_props = config_provider.getInstrumentationConfig().?;
//! const http_config = config_props.get("general").get("http");
//! const headers = http_config.get("client").get("request_captured_headers");
//! ```

const std = @import("std");
const ConfigValue = @import("config_value.zig").ConfigValue;

/// ConfigProperties provides access to configuration properties within a mapping node.
/// It uses a tagged union with bridge pattern to allow SDK implementations.
pub const ConfigProperties = union(enum) {
    /// No-operation implementation that returns not_set for all queries
    noop: void,

    /// Bridge to SDK implementation
    bridge: ConfigPropertiesBridge,

    /// Get a configuration property by key
    /// Returns ConfigValue representing the property, or not_set if the key doesn't exist
    pub inline fn get(self: *const ConfigProperties, key: []const u8) ConfigValue {
        return switch (self.*) {
            .noop => .not_set,
            .bridge => |*bridge| bridge.getFn(bridge.ctx, key),
        };
    }
};

/// Bridge structure that holds SDK implementation pointer and vtable
/// This enables SDK implementations to plug into the API interface
pub const ConfigPropertiesBridge = struct {
    /// Opaque pointer to the SDK implementation
    ctx: *anyopaque,

    /// Function pointer to the SDK's get implementation
    getFn: *const fn (ctx: *anyopaque, key: []const u8) ConfigValue,

    /// Initialize a bridge from an SDK implementation
    /// The SDK implementation must have a `get` method with signature:
    /// `fn get(self: *const SdkType, key: []const u8) ConfigValue`
    pub fn init(ptr: anytype) ConfigPropertiesBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn get(pointer: *anyopaque, key: []const u8) ConfigValue {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.get(self, key);
            }
        };

        return .{
            .ctx = @constCast(@ptrCast(ptr)),
            .getFn = VTable.get,
        };
    }
};
