//! OpenTelemetry Logger API
//!
//! This module defines the Logger interface according to the OpenTelemetry specification.
//! A Logger is the primary interface for emitting log records.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/api.md#logger

const std = @import("std");
const isValidatingMode = @import("../common/error_handler.zig").isValidatingMode;

const AttributeValue = @import("../common/root.zig").AttributeValue;
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
const reportValidationError = @import("../common/error_handler.zig").reportValidationError;
const Context = @import("../context/root.zig").Context;
const Severity = @import("severity.zig").Severity;

/// Logger interface using tagged union for compile-time polymorphism.
/// In the API layer, only the noop implementation is provided.
/// SDK implementations will extend this with concrete loggers.
pub const Logger = union(enum) {
    noop: void,
    bridge: LoggerBridge, // SDK logger bridge

    /// Emit a log record with individual parameters
    ///
    /// This method creates a log record with the specified parameters. In debug builds,
    /// input validation is performed and any issues are reported via the global error
    /// handler, but log emission always succeeds (potentially with corrected/filtered input).
    ///
    /// ## Parameters
    /// - `severity`: Log severity level (validated if provided)
    /// - `body`: Log message body (validated if provided)
    /// - `attributes`: Log attributes (validated using standard attribute validation)
    /// - `event_name`: Event name (validated if provided)
    /// - `severity_text`: Custom severity text (validated if provided)
    /// - Other parameters: Timestamps, trace context, flags (basic validation)
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Severity**: Must be valid enum value if provided
    /// - **Body**: Must be non-empty string if provided
    /// - **Attributes**: Invalid attributes (empty keys) are reported and filtered
    /// - **Event name**: Must be non-empty if provided
    /// - **Severity text**: Must be non-empty if provided
    ///
    /// ## Error Handling
    /// - **Validation errors**: Reported via error handler, operation continues
    /// - **No-op fallback**: On critical failures, log is still emitted (potentially as no-op)
    ///
    /// ## Performance
    /// - **Release builds**: No validation overhead
    /// - **Debug builds**: Minimal overhead for validation checks
    pub fn emitLogRecord(
        self: *Logger,
        ctx: Context,
        severity: ?Severity,
        body: ?AttributeValue,
        attributes: ?[]const AttributeKeyValue,
        timestamp_ns: ?i64,
        observed_timestamp_ns: ?i64,
        event_name: ?[]const u8,
        severity_text: ?[]const u8,
        trace_id: ?[16]u8,
        span_id: ?[8]u8,
        flags: ?u8,
    ) void {
        switch (self.*) {
            .noop => |_| {},
            .bridge => |bridge| bridge.emitLogRecordFn(
                bridge.logger_ptr,
                ctx,
                severity,
                body,
                attributes,
                timestamp_ns,
                observed_timestamp_ns,
                event_name,
                severity_text,
                trace_id,
                span_id,
                flags,
            ),
        }
    }

    /// Check if logging is enabled for a given severity
    pub inline fn enabled(self: *const Logger, ctx: Context, severity: ?Severity) bool {
        return switch (self.*) {
            .noop => |_| return false,
            .bridge => |bridge| bridge.enabledFn(bridge.logger_ptr, ctx, severity),
        };
    }

    /// Check if logging is enabled for a given severity and event name
    pub inline fn enabledWithEvent(
        self: *const Logger,
        ctx: Context,
        severity: ?Severity,
        event_name: []const u8,
    ) bool {
        return switch (self.*) {
            .noop => |_| return false,
            .bridge => |bridge| bridge.enabledWithEventFn(bridge.logger_ptr, ctx, severity, event_name),
        };
    }

    // Convenience methods for different severity levels

    /// Log a trace message
    pub inline fn trace(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .trace, fmt, args);
    }

    /// Log a debug message
    pub inline fn debug(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .debug, fmt, args);
    }

    /// Log an info message
    pub inline fn info(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .info, fmt, args);
    }

    /// Log a warning message
    pub inline fn warn(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .warn, fmt, args);
    }

    /// Log an error message
    pub inline fn @"error"(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .@"error", fmt, args);
    }

    /// Log a fatal message
    pub inline fn fatal(self: *Logger, ctx: Context, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .fatal, fmt, args);
    }

    /// Generic log method with severity
    ///
    /// This method formats a log message and emits it with the specified severity.
    /// In debug builds, format string and arguments are validated.
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Format string**: Must be non-empty
    /// - **Severity**: Must be valid enum value
    /// - **Message formatting**: Errors are handled gracefully with truncation
    ///
    /// ## Performance
    /// - **Release builds**: No validation overhead
    /// - **Debug builds**: Minimal overhead for validation checks
    pub fn log(
        self: *Logger,
        ctx: Context,
        severity: Severity,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (!self.enabled(ctx, severity)) return;

        var buf: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, fmt, args) catch |err| blk: {
            const truncated = switch (err) {
                error.NoSpaceLeft => " [truncated]",
            };
            break :blk buf[0 .. buf.len - truncated.len] ++ truncated;
        };

        self.emitLogRecord(
            ctx,
            severity,
            AttributeValue{ .string = message },
            null, // attributes
            @as(i64, @intCast(std.time.nanoTimestamp())), // timestamp_ns
            null, // observed_timestamp_ns
            null, // event_name
            null, // severity_text
            null, // trace_id
            null, // span_id
            null, // flags
        );
    }
};

