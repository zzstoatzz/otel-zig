//! OpenTelemetry Global Provider Registry
//!
//! This module manages global providers for all OpenTelemetry signals (logs, traces, metrics).
//! It provides thread-safe access to global providers and convenience functions for
//! obtaining loggers, tracers, and meters.
//!
//! ## Design
//! - Uses static storage with mutex protection for thread safety
//! - Provides default no-op providers when not configured
//! - Allows runtime configuration of providers
//!
//! ## Usage
//! ```zig
//! const otel_api = @import("otel-api");
//! 
//! // Set a global logger provider
//! otel_api.provider_registry.setGlobalLoggerProvider(my_provider);
//! 
//! // Get a logger from the global provider
//! const logger = otel_api.provider_registry.getGlobalLogger("my.service");
//! ```

const std = @import("std");
const logs = @import("logs/root.zig");
const trace = @import("trace/root.zig");
const metrics = @import("metrics/root.zig");

// Global provider storage with thread safety
var global_logger_provider: ?*logs.LoggerProvider = null;
var global_tracer_provider: ?*trace.TracerProvider = null;
var global_meter_provider: ?*metrics.MeterProvider = null;
var mutex = std.Thread.Mutex{};

// Track whether global providers are owned by the registry (and should be freed on reset)
var logger_provider_owned_by_registry = false;
var tracer_provider_owned_by_registry = false;
var meter_provider_owned_by_registry = false;

// Default allocator for no-op providers
var noop_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

// Logger Provider Management

/// Get the global logger provider, returning a no-op provider if none is set
pub fn getGlobalLoggerProvider() *logs.LoggerProvider {
    mutex.lock();
    defer mutex.unlock();
    
    if (global_logger_provider) |provider| {
        return provider;
    }
    
    // Create and cache a no-op provider
    const provider = noop_arena.allocator().create(logs.LoggerProvider) catch unreachable;
    provider.* = logs.createNoopProvider(noop_arena.allocator());
    global_logger_provider = provider;
    logger_provider_owned_by_registry = true;
    return provider;
}

/// Set the global logger provider
pub fn setGlobalLoggerProvider(provider: *logs.LoggerProvider) void {
    mutex.lock();
    defer mutex.unlock();
    
    // If we currently have a registry-owned provider, clean it up first
    if (global_logger_provider != null and logger_provider_owned_by_registry) {
        if (global_logger_provider) |old_provider| {
            old_provider.deinit();
            noop_arena.allocator().destroy(old_provider);
        }
    }
    
    global_logger_provider = provider;
    logger_provider_owned_by_registry = false; // User-provided provider
}

/// Reset the global logger provider to no-op
pub fn resetGlobalLoggerProvider() void {
    mutex.lock();
    defer mutex.unlock();
    
    // Only clean up providers that are owned by the registry
    if (global_logger_provider != null and logger_provider_owned_by_registry) {
        if (global_logger_provider) |provider| {
            provider.deinit();
            noop_arena.allocator().destroy(provider);
        }
    }
    
    global_logger_provider = null;
    logger_provider_owned_by_registry = false;
}

/// Get a logger from the global provider with just a name
pub fn getGlobalLogger(name: []const u8) !*logs.Logger {
    const provider = getGlobalLoggerProvider();
    return provider.getLoggerWithName(name);
}

/// Get a logger from the global provider with name and version
pub fn getGlobalLoggerWithVersion(name: []const u8, version: []const u8) !*logs.Logger {
    const provider = getGlobalLoggerProvider();
    return provider.getLoggerWithVersion(name, version);
}

// Tracer Provider Management (placeholder until trace API is implemented)

/// Get the global tracer provider
pub fn getGlobalTracerProvider() *trace.TracerProvider {
    mutex.lock();
    defer mutex.unlock();
    
    if (global_tracer_provider) |provider| {
        return provider;
    }
    
    // TODO: Return no-op provider when trace API is implemented
    unreachable;
}

/// Set the global tracer provider
pub fn setGlobalTracerProvider(provider: *trace.TracerProvider) void {
    mutex.lock();
    defer mutex.unlock();
    
    global_tracer_provider = provider;
}

/// Reset the global tracer provider
pub fn resetGlobalTracerProvider() void {
    mutex.lock();
    defer mutex.unlock();
    
    global_tracer_provider = null;
}

// Meter Provider Management (placeholder until metrics API is implemented)

/// Get the global meter provider
pub fn getGlobalMeterProvider() *metrics.MeterProvider {
    mutex.lock();
    defer mutex.unlock();
    
    if (global_meter_provider) |provider| {
        return provider;
    }
    
    // TODO: Return no-op provider when metrics API is implemented
    unreachable;
}

/// Set the global meter provider
pub fn setGlobalMeterProvider(provider: *metrics.MeterProvider) void {
    mutex.lock();
    defer mutex.unlock();
    
    global_meter_provider = provider;
}

/// Reset the global meter provider
pub fn resetGlobalMeterProvider() void {
    mutex.lock();
    defer mutex.unlock();
    
    global_meter_provider = null;
}

/// Clean up all global providers
pub fn deinit() void {
    resetGlobalLoggerProvider();
    resetGlobalTracerProvider();
    resetGlobalMeterProvider();
    noop_arena.deinit();
}

test "global logger provider management" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Reset to ensure clean state
    resetGlobalLoggerProvider();
    
    // Should get no-op provider by default
    const default_provider = getGlobalLoggerProvider();
    try testing.expect(default_provider.* == .noop);
    
    // Create and set a custom provider
    var custom_provider = logs.createNoopProvider(allocator);
    setGlobalLoggerProvider(&custom_provider);
    
    // Should get the custom provider
    const retrieved = getGlobalLoggerProvider();
    try testing.expectEqual(&custom_provider, retrieved);
    
    // Get a logger
    const logger = try getGlobalLogger("test.service");
    try testing.expect(logger.* == .noop);
    
    // Clean up
    resetGlobalLoggerProvider();
    custom_provider.deinit();
}

test "global logger convenience functions" {
    const testing = std.testing;
    
    // Reset to ensure clean state
    resetGlobalLoggerProvider();
    
    // Get logger with just name
    const logger1 = try getGlobalLogger("test.logger");
    try testing.expect(logger1.* == .noop);
    try testing.expectEqualStrings("test.logger", logger1.getInstrumentationScope().name);
    
    // Get logger with version
    const logger2 = try getGlobalLoggerWithVersion("test.logger", "1.0.0");
    try testing.expect(logger2.* == .noop);
    try testing.expectEqualStrings("test.logger", logger2.getInstrumentationScope().name);
    try testing.expectEqualStrings("1.0.0", logger2.getInstrumentationScope().version.?);
}