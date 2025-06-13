//! OpenTelemetry Span API
//!
//! This module defines the Span interface according to the OpenTelemetry specification.
//! A Span represents a unit of work within a trace.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#span

const std = @import("std");

const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const AttributeValue = @import("../common/root.zig").AttributeValue;
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
const Context = @import("../context/root.zig").Context;
const SpanContext = @import("span_context.zig").SpanContext;
const Event = @import("event.zig").Event;

/// Span interface using tagged union for compile-time polymorphism.
/// In the API layer, only the noop implementation is provided.
/// SDK implementations will extend this with concrete spans.
pub const Span = union(enum) {
    noop: SpanContext,
    bridge: SpanBridge, // SDK span bridge

    /// Add an attribute to the span
    pub inline fn setAttribute(
        self: *const Span,
        key: []const u8,
        value: AttributeValue,
    ) !void {
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.setAttributeFn(bridge.span_ptr, key, value),
        }
    }

    /// Add multiple attributes to the span
    pub inline fn setAttributes(
        self: *const Span,
        attributes: []const AttributeKeyValue,
    ) !void {
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.setAttributesFn(bridge.span_ptr, attributes),
        }
    }

    /// Add an event to the span
    pub inline fn addEvent(
        self: *const Span,
        event: Event,
    ) !void {
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.addEventFn(bridge.span_ptr, event),
        }
    }

    /// Add a link to another span
    pub inline fn addLink(
        self: *const Span,
        link: Link,
    ) !void {
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.addLinkFn(bridge.span_ptr, link),
        }
    }

    /// Record an exception as an event on the span
    pub inline fn recordException(
        self: *const Span,
        exception: anyerror,
        attributes: ?[]const AttributeKeyValue,
        timestamp_ns: ?i64,
    ) !void {
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.recordExceptionFn(bridge.span_ptr, exception, attributes, timestamp_ns),
        }
    }

    /// Set the status of the span
    pub inline fn setStatus(
        self: *const Span,
        status: Status,
    ) !void {
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.setStatusFn(bridge.span_ptr, status),
        }
    }

    /// Update the span name
    pub inline fn updateName(
        self: *const Span,
        name: []const u8,
    ) !void {
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.updateNameFn(bridge.span_ptr, name),
        }
    }

    /// End the span with optional end options
    pub inline fn end(
        self: *const Span,
        options: ?SpanEndOptions,
    ) void {
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| bridge.endFn(bridge.span_ptr, options),
        }
    }

    /// Check if the span is recording (accepting data)
    pub inline fn isRecording(self: *const Span) bool {
        return switch (self.*) {
            .noop => |_| false,
            .bridge => |bridge| bridge.isRecordingFn(bridge.span_ptr),
        };
    }

    /// Get the span context for this span
    pub inline fn getSpanContext(self: *const Span) SpanContext {
        return switch (self.*) {
            .noop => |span_context| span_context,
            .bridge => |bridge| bridge.getSpanContextFn(bridge.span_ptr),
        };
    }

    /// Clean up span resources
    pub inline fn deinit(self: *const Span) void {
        switch (self.*) {
            .noop => |_| {},
            .bridge => |bridge| bridge.deinitFn(bridge.span_ptr),
        }
    }
};

/// Bridge structure that holds SDK span pointer and vtable
pub const SpanBridge = struct {
    span_ptr: *anyopaque,
    setAttributeFn: *const fn (span_ptr: *anyopaque, key: []const u8, value: AttributeValue) anyerror!void,
    setAttributesFn: *const fn (span_ptr: *anyopaque, attributes: []const AttributeKeyValue) anyerror!void,
    addEventFn: *const fn (span_ptr: *anyopaque, event: Event) anyerror!void,
    addLinkFn: *const fn (span_ptr: *anyopaque, link: Link) anyerror!void,
    recordExceptionFn: *const fn (span_ptr: *anyopaque, exception: anyerror, attributes: ?[]const AttributeKeyValue, timestamp_ns: ?i64) anyerror!void,
    setStatusFn: *const fn (span_ptr: *anyopaque, status: Status) anyerror!void,
    updateNameFn: *const fn (span_ptr: *anyopaque, name: []const u8) anyerror!void,
    endFn: *const fn (span_ptr: *anyopaque, options: ?SpanEndOptions) void,
    isRecordingFn: *const fn (span_ptr: *anyopaque) bool,
    getSpanContextFn: *const fn (span_ptr: *anyopaque) SpanContext,
    deinitFn: *const fn (span_ptr: *anyopaque) void,

    pub fn init(ptr: anytype) SpanBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn setAttribute(pointer: *anyopaque, key: []const u8, value: AttributeValue) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.setAttribute(self, key, value);
            }
            pub fn setAttributes(pointer: *anyopaque, attributes: []const AttributeKeyValue) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.setAttributes(self, attributes);
            }
            pub fn addEvent(pointer: *anyopaque, event: Event) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.addEvent(self, event);
            }
            pub fn addLink(pointer: *anyopaque, link: Link) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.addLink(self, link);
            }
            pub fn recordException(pointer: *anyopaque, exception: anyerror, attributes: ?[]const AttributeKeyValue, timestamp_ns: ?i64) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.recordException(self, exception, attributes, timestamp_ns);
            }
            pub fn setStatus(pointer: *anyopaque, status: Status) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.setStatus(self, status);
            }
            pub fn updateName(pointer: *anyopaque, name: []const u8) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.updateName(self, name);
            }
            pub fn end(pointer: *anyopaque, options: ?SpanEndOptions) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.end(self, options);
            }
            pub fn isRecording(pointer: *anyopaque) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.isRecording(self);
            }
            pub fn getSpanContext(pointer: *anyopaque) SpanContext {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getSpanContext(self);
            }
            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.deinit(self);
            }
        };

        return .{
            .span_ptr = ptr,
            .setAttributeFn = VTable.setAttribute,
            .setAttributesFn = VTable.setAttributes,
            .addEventFn = VTable.addEvent,
            .addLinkFn = VTable.addLink,
            .recordExceptionFn = VTable.recordException,
            .setStatusFn = VTable.setStatus,
            .updateNameFn = VTable.updateName,
            .endFn = VTable.end,
            .isRecordingFn = VTable.isRecording,
            .getSpanContextFn = VTable.getSpanContext,
            .deinitFn = VTable.deinit,
        };
    }
};

