//! OpenTelemetry Global Provider Registry
//!
//! Provides the common entry point for seting up providers.

const std = @import("std");
const io = std.Options.debug_io;
const logs = @import("logs/root.zig");
const trace = @import("trace/root.zig");
const metrics = @import("metrics/root.zig");
const config = @import("config/root.zig");
const context = @import("context/root.zig");

// Default global providers, if providers are not setup.
const default_logger_provider: logs.LoggerProvider = .{ .noop = {} };
const default_tracer_provider: trace.TracerProvider = .{ .noop = {} };
const default_meter_provider: metrics.MeterProvider = .{ .noop = {} };
const default_config_provider: config.ConfigProvider = .{ .noop = {} };
const default_text_map_propagator: context.TextMapPropagator = .{ .noop = {} };

// Global provider storage with thread safety
var global_logger_provider: std.atomic.Value(?*logs.LoggerProvider) = std.atomic.Value(?*logs.LoggerProvider).init(null);
var global_tracer_provider: std.atomic.Value(?*trace.TracerProvider) = std.atomic.Value(?*trace.TracerProvider).init(null);
var global_meter_provider: std.atomic.Value(?*metrics.MeterProvider) = std.atomic.Value(?*metrics.MeterProvider).init(null);
var global_config_provider: std.atomic.Value(?*config.ConfigProvider) = std.atomic.Value(?*config.ConfigProvider).init(null);
var global_text_map_propagator: std.atomic.Value(?*context.TextMapPropagator) = std.atomic.Value(?*context.TextMapPropagator).init(null);
var logger_mutex = std.Io.Mutex.init;
var tracer_mutex = std.Io.Mutex.init;
var meter_mutex = std.Io.Mutex.init;
var config_mutex = std.Io.Mutex.init;
var propagator_mutex = std.Io.Mutex.init;

pub fn getGlobalTextMapPropagator() *const context.TextMapPropagator {
    const propagator = global_text_map_propagator.load(.acquire);
    return if (propagator) |value| value else &default_text_map_propagator;
}

pub fn setGlobalTextMapPropagator(propagator: ?context.TextMapPropagator) !void {
    propagator_mutex.lockUncancelable(io);
    defer propagator_mutex.unlock(io);
    const old = global_text_map_propagator.load(.acquire);
    if (propagator) |value| {
        const pointer = try std.heap.page_allocator.create(context.TextMapPropagator);
        pointer.* = value;
        global_text_map_propagator.store(pointer, .release);
    } else {
        global_text_map_propagator.store(null, .release);
    }
    if (old) |pointer| std.heap.page_allocator.destroy(pointer);
}

/// Get the global logger provider. Fatal if a provider is not setup.
pub fn getGlobalLoggerProvider() *const logs.LoggerProvider {
    const provider = global_logger_provider.load(.acquire);
    return if (provider) |p| p else &default_logger_provider;
}

/// Set the global logger provider by value, managing interface wrapper memory internally.
/// Uses page allocator to manage the interface wrapper memory.
/// Returns error if allocation fails.
pub fn setGlobalLoggerProvider(provider: ?logs.LoggerProvider) !void {
    logger_mutex.lockUncancelable(io);
    defer logger_mutex.unlock(io);

    // Get old value atomically
    const old_provider = global_logger_provider.load(.acquire);

    if (provider) |new_provider| {
        // Allocate new interface wrapper using page allocator
        const provider_ptr = try std.heap.page_allocator.create(logs.LoggerProvider);
        provider_ptr.* = new_provider;

        // Store new provider atomically first
        global_logger_provider.store(provider_ptr, .release);
    } else {
        // Setting to null
        global_logger_provider.store(null, .release);
    }

    // Clean up old provider if exists
    if (old_provider) |old| {
        std.heap.page_allocator.destroy(old);
    }
}

/// Get the global tracer provider. Fatal if a provider is not setup.
pub fn getGlobalTracerProvider() *const trace.TracerProvider {
    const provider = global_tracer_provider.load(.acquire);
    return if (provider) |p| p else &default_tracer_provider;
}

