//! std.log Bridge for OpenTelemetry
//!
//! This module provides a bridge between Zig's standard logging system (std.log)
//! and OpenTelemetry structured logging. It allows existing std.log code to work
//! unchanged while automatically emitting OpenTelemetry log records.
//!
//! ## Usage
//!
//! In your application's std_options:
//! ```zig
//! const std_log_bridge = @import("otel-sdk").std_log_bridge;
//!
//! pub const std_options = .{
//!     .log_level = .debug,
//!     .logFn = std_log_bridge.otelLogFn,
//! };
//! ```
//!
//! Then initialize the bridge after setting up your OTel providers:
//! ```zig
//! try std_log_bridge.init(.{});
//! defer std_log_bridge.deinit();
//! ```

const std = @import("std");
const io = std.Options.debug_io;
const api = @import("otel-api");

/// Configuration for the std.log bridge
pub const BridgeConfig = struct {
    /// Whether the bridge is enabled (if false, falls back to std.log.defaultLog)
    enabled: bool = true,

    /// Whether to include the std.log scope as an attribute
    include_scope_attribute: bool = true,

    /// Instrumentation scope name for all std.log messages
    instrumentation_scope_name: []const u8 = "std.log",

    /// Instrumentation scope version
    instrumentation_scope_version: ?[]const u8 = null,

    /// Also write every record through `std.log.defaultLog` (stderr). Without
    /// this the bridge REPLACES stderr output once initialized, which turns
    /// `fly logs` / journald / a terminal silent the moment export comes up.
    also_default_log: bool = false,

    /// Source of the active span for trace correlation. The bridge has no
    /// notion of "current span" of its own; a client SDK that tracks one
    /// (thread-local or otherwise) hands it over here so each record carries
    /// trace_id/span_id and renders under its span in the backend.
    span_context_fn: ?*const fn () ?api.trace.Span.Context = null,
};

/// Bridge state - kept minimal for performance
const BridgeState = struct {
    config: BridgeConfig,
    context: []api.ContextKeyValue,
    instrumentation_scope: api.InstrumentationScope,
    initialized: std.atomic.Value(bool),
};

/// Global bridge state
var bridge_state: BridgeState = undefined;
var bridge_mutex = std.Io.Mutex.init;

/// Initialize the std.log bridge
pub fn init(config: BridgeConfig) !void {
    bridge_mutex.lockUncancelable(io);
    defer bridge_mutex.unlock(io);

    if (bridge_state.initialized.load(.acquire)) return;

    // Create context - using page allocator since this is global state
    const context = try api.ContextKeyValue.initOwnedSlice(std.heap.page_allocator, &.{});
    errdefer api.ContextKeyValue.deinitOwnedSlice(std.heap.page_allocator, context);

    // Create instrumentation scope
    const instrumentation_scope = api.InstrumentationScope{
        .name = config.instrumentation_scope_name,
        .version = config.instrumentation_scope_version,
    };

    bridge_state = BridgeState{
        .config = config,
        .context = context,
        .instrumentation_scope = instrumentation_scope,
        .initialized = std.atomic.Value(bool).init(false),
    };

    bridge_state.initialized.store(true, .release);
}

/// Deinitialize the std.log bridge
pub fn deinit() void {
    bridge_mutex.lockUncancelable(io);
    defer bridge_mutex.unlock(io);

    if (!bridge_state.initialized.load(.acquire)) return;

    api.ContextKeyValue.deinitOwnedSlice(std.heap.page_allocator, bridge_state.context);
    bridge_state.initialized.store(false, .release);
}

/// Update bridge configuration at runtime
pub fn updateConfig(config: BridgeConfig) void {
    bridge_mutex.lockUncancelable(io);
    defer bridge_mutex.unlock(io);

    if (bridge_state.initialized.load(.acquire)) {
        bridge_state.config = config;
    }
}

/// Map std.log.Level to OpenTelemetry Severity
fn mapLogLevelToSeverity(level: std.log.Level) api.logs.Severity {
    return switch (level) {
        .err => .@"error", // std.log.err -> OTel ERROR (17)
        .warn => .warn, // std.log.warn -> OTel WARN (13)
        .info => .info, // std.log.info -> OTel INFO (9)
        .debug => .debug, // std.log.debug -> OTel DEBUG (5)
    };
}

/// OpenTelemetry logFn implementation
pub fn otelLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Fast path: if bridge not initialized or disabled, use default logging
    if (!bridge_state.initialized.load(.acquire) or !bridge_state.config.enabled) {
        std.log.defaultLog(level, scope, format, args);
        return;
    }

    if (bridge_state.config.also_default_log) std.log.defaultLog(level, scope, format, args);

    // Try to perform OTel logging, fall back to default on any error
    otelLogImpl(level, scope, format, args) catch {
        if (!bridge_state.config.also_default_log) std.log.defaultLog(level, scope, format, args);
    };
}