/// SpanKind describes the relationship between the Span, its parents, and its children
pub const SpanKind = enum(u8) {
    /// Internal span represents an internal operation within an application
    internal,

    /// Server span represents a request received by a server
    server,

    /// Client span represents a request made by a client
    client,

    /// Producer span represents a message sent to a message broker or queue
    producer,

    /// Consumer span represents a message received from a message broker or queue
    consumer,

    /// Convert SpanKind to its string representation
    pub fn toString(self: SpanKind) []const u8 {
        return switch (self) {
            .internal => "internal",
            .server => "server",
            .client => "client",
            .producer => "producer",
            .consumer => "consumer",
        };
    }

    /// Parse SpanKind from string representation
    pub fn fromString(str: []const u8) ?SpanKind {
        if (std.mem.eql(u8, str, "internal")) return .internal;
        if (std.mem.eql(u8, str, "server")) return .server;
        if (std.mem.eql(u8, str, "client")) return .client;
        if (std.mem.eql(u8, str, "producer")) return .producer;
        if (std.mem.eql(u8, str, "consumer")) return .consumer;
        return null;
    }

    /// Format SpanKind for debugging
    pub fn format(self: SpanKind, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(self.toString());
    }
};

/// SpanStartOptions defines configuration options for creating a span
pub const SpanStartOptions = struct {
    /// Parent context to use for the span
    /// If null, will attempt to get parent from current context
    parent_context: ?Context = null,

    /// Kind of the span (defaults to internal)
    kind: SpanKind = .internal,

    /// Initial attributes to set on the span
    attributes: ?[]const AttributeKeyValue = null,

    /// Links to other spans
    links: ?[]const Link = null,

    /// Custom start time in nanoseconds since Unix epoch
    /// If null, current time will be used
    start_time_ns: ?i64 = null,

    /// Whether this span should be recorded even if not sampled
    /// This affects the IsRecording flag
    record: bool = true,

    /// Create default span start options
    pub const default = SpanStartOptions{};

    /// Check if this options struct has a parent context
    pub fn hasParentContext(self: SpanStartOptions) bool {
        return self.parent_context != null;
    }

    /// Check if this options struct has attributes
    pub fn hasAttributes(self: SpanStartOptions) bool {
        return self.attributes != null and self.attributes.?.len > 0;
    }

    /// Check if this options struct has links
    pub fn hasLinks(self: SpanStartOptions) bool {
        return self.links != null and self.links.?.len > 0;
    }

    /// Check if this options struct has a custom start time
    pub fn hasCustomStartTime(self: SpanStartOptions) bool {
        return self.start_time_ns != null;
    }

    /// Get the number of attributes
    pub fn getAttributeCount(self: SpanStartOptions) usize {
        return if (self.attributes) |attrs| attrs.len else 0;
    }

    /// Get the number of links
    pub fn getLinkCount(self: SpanStartOptions) usize {
        return if (self.links) |links| links.len else 0;
    }

    /// Format SpanStartOptions for debugging
    pub fn format(self: SpanStartOptions, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("SpanStartOptions{{kind={}, record={}", .{ self.kind, self.record });

        if (self.parent_context != null) {
            try writer.writeAll(", has_parent=true");
        }

        if (self.hasAttributes()) {
            try writer.print(", attributes={}", .{self.getAttributeCount()});
        }

        if (self.hasLinks()) {
            try writer.print(", links={}", .{self.getLinkCount()});
        }

        if (self.start_time_ns) |time| {
            try writer.print(", start_time_ns={}", .{time});
        }

        try writer.writeAll("}");
    }
};