/// Set the global tracer provider by value, managing interface wrapper memory internally.
/// Uses page allocator to manage the interface wrapper memory.
/// Returns error if allocation fails.
pub fn setGlobalTracerProvider(provider: ?trace.TracerProvider) !void {
    tracer_mutex.lockUncancelable(io);
    defer tracer_mutex.unlock(io);

    // Get old value atomically
    const old_provider = global_tracer_provider.load(.acquire);

    if (provider) |new_provider| {
        // Allocate new interface wrapper using page allocator
        const provider_ptr = try std.heap.page_allocator.create(trace.TracerProvider);
        provider_ptr.* = new_provider;

        // Store new provider atomically first
        global_tracer_provider.store(provider_ptr, .release);
    } else {
        // Setting to null
        global_tracer_provider.store(null, .release);
    }

    // Clean up old provider if exists
    if (old_provider) |old| {
        std.heap.page_allocator.destroy(old);
    }
}

/// Get the global meter provider
pub fn getGlobalMeterProvider() *const metrics.MeterProvider {
    const provider = global_meter_provider.load(.acquire);
    return if (provider) |p| p else &default_meter_provider;
}

/// Set the global meter provider, returns the old provider.
///
/// Callers responsiblitiy to manage the lifecycle of the returned, old provider.
pub fn setGlobalMeterProvider(provider: ?metrics.MeterProvider) !void {
    meter_mutex.lockUncancelable(io);
    defer meter_mutex.unlock(io);

    // Get old value atomically
    const old_provider = global_meter_provider.load(.acquire);

    if (provider) |new_provider| {
        // Allocate new interface wrapper using page allocator
        const provider_ptr = try std.heap.page_allocator.create(metrics.MeterProvider);
        provider_ptr.* = new_provider;

        // Store new provider atomically first
        global_meter_provider.store(provider_ptr, .release);
    } else {
        // Setting to null
        global_meter_provider.store(null, .release);
    }

    // Clean up old provider if exists
    if (old_provider) |old| {
        std.heap.page_allocator.destroy(old);
    }
}

/// Get the global config provider
pub fn getGlobalConfigProvider() *const config.ConfigProvider {
    const provider = global_config_provider.load(.acquire);
    return if (provider) |p| p else &default_config_provider;
}

/// Set the global config provider, managing interface wrapper memory internally.
/// Uses page allocator to manage the interface wrapper memory.
/// Returns error if allocation fails.
pub fn setGlobalConfigProvider(provider: ?config.ConfigProvider) !void {
    config_mutex.lockUncancelable(io);
    defer config_mutex.unlock(io);

    // Get old value atomically
    const old_provider = global_config_provider.load(.acquire);

    if (provider) |new_provider| {
        // Allocate new interface wrapper using page allocator
        const provider_ptr = try std.heap.page_allocator.create(config.ConfigProvider);
        provider_ptr.* = new_provider;

        // Store new provider atomically first
        global_config_provider.store(provider_ptr, .release);
    } else {
        // Setting to null
        global_config_provider.store(null, .release);
    }

    // Clean up old provider if exists
    if (old_provider) |old| {
        std.heap.page_allocator.destroy(old);
    }
}

/// Clean up all global providers by setting them to null.
/// This will automatically free any allocated interface wrappers.
pub fn unsetAllProviders() void {
    setGlobalLoggerProvider(null) catch {};
    setGlobalTracerProvider(null) catch {};
    setGlobalMeterProvider(null) catch {};
    setGlobalConfigProvider(null) catch {};
    setGlobalTextMapPropagator(null) catch {};
}

test "global text map propagator can be installed and reset" {
    defer setGlobalTextMapPropagator(null) catch {};
    try setGlobalTextMapPropagator(context.createW3cBaggagePropagator());
    const fields = try getGlobalTextMapPropagator().fields(std.testing.allocator);
    defer std.testing.allocator.free(fields);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("traceparent", fields[0]);
    try std.testing.expectEqualStrings("tracestate", fields[1]);
    try std.testing.expectEqualStrings("baggage", fields[2]);
}