/// Internal OTel logging implementation
fn otelLogImpl(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) !void {
    // Get logger from global provider
    const logger_provider = api.getGlobalLoggerProvider();
    var logger = logger_provider.getLoggerWithScope(bridge_state.instrumentation_scope) catch {
        return error.LoggerCreationFailed;
    };

    // Map severity
    const severity = mapLogLevelToSeverity(level);

    // Early return if logging not enabled for this level
    if (!logger.enabled(bridge_state.context, severity)) return;

    // Format message - use stack buffer for efficiency
    var message_buf: [2048]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, format, args) catch |err| switch (err) {
        error.NoSpaceLeft => message_buf[0 .. message_buf.len - 12] ++ " [truncated]",
    };

    // The std.log scope is the closest thing zig has to a module name;
    // `code.module.name` is the semconv key the logfire rust/python clients
    // use for the same idea, so records group the same way across languages.
    const scope_attrs = [_]api.common.AttributeKeyValue{
        .{ .key = "code.module.name", .value = .{ .string = @tagName(scope) } },
    };
    const attributes: ?[]const api.common.AttributeKeyValue =
        if (bridge_state.config.include_scope_attribute) &scope_attrs else null;

    const span_ctx: ?api.trace.Span.Context = if (bridge_state.config.span_context_fn) |f| f() else null;

    logger.emitLogRecord(
        bridge_state.context,
        severity,
        .{ .string = message },
        attributes,
        @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)),
        null, // observed_timestamp_ns
        null, // event_name
        @tagName(level), // severity_text
        if (span_ctx) |c| c.trace_id else null,
        if (span_ctx) |c| c.span_id else null,
        if (span_ctx) |c| c.trace_flags else null,
    );
}

/// Check if the bridge is initialized and enabled
pub fn isEnabled() bool {
    return bridge_state.initialized.load(.acquire) and bridge_state.config.enabled;
}

/// Get current bridge configuration (thread-safe read)
pub fn getConfig() BridgeConfig {
    if (bridge_state.initialized.load(.acquire)) {
        return bridge_state.config;
    }
    return BridgeConfig{};
}

// Tests
test "std.log bridge initialization" {
    const testing = std.testing;

    // Test initialization
    try init(.{});
    defer deinit();

    try testing.expect(isEnabled());

    const config = getConfig();
    try testing.expect(config.enabled);
    try testing.expect(config.include_scope_attribute);
    try testing.expectEqualStrings("std.log", config.instrumentation_scope_name);
}

test "severity mapping" {
    const testing = std.testing;

    try testing.expectEqual(api.logs.Severity.@"error", mapLogLevelToSeverity(.err));
    try testing.expectEqual(api.logs.Severity.warn, mapLogLevelToSeverity(.warn));
    try testing.expectEqual(api.logs.Severity.info, mapLogLevelToSeverity(.info));
    try testing.expectEqual(api.logs.Severity.debug, mapLogLevelToSeverity(.debug));
}

test "config updates" {
    const testing = std.testing;

    try init(.{ .enabled = true });
    defer deinit();

    try testing.expect(isEnabled());

    updateConfig(.{ .enabled = false });
    try testing.expect(!isEnabled());

    updateConfig(.{ .enabled = true });
    try testing.expect(isEnabled());
}

test "fallback behavior" {

    // Test that otelLogFn works even when not initialized
    // This should not crash and should fall back to std.log.defaultLog
    otelLogFn(.info, .testing, "Test message {}", .{42});

    // Initialize and test normal operation
    try init(.{});
    defer deinit();

    otelLogFn(.info, .testing, "Test message {}", .{42});
}

test "scope attribute, severity text and span context reach the record" {
    const testing = std.testing;
    const Capture = struct {
        var records: usize = 0;
        var saw_scope = false;
        var saw_trace = false;
        var severity_text: ?[]const u8 = null;

        fn spanCtx() ?api.trace.Span.Context {
            return .{
                .trace_id = api.common.TraceId.fromBytes(@as([16]u8, @splat(7))),
                .span_id = api.common.SpanId.fromBytes(@as([8]u8, @splat(9))),
                .trace_flags = api.trace.Span.Context.SAMPLED_FLAG,
                .trace_state = null,
                .is_remote = false,
            };
        }

        pub fn enabled(_: *@This(), _: []const api.ContextKeyValue, _: ?api.logs.Severity) bool {
            return true;
        }
        pub fn enabledWithEvent(_: *@This(), _: []const api.ContextKeyValue, _: ?api.logs.Severity, _: []const u8) bool {
            return true;
        }
        pub fn emitLogRecord(
            _: *@This(),
            _: []const api.ContextKeyValue,
            _: ?api.logs.Severity,
            _: ?api.common.AttributeValue,
            attributes: ?[]const api.common.AttributeKeyValue,
            _: ?i64,
            _: ?i64,
            _: ?[]const u8,
            sev_text: ?[]const u8,
            trace_id: ?api.common.TraceId,
            _: ?api.common.SpanId,
            _: ?u8,
        ) void {
            records += 1;
            severity_text = sev_text;
            if (attributes) |attrs| for (attrs) |kv| {
                if (std.mem.eql(u8, kv.key, "code.module.name") and std.mem.eql(u8, kv.value.string, "bridge_test")) saw_scope = true;
            };
            if (trace_id) |t| saw_trace = std.mem.eql(u8, &t.bytes, &(@as([16]u8, @splat(7))));
        }
    };
    var capture = Capture{};
    const CaptureProvider = struct {
        logger_ptr: *Capture,
        pub fn getLoggerWithScope(self: *@This(), _: api.InstrumentationScope) !api.logs.Logger {
            return .{ .bridge = api.logs.LoggerBridge.init(self.logger_ptr) };
        }
    };
    var provider = CaptureProvider{ .logger_ptr = &capture };
    try api.provider_registry.setGlobalLoggerProvider(.{ .bridge = api.logs.LoggerProviderBridge.init(&provider) });
    defer api.provider_registry.unsetAllProviders();

    try init(.{ .span_context_fn = Capture.spanCtx });
    defer deinit();

    otelLogFn(.warn, .bridge_test, "hello {d}", .{1});
    try testing.expectEqual(@as(usize, 1), Capture.records);
    try testing.expect(Capture.saw_scope);
    try testing.expect(Capture.saw_trace);
    try testing.expectEqualStrings("warn", Capture.severity_text.?);
}
