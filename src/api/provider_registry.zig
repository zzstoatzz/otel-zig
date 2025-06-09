//! OpenTelemetry Global Provider Registry
//!
//! Provides the common entry point for seting up providers.

const std = @import("std");
const logs = @import("logs/root.zig");
const trace = @import("trace/root.zig");
const metrics = @import("metrics/root.zig");

// Global provider storage with thread safety
var global_logger_provider: ?*logs.LoggerProvider = null;
var global_tracer_provider: ?*trace.TracerProvider = null;
var global_meter_provider: ?*metrics.MeterProvider = null;
var mutex = std.Thread.Mutex{};

/// Get the global logger provider. Fatal if a provider is not setup.
pub fn getGlobalLoggerProvider() *logs.LoggerProvider {
    mutex.lock();
    defer mutex.unlock();

    if (global_logger_provider) |provider| {
        return provider;
    }
    unreachable;
}

/// Set the global logger provider, returns the old provider.
///
/// Callers responsiblitiy to manage the lifecycle of the returned, old provider.
pub fn setGlobalLoggerProvider(provider: ?*logs.LoggerProvider) ?*logs.LoggerProvider {
    mutex.lock();
    defer mutex.unlock();
    const old_provider = global_logger_provider;
    global_logger_provider = provider;
    return old_provider;
}

/// Get the global tracer provider. Fatal if a provider is not setup.
pub fn getGlobalTracerProvider() *trace.TracerProvider {
    mutex.lock();
    defer mutex.unlock();

    if (global_tracer_provider) |provider| {
        return provider;
    }
    unreachable;
}

/// Set the global tracer provider, returns the old provider.
///
/// Callers responsiblitiy to manage the lifecycle of the returned, old provider.
pub fn setGlobalTracerProvider(provider: ?*trace.TracerProvider) ?*trace.TracerProvider {
    mutex.lock();
    defer mutex.unlock();

    const old_provider = global_tracer_provider;
    global_tracer_provider = provider;
    return old_provider;
}

/// Get the global meter provider
pub fn getGlobalMeterProvider() *metrics.MeterProvider {
    mutex.lock();
    defer mutex.unlock();

    if (global_meter_provider) |provider| {
        return provider;
    }
    unreachable;
}

/// Set the global meter provider, returns the old provider.
///
/// Callers responsiblitiy to manage the lifecycle of the returned, old provider.
pub fn setGlobalMeterProvider(provider: ?*metrics.MeterProvider) ?*metrics.MeterProvider {
    mutex.lock();
    defer mutex.unlock();

    const old_provider = global_meter_provider;
    global_meter_provider = provider;
    return old_provider;
}

/// Clean up all global providers
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();

    if (setGlobalLoggerProvider(null)) |old_provider| old_provider.deinit();
    if (setGlobalTracerProvider(null)) |old_provider| old_provider.deinit();
    if (setGlobalMeterProvider(null)) |old_provider| old_provider.deinit();
}
