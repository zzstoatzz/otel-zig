//! OpenTelemetry Logger SDK Implementation
//!
//! This module provides concrete implementations of the Logger interface.
//! The SDK provides StandardLogger and CustomLogger implementations that can be
//! used with the API's Logger interface.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md

const std = @import("std");
const otel_api = @import("otel-api");

const Context = otel_api.Context;
const LogRecord = @import("log_record.zig").LogRecord;
const Severity = otel_api.logs.Severity;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const AttributeValue = otel_api.common.AttributeValue;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
pub const Logger = otel_api.logs.Logger;
const Resource = @import("../resource/resource.zig").Resource;
const LogProcessor = @import("processor.zig").LogProcessor;

/// Standard logger implementation with configurable severity and handler
pub const StandardLogger = struct {
    allocator: std.mem.Allocator,
    scope: InstrumentationScope,
    min_severity: Severity = .invalid,
    resource: Resource,
    handler: LogProcessor,

    pub fn init(
        allocator: std.mem.Allocator,
        scope: InstrumentationScope,
        min_severity: Severity,
        resource: Resource,
        handler: LogProcessor,
    ) StandardLogger {
        return .{
            .allocator = allocator,
            .scope = scope,
            .min_severity = min_severity,
            .resource = resource,
            .handler = handler,
        };
    }

    pub fn deinit(self: *StandardLogger) void {
        _ = self;
    }

    pub inline fn emitLogRecord(
        self: *StandardLogger,
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
        const record_severity = severity orelse .invalid;

        // Check severity filtering
        if (self.enabled(ctx, record_severity)) {
            // Construct LogRecord from individual parameters
            const record = LogRecord{
                .timestamp_ns = timestamp_ns,
                .observed_timestamp_ns = observed_timestamp_ns,
                .severity_number = record_severity,
                .severity_text = severity_text,
                .body = body,
                .event_name = event_name,
                .attributes = attributes orelse &[_]AttributeKeyValue{},
                .trace_id = trace_id,
                .span_id = span_id,
                .flags = flags,
                .instrumentation_scope = self.scope,
            };

            self.handler.onEmit(record, ctx, self.resource);
        }
    }

    pub inline fn enabled(self: *const StandardLogger, ctx: Context, severity: Severity) bool {
        _ = ctx;
        // Compare severity levels for filtering
        return @intFromEnum(severity) >= @intFromEnum(self.min_severity);
    }

    pub inline fn enabledWithEvent(
        self: *const StandardLogger,
        ctx: Context,
        severity: Severity,
        event_name: []const u8,
    ) bool {
        _ = event_name;
        return self.enabled(ctx, severity);
    }

    pub inline fn setMinimumSeverity(self: *StandardLogger, severity: Severity) void {
        self.min_severity = severity;
    }

    pub inline fn getResource(self: *const StandardLogger) *const Resource {
        return self.resource;
    }

    pub inline fn getInstrumentationScope(self: *const StandardLogger) InstrumentationScope {
        return self.scope;
    }
};