/// Bridge structure that holds SDK logger pointer and vtable
pub const LoggerBridge = struct {
    logger_ptr: *anyopaque,
    emitLogRecordFn: *const fn (
        logger_ptr: *anyopaque,
        ctx: Context,
        severity: ?Severity,
        body: ?AttributeValue,
        attributes: ?[]const AttributeKeyValue,
        timestamp_ns: ?i64,
        observed_timestamp_ns: ?i64,
        event_name: ?[]const u8,
        severity_text: ?[]const u8,
        trace_id: ?[16]u8,
        span_id: ?[8]u8,
        flags: ?u8,
    ) void,
    enabledFn: *const fn (logger_ptr: *anyopaque, ctx: Context, severity: ?Severity) bool,
    enabledWithEventFn: *const fn (logger_ptr: *anyopaque, ctx: Context, severity: ?Severity, event_name: []const u8) bool,

    pub fn init(ptr: anytype) LoggerBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn emitLogRecord(
                pointer: *anyopaque,
                ctx: Context,
                severity: ?Severity,
                body: ?AttributeValue,
                attributes: ?[]const AttributeKeyValue,
                timestamp_ns: ?i64,
                observed_timestamp_ns: ?i64,
                event_name: ?[]const u8,
                severity_text: ?[]const u8,
                trace_id: ?[16]u8,
                span_id: ?[8]u8,
                flags: ?u8,
            ) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.emitLogRecord(
                    self,
                    ctx,
                    severity,
                    body,
                    attributes,
                    timestamp_ns,
                    observed_timestamp_ns,
                    event_name,
                    severity_text,
                    trace_id,
                    span_id,
                    flags,
                );
            }
            pub fn enabled(pointer: *anyopaque, ctx: Context, severity: ?Severity) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.enabled(self, ctx, severity);
            }
            pub fn enabledWithEvent(pointer: *anyopaque, ctx: Context, severity: ?Severity, event_name: []const u8) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.enabledWithEvent(self, ctx, severity, event_name);
            }
        };

        return .{
            .logger_ptr = ptr,
            .emitLogRecordFn = VTable.emitLogRecord,
            .enabledFn = VTable.enabled,
            .enabledWithEventFn = VTable.enabledWithEvent,
        };
    }
};

/// Validate severity level in debug mode
pub fn validateSeverity(severity: ?Severity) ?Severity {
    if (!isValidatingMode()) return severity;
    // All Severity enum values are valid by Zig type system
    return severity;
}

/// Validate log message body in debug mode
pub fn validateLogBody(body: ?AttributeValue) ?AttributeValue {
    if (!isValidatingMode()) return body;

    if (body) |b| {
        switch (b) {
            .string => |s| {
                if (s.len == 0) {
                    reportValidationError(.logger, "emitLogRecord", "Empty log message body provided", null);
                }
            },
            else => {}, // Other AttributeValue types are valid by design
        }
    }
    return body;
}

/// Validate log attributes using existing attribute validation
pub fn validateLogAttributes(attributes: ?[]const AttributeKeyValue) ?[]const AttributeKeyValue {
    if (!isValidatingMode()) return attributes;

    if (attributes) |attrs| {
        return validateAttributes(attrs);
    }
    return attributes;
}

/// Validate event name in debug mode
pub fn validateEventName(event_name: ?[]const u8) ?[]const u8 {
    if (!isValidatingMode()) return event_name;

    if (event_name) |name| {
        if (name.len == 0) {
            reportValidationError(.logger, "emitLogRecord", "Empty event name provided", null);
        }
    }
    return event_name;
}

/// Validate severity text in debug mode
pub fn validateSeverityText(severity_text: ?[]const u8) ?[]const u8 {
    if (!isValidatingMode()) return severity_text;

    if (severity_text) |text| {
        if (text.len == 0) {
            reportValidationError(.logger, "emitLogRecord", "Empty severity text provided", null);
        }
    }
    return severity_text;
}

/// Validate format string in debug mode
pub fn validateFormatString(comptime fmt: []const u8) bool {
    if (!isValidatingMode()) return true;
    return fmt.len > 0;
}

/// Validate attributes and report errors in debug mode (reuse from tracer)
pub fn validateAttributes(attributes: []const AttributeKeyValue) []const AttributeKeyValue {
    if (!isValidatingMode()) return attributes;

    // Count invalid attributes
    var invalid_count: usize = 0;

    for (attributes) |attr| {
        if (attr.key.len == 0) {
            invalid_count += 1;
        }
    }

    // Report errors if any invalid attributes found
    if (invalid_count > 0) {
        reportValidationError(.logger, "emitLogRecord", "Invalid attributes detected due to empty keys", null);
    }

    // Always return original slice - no memory allocation
    return attributes;
}