/// SpanEndOptions defines configuration options for ending a span
pub const SpanEndOptions = struct {
    /// Custom end time in nanoseconds since Unix epoch
    /// If null, current time will be used when the span is ended
    end_time_ns: ?i64 = null,

    /// Create default span end options
    pub const default: SpanEndOptions = .{};

    /// Create span end options with a custom end time
    pub fn withEndTime(end_time_ns: i64) SpanEndOptions {
        return SpanEndOptions{
            .end_time_ns = end_time_ns,
        };
    }

    /// Create span end options with current system time
    pub fn withCurrentTime() SpanEndOptions {
        const current_time_ns: i64 = @intCast(std.time.nanoTimestamp());
        return SpanEndOptions{
            .end_time_ns = current_time_ns,
        };
    }

    /// Check if this options struct has a custom end time
    pub fn hasCustomEndTime(self: SpanEndOptions) bool {
        return self.end_time_ns != null;
    }

    /// Get the end time, or return a default if not set
    pub fn getEndTimeOrDefault(self: SpanEndOptions, default_time_ns: i64) i64 {
        return self.end_time_ns orelse default_time_ns;
    }

    /// Create a copy of these options with a different end time
    pub fn replaceEndTime(self: SpanEndOptions, end_time_ns: ?i64) SpanEndOptions {
        _ = self;
        return SpanEndOptions{
            .end_time_ns = end_time_ns,
        };
    }

    /// Format SpanEndOptions for debugging
    pub fn format(self: SpanEndOptions, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("SpanEndOptions{");

        if (self.end_time_ns) |time| {
            try writer.print("end_time_ns={}", .{time});
        } else {
            try writer.writeAll("end_time_ns=null");
        }

        try writer.writeAll("}");
    }
};

pub const Link = struct {
    /// The span context of the linked span
    span_context: SpanContext,

    /// Optional attributes providing additional context about the link
    attributes: ?[]const AttributeKeyValue,

    /// Check if this link is valid (has a valid span context)
    pub fn isValid(self: Link) bool {
        return self.span_context.isValid();
    }

    /// Get the trace ID of the linked span
    pub fn getTraceId(self: Link) [16]u8 {
        return self.span_context.trace_id;
    }

    /// Get the span ID of the linked span
    pub fn getSpanId(self: Link) [8]u8 {
        return self.span_context.span_id;
    }

    /// Check if the linked span is sampled
    pub fn isSampled(self: Link) bool {
        return self.span_context.isSampled();
    }

    /// Check if the linked span is from a remote process
    pub fn isRemote(self: Link) bool {
        return self.span_context.is_remote;
    }

    /// Create a copy of this link with different attributes
    pub fn withAttributes(self: Link, attributes: ?[]const AttributeKeyValue) Link {
        return Link{
            .span_context = self.span_context,
            .attributes = attributes,
        };
    }

    /// Format Link for debugging
    pub fn format(self: Link, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("Link{{span_context={}", .{self.span_context});

        if (self.attributes) |attrs| {
            try writer.writeAll(", attributes=[");
            for (attrs, 0..) |attr, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{}={}", .{ std.fmt.fmtSliceEscapeUpper(attr.key), attr.value });
            }
            try writer.writeAll("]");
        }

        try writer.writeAll("}");
    }
};

/// StatusCode represents the canonical code of a span's status
pub const StatusCode = enum(u8) {
    /// The default status - indicates that the status has not been set
    unset,

    /// The operation completed successfully
    ok,

    /// The operation contains an error
    @"error",

    /// Format StatusCode for debugging
    pub fn format(self: StatusCode, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(@tagName(self));
    }
};

/// Status represents the status of a finished span
pub const Status = struct {
    /// The canonical status code
    code: StatusCode,

    /// Optional descriptive message, typically used with error status
    description: ?[]const u8,

    /// Create an unset status
    pub fn unset() Status {
        return Status{
            .code = .unset,
            .description = null,
        };
    }

    /// Create an ok status
    pub fn ok(description: ?[]const u8) Status {
        return Status{
            .code = .ok,
            .description = description,
        };
    }

    /// Create an error status
    pub fn err(description: ?[]const u8) Status {
        return Status{
            .code = .@"error",
            .description = description,
        };
    }

    /// Format Status for debugging
    pub fn format(self: Status, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("Status{{code={}", .{self.code});

        if (self.description) |desc| {
            try writer.print(", description=\"{s}\"", .{desc});
        }

        try writer.print("}}", .{});
    }
};
