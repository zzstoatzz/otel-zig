//! OpenTelemetry API

const std = @import("std");

pub const logs = @import("logs/root.zig");
pub const trace = @import("trace/root.zig");
pub const metrics = @import("metrics/root.zig");
pub const baggage = @import("baggage/root.zig");
pub const context = @import("context/root.zig");
pub const common = @import("common/root.zig");
pub const provider_registry = @import("provider_registry.zig");

// Re-export commonly used types at the root level for convenience
pub const Context = context.Context;
pub const AttributeBuilder = common.AttributeBuilder;
pub const AttributeKeyValue = common.AttributeKeyValue;
pub const AttributeValue = common.AttributeValue;
pub const InstrumentationScope = common.InstrumentationScope;

pub const getGlobalLoggerProvider = provider_registry.getGlobalLoggerProvider;
pub const getGlobalMeterProvider = provider_registry.getGlobalMeterProvider;
pub const getGlobalTracerProvider = provider_registry.getGlobalTracerProvider;

test "api module compilation" {
    std.testing.refAllDecls(@This());
}
