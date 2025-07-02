//! OpenTelemetry SDK Recording Span Implementation
//!
//! This module provides the concrete implementation of the Span interface
//! for the SDK. RecordingSpan accumulates telemetry data during its lifetime
//! and becomes immutable after ending.

const std = @import("std");
const otel_api = @import("otel-api");

const Span = otel_api.trace.Span;
const SpanContext = otel_api.trace.SpanContext;
const SpanKind = otel_api.trace.SpanKind;
const Status = otel_api.trace.Status;
const Link = otel_api.trace.Link;
const Event = otel_api.trace.Event;
const AttributeValue = otel_api.common.AttributeValue;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const OpenTelemetryError = otel_api.common.OpenTelemetryError;
const Context = otel_api.Context;
const TraceId = otel_api.common.TraceId;
const SpanId = otel_api.common.SpanId;

// Import validation functions from API layer
const validateAttributeKey = otel_api.trace.validateAttributeKey;
const validateSpanName = otel_api.trace.validateSpanName;
const reportValidationError = otel_api.common.reportValidationError;

const Clock = @import("../common/clock.zig").Clock;
const getTimestamp = @import("../common/clock.zig").getTimestamp;
const SpanLimits = otel_api.trace.SpanLimits;

/// Recording span implementation that accumulates telemetry data
pub const RecordingSpan = struct {
    /// Allocator for dynamic allocations
    allocator: std.mem.Allocator,

    /// Immutable span context
    span_context: SpanContext,

    /// Parent span context (if this span has a parent)
    parent_span_context: ?SpanContext,

    /// Span name
    name: []const u8,

    /// Span kind
    kind: SpanKind,

    /// Start timestamp in nanoseconds
    start_time: i64,

    /// End timestamp in nanoseconds (null if not ended)
    end_time: ?i64,

    /// Span attributes (lazily allocated)
    attributes: ?std.ArrayList(AttributeKeyValue),

    /// Span events (lazily allocated)
    events: ?std.ArrayList(Event),

    /// Span links (lazily allocated)
    links: ?std.ArrayList(Link),

    /// Span status
    status: Status,

    /// Whether the span is still recording
    is_recording: bool,

    /// Span limits configuration
    span_limits: SpanLimits,

    /// Number of attributes dropped due to limits
    dropped_attributes_count: u32 = 0,

    /// Number of events dropped due to limits
    dropped_events_count: u32 = 0,

    /// Number of links dropped due to limits
    dropped_links_count: u32 = 0,

    /// Reference to the span processor for end notification
    processor: *anyopaque,
    processorOnEndFn: ?*const fn (processor: *anyopaque, span: *RecordingSpan) void,

    /// Create a new recording span
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        span_context: SpanContext,
        parent_span_context: ?SpanContext,
        kind: SpanKind,
        start_time: i64,
        initial_attributes: []const AttributeKeyValue,
        initial_links: []const Link,
        span_limits: SpanLimits,
        processor: *anyopaque,
        processorOnEndFn: ?*const fn (processor: *anyopaque, span: *RecordingSpan) void,
    ) !*RecordingSpan {
        const self = try allocator.create(RecordingSpan);
        errdefer allocator.destroy(self);

        self.* = RecordingSpan{
            .allocator = allocator,
            .span_context = span_context,
            .parent_span_context = parent_span_context,
            .name = name,
            .kind = kind,
            .start_time = start_time,
            .end_time = null,
            .attributes = null,
            .events = null,
            .links = null,
            .status = Status.unset(),
            .is_recording = true,
            .span_limits = span_limits,
            .processor = processor,
            .processorOnEndFn = processorOnEndFn,
        };

        // Add initial attributes if any
        if (initial_attributes.len > 0) {
            try self.ensureAttributes();
            try self.attributes.?.appendSlice(initial_attributes);
        }

        // Add initial links if any
        if (initial_links.len > 0) {
            try self.ensureLinks();
            try self.links.?.appendSlice(initial_links);
        }

        return self;
    }

    /// Clean up span resources with auto-end
    pub fn deinit(self: *RecordingSpan) void {
        // Auto-end - end() is idempotent
        self.end(null);

        // Clean up memory
        if (self.attributes) |*attrs| {
            attrs.deinit();
        }
        if (self.events) |*evts| {
            evts.deinit();
        }
        if (self.links) |*lnks| {
            lnks.deinit();
        }
        self.allocator.destroy(self);
    }

    /// Create an owned clone of this span for batching/queuing
    /// The caller is responsible for calling deinit() on the cloned span
    pub fn clone(self: *const RecordingSpan, allocator: std.mem.Allocator) !*RecordingSpan {
        const cloned = try allocator.create(RecordingSpan);

        // Clone the name string
        const cloned_name = try allocator.dupe(u8, self.name);

        cloned.* = .{
            .allocator = allocator,
            .span_context = self.span_context,
            .parent_span_context = self.parent_span_context,
            .name = cloned_name,
            .kind = self.kind,
            .start_time = self.start_time,
            .end_time = self.end_time,
            .attributes = null,
            .events = null,
            .links = null,
            .status = self.status,
            .is_recording = self.is_recording,
            .span_limits = self.span_limits,
            .processor = self.processor,
            .processorOnEndFn = null, // Cloned spans don't call back to processor
        };

        // Deep copy attributes if they exist
        if (self.attributes) |*attrs| {
            var cloned_attrs = std.ArrayList(AttributeKeyValue).init(allocator);
            for (attrs.items) |attr| {
                // Clone the attribute key and value if they contain owned data
                const cloned_key = try allocator.dupe(u8, attr.key);
                var cloned_value = attr.value;

                // Deep copy string values
                switch (attr.value) {
                    .string => |str| {
                        cloned_value = AttributeValue{ .string = try allocator.dupe(u8, str) };
                    },
                    .string_array => |str_array| {
                        var cloned_str_array = try allocator.alloc([]const u8, str_array.len);
                        for (str_array, 0..) |str, i| {
                            cloned_str_array[i] = try allocator.dupe(u8, str);
                        }
                        cloned_value = AttributeValue{ .string_array = cloned_str_array };
                    },
                    else => {}, // Other types don't contain owned strings
                }

                try cloned_attrs.append(.{
                    .key = cloned_key,
                    .value = cloned_value,
                });
            }
            cloned.attributes = cloned_attrs;
        }

        // Deep copy events if they exist
        if (self.events) |*events| {
            var cloned_events = std.ArrayList(Event).init(allocator);
            for (events.items) |event| {
                const cloned_event_name = try allocator.dupe(u8, event.name);

                // Clone event attributes
                var cloned_event_attrs: ?[]AttributeKeyValue = null;
                if (event.attributes) |attrs| {
                    var event_attrs = try allocator.alloc(AttributeKeyValue, attrs.len);
                    for (attrs, 0..) |attr, i| {
                        const cloned_key = try allocator.dupe(u8, attr.key);
                        var cloned_value = attr.value;

                        switch (attr.value) {
                            .string => |str| {
                                cloned_value = AttributeValue{ .string = try allocator.dupe(u8, str) };
                            },
                            .string_array => |str_array| {
                                var cloned_str_array = try allocator.alloc([]const u8, str_array.len);
                                for (str_array, 0..) |str, j| {
                                    cloned_str_array[j] = try allocator.dupe(u8, str);
                                }
                                cloned_value = AttributeValue{ .string_array = cloned_str_array };
                            },
                            else => {},
                        }

                        event_attrs[i] = .{
                            .key = cloned_key,
                            .value = cloned_value,
                        };
                    }
                    cloned_event_attrs = event_attrs;
                }

                try cloned_events.append(.{
                    .name = cloned_event_name,
                    .timestamp_ns = event.timestamp_ns,
                    .attributes = cloned_event_attrs,
                });
            }
            cloned.events = cloned_events;
        }

        // Deep copy links if they exist
        if (self.links) |*links| {
            var cloned_links = std.ArrayList(Link).init(allocator);
            for (links.items) |link| {
                // Clone link attributes
                var cloned_link_attrs: ?[]AttributeKeyValue = null;
                if (link.attributes) |attrs| {
                    var link_attrs = try allocator.alloc(AttributeKeyValue, attrs.len);
                    for (attrs, 0..) |attr, i| {
                        const cloned_key = try allocator.dupe(u8, attr.key);
                        var cloned_value = attr.value;

                        switch (attr.value) {
                            .string => |str| {
                                cloned_value = AttributeValue{ .string = try allocator.dupe(u8, str) };
                            },
                            .string_array => |str_array| {
                                var cloned_str_array = try allocator.alloc([]const u8, str_array.len);
                                for (str_array, 0..) |str, j| {
                                    cloned_str_array[j] = try allocator.dupe(u8, str);
                                }
                                cloned_value = AttributeValue{ .string_array = cloned_str_array };
                            },
                            else => {},
                        }

                        link_attrs[i] = .{
                            .key = cloned_key,
                            .value = cloned_value,
                        };
                    }
                    cloned_link_attrs = link_attrs;
                }

                try cloned_links.append(.{
                    .span_context = link.span_context,
                    .attributes = cloned_link_attrs,
                });
            }
            cloned.links = cloned_links;
        }

        return cloned;
    }

    /// Clean up a cloned span and all its owned data
    /// This should only be called on spans created with clone()
    pub fn deinitCloned(self: *RecordingSpan) void {
        // Free the cloned name
        self.allocator.free(self.name);

        // Free cloned attributes
        if (self.attributes) |*attrs| {
            for (attrs.items) |attr| {
                self.allocator.free(attr.key);
                switch (attr.value) {
                    .string => |str| {
                        self.allocator.free(str);
                    },
                    .string_array => |str_array| {
                        for (str_array) |str| {
                            self.allocator.free(str);
                        }
                        self.allocator.free(str_array);
                    },
                    else => {},
                }
            }
            attrs.deinit();
        }

        // Free cloned events
        if (self.events) |*events| {
            for (events.items) |event| {
                self.allocator.free(event.name);
                if (event.attributes) |attrs| {
                    for (attrs) |attr| {
                        self.allocator.free(attr.key);
                        switch (attr.value) {
                            .string => |str| {
                                self.allocator.free(str);
                            },
                            .string_array => |str_array| {
                                for (str_array) |str| {
                                    self.allocator.free(str);
                                }
                                self.allocator.free(str_array);
                            },
                            else => {},
                        }
                    }
                    self.allocator.free(attrs);
                }
            }
            events.deinit();
        }

        // Free cloned links
        if (self.links) |*links| {
            for (links.items) |link| {
                if (link.attributes) |attrs| {
                    for (attrs) |attr| {
                        self.allocator.free(attr.key);
                        switch (attr.value) {
                            .string => |str| {
                                self.allocator.free(str);
                            },
                            .string_array => |str_array| {
                                for (str_array) |str| {
                                    self.allocator.free(str);
                                }
                                self.allocator.free(str_array);
                            },
                            else => {},
                        }
                    }
                    self.allocator.free(attrs);
                }
            }
            links.deinit();
        }

        // Destroy the span itself
        self.allocator.destroy(self);
    }

    /// Ensure attributes list is allocated
    fn ensureAttributes(self: *RecordingSpan) !void {
        if (self.attributes == null) {
            self.attributes = std.ArrayList(AttributeKeyValue).init(self.allocator);
        }
    }

    /// Ensure events list is allocated
    fn ensureEvents(self: *RecordingSpan) !void {
        if (self.events == null) {
            self.events = std.ArrayList(Event).init(self.allocator);
        }
    }

    /// Ensure links list is allocated
    fn ensureLinks(self: *RecordingSpan) !void {
        if (self.links == null) {
            self.links = std.ArrayList(Link).init(self.allocator);
        }
    }

    /// Validate that a link has a valid span context
    /// Per spec: "Implementations SHOULD record links containing SpanContext with empty
    /// TraceId or SpanId (all zeros) as long as either the attribute set or TraceState is non-empty."
    fn isValidLink(link: Link) bool {
        const zero_trace = std.mem.zeroes([16]u8);
        const zero_span = std.mem.zeroes([8]u8);

        const has_zero_trace_id = std.mem.eql(u8, &link.span_context.trace_id.bytes, &zero_trace);
        const has_zero_span_id = std.mem.eql(u8, &link.span_context.span_id.bytes, &zero_span);

        // If both IDs are valid (non-zero), link is valid
        if (!has_zero_trace_id and !has_zero_span_id) {
            return true;
        }

        // If one or both IDs are zero, check if we have attributes or trace_state
        if (has_zero_trace_id or has_zero_span_id) {
            // Link is valid if it has attributes
            if (link.attributes != null and link.attributes.?.len > 0) {
                return true;
            }

            // Link is valid if span context has trace_state
            if (link.span_context.trace_state != null) {
                return true;
            }

            // No attributes or trace_state, so zero IDs make this invalid
            return false;
        }

        return true;
    }

    /// Create a Span interface for this recording span
    pub fn span(self: *RecordingSpan) Span {
        return Span{ .bridge = RecordingSpanBridge.init(self) };
    }

    // Span interface implementation methods

    fn getSpanContext(self: *const RecordingSpan) SpanContext {
        return self.span_context;
    }

    fn isRecording(self: *const RecordingSpan) bool {
        return self.is_recording;
    }

    fn setAttribute(self: *RecordingSpan, key: []const u8, value: AttributeValue) !void {
        if (!self.is_recording) return;

        // Validate parameters in debug mode
        if (!validateAttributeKey(key)) {
            reportValidationError(.tracer, "setAttribute", "Invalid attribute key provided", null);
            return; // Skip invalid attribute
        }

        try self.ensureAttributes();

        // Check if attribute already exists and update it
        for (self.attributes.?.items) |*attr| {
            if (std.mem.eql(u8, attr.key, key)) {
                attr.value = value;
                return;
            }
        }

        // Add new attribute
        try self.attributes.?.append(.{ .key = key, .value = value });
    }

    fn setAttributes(self: *RecordingSpan, attributes: []const AttributeKeyValue) !void {
        if (!self.is_recording) return;

        // Validate attributes inline without creating filtered array
        var invalid_count: usize = 0;
        for (attributes) |attr| {
            if (!validateAttributeKey(attr.key)) {
                invalid_count += 1;
            }
        }

        if (invalid_count > 0) {
            reportValidationError(.tracer, "setAttributes", "Invalid attributes detected", null);
            // Still pass all attributes - let SDK handle the filtering
        }

        for (attributes) |attr| {
            try self.setAttribute(attr.key, attr.value);
        }
    }

    fn addEvent(self: *RecordingSpan, event: Event) !void {
        if (!self.is_recording) return;

        // Validate event name
        if (event.name.len == 0) {
            return OpenTelemetryError.InvalidEventName;
        }

        // Validate event attributes if present
        if (event.attributes != null) {
            var invalid_count: usize = 0;
            for (event.attributes.?) |attr| {
                if (!validateAttributeKey(attr.key)) {
                    invalid_count += 1;
                }
            }

            if (invalid_count > 0) {
                reportValidationError(.tracer, "addEvent", "Invalid event attributes detected", null);
            }
        }

        try self.ensureEvents();
        try self.events.?.append(event);
    }

    fn addLink(self: *RecordingSpan, link: Link) !void {
        if (!self.is_recording) return;

        // Validate link
        if (!isValidLink(link)) {
            return OpenTelemetryError.InvalidLink;
        }

        try self.ensureLinks();
        try self.links.?.append(link);
    }

    fn addLinks(self: *RecordingSpan, links: []const Link) !void {
        if (!self.is_recording) return;

        // Validate all links first before adding any
        for (links) |link| {
            if (!isValidLink(link)) {
                return OpenTelemetryError.InvalidLink;
            }
        }

        try self.ensureLinks();
        try self.links.?.appendSlice(links);
    }

    fn setStatus(self: *RecordingSpan, status: Status) !void {
        if (!self.is_recording) return;

        self.status = status;
    }

    fn updateName(self: *RecordingSpan, name: []const u8) !void {
        if (!self.is_recording) return;

        // Validate span name in debug mode
        if (!validateSpanName(name)) {
            reportValidationError(.tracer, "updateName", "Empty span name provided", null);
            // Continue with empty name (spec allows it, but we report it in debug)
        }

        self.name = name;
    }

    fn end(self: *RecordingSpan, options: ?otel_api.trace.SpanEndOptions) void {
        if (!self.is_recording) return; // Idempotent - already ended or never recording

        // Mark as not recording and set end time
        self.is_recording = false;
        if (options) |opts| {
            self.end_time = opts.end_time_ns orelse getTimestamp();
        } else {
            self.end_time = getTimestamp();
        }

        // Enforce span limits
        self.enforceLimits();

        // Notify processor if available
        if (self.processorOnEndFn) |onEndFn| {
            onEndFn(self.processor, self);
        }
    }

    /// Enforce span limits by truncating excess data
    fn enforceLimits(self: *RecordingSpan) void {
        // Enforce attribute limits
        if (self.attributes) |*attrs| {
            // Truncate attributes if exceeding limit
            const original_attr_count = attrs.items.len;
            if (original_attr_count > self.span_limits.max_attributes) {
                self.dropped_attributes_count += @intCast(original_attr_count - self.span_limits.max_attributes);
                attrs.shrinkRetainingCapacity(self.span_limits.max_attributes);
            }

            // Enforce attribute key/value length limits
            for (attrs.items) |*attr| {
                // Truncate key if too long
                if (attr.key.len > self.span_limits.max_attribute_key_length) {
                    attr.key = attr.key[0..self.span_limits.max_attribute_key_length];
                }

                // Truncate string values if too long
                switch (attr.value) {
                    .string => |str| {
                        if (str.len > self.span_limits.max_attribute_value_length) {
                            attr.value = AttributeValue{ .string = str[0..self.span_limits.max_attribute_value_length] };
                        }
                    },
                    else => {},
                }
            }
        }

        // Enforce event limits
        if (self.events) |*events| {
            // Truncate events if exceeding limit
            const original_event_count = events.items.len;
            if (original_event_count > self.span_limits.max_events) {
                self.dropped_events_count += @intCast(original_event_count - self.span_limits.max_events);
                events.shrinkRetainingCapacity(self.span_limits.max_events);
            }

            // Enforce attributes per event limit
            for (events.items) |*event| {
                if (event.attributes) |attrs| {
                    if (attrs.len > self.span_limits.max_attributes_per_event) {
                        event.attributes = attrs[0..self.span_limits.max_attributes_per_event];
                    }
                }
            }
        }

        // Enforce link limits
        if (self.links) |*links| {
            // Truncate links if exceeding limit
            const original_link_count = links.items.len;
            if (original_link_count > self.span_limits.max_links) {
                self.dropped_links_count += @intCast(original_link_count - self.span_limits.max_links);
                links.shrinkRetainingCapacity(self.span_limits.max_links);
            }

            // Enforce attributes per link limit
            for (links.items) |*link| {
                if (link.attributes) |attrs| {
                    if (attrs.len > self.span_limits.max_attributes_per_link) {
                        link.attributes = attrs[0..self.span_limits.max_attributes_per_link];
                    }
                }
            }
        }
    }

    fn recordException(self: *RecordingSpan, exception: anyerror, attributes: ?[]const AttributeKeyValue, timestamp: ?i64) !void {
        if (!self.is_recording) return;

        // Validate exception attributes if present
        if (attributes != null) {
            var invalid_count: usize = 0;
            for (attributes.?) |attr| {
                if (!validateAttributeKey(attr.key)) {
                    invalid_count += 1;
                }
            }

            if (invalid_count > 0) {
                reportValidationError(.tracer, "recordException", "Invalid exception attributes detected", null);
            }
        }

        // Convert exception to event following OpenTelemetry semantic conventions
        const attrs_len = if (attributes) |attrs| attrs.len else 0;
        const exception_attrs = try self.allocator.alloc(AttributeKeyValue, attrs_len + 2);
        defer self.allocator.free(exception_attrs);

        exception_attrs[0] = .{
            .key = "exception.type",
            .value = AttributeValue{ .string = @errorName(exception) },
        };
        exception_attrs[1] = .{
            .key = "exception.message",
            .value = AttributeValue{ .string = @errorName(exception) },
        };
        if (attributes) |attrs| {
            @memcpy(exception_attrs[2..], attrs);
        }

        const exception_event = Event{
            .name = "exception",
            .timestamp_ns = timestamp orelse getTimestamp(),
            .attributes = exception_attrs[0 .. attrs_len + 2],
        };
        try self.addEvent(exception_event);
    }
};

/// Bridge implementation for RecordingSpan to implement the Span interface
const RecordingSpanBridge = struct {
    span_ptr: *RecordingSpan,

    pub fn init(span_ptr: *RecordingSpan) otel_api.trace.SpanBridge {
        return .{
            .span_ptr = span_ptr,
            .getSpanContextFn = getSpanContext,
            .isRecordingFn = isRecording,
            .setAttributeFn = setAttribute,
            .setAttributesFn = setAttributes,
            .addEventFn = addEvent,
            .addLinkFn = addLink,
            .addLinksFn = addLinks,
            .recordExceptionFn = recordException,
            .setStatusFn = setStatus,
            .updateNameFn = updateName,
            .endFn = end,
            .deinitFn = deinit,
        };
    }

    fn getSpanContext(span_ptr: *anyopaque) SpanContext {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        return self.getSpanContext();
    }

    fn isRecording(span_ptr: *anyopaque) bool {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        return self.isRecording();
    }

    fn setAttribute(span_ptr: *anyopaque, key: []const u8, value: AttributeValue) anyerror!void {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        return self.setAttribute(key, value);
    }

    fn setAttributes(span_ptr: *anyopaque, attributes: []const AttributeKeyValue) anyerror!void {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        return self.setAttributes(attributes);
    }

    fn addEvent(span_ptr: *anyopaque, event: Event) anyerror!void {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        return self.addEvent(event);
    }

    fn addLink(span_ptr: *anyopaque, link: Link) anyerror!void {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        return self.addLink(link);
    }

    fn addLinks(span_ptr: *anyopaque, links: []const Link) anyerror!void {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        return self.addLinks(links);
    }

    fn setStatus(span_ptr: *anyopaque, status: Status) anyerror!void {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        return self.setStatus(status);
    }

    fn updateName(span_ptr: *anyopaque, name: []const u8) anyerror!void {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        return self.updateName(name);
    }

    fn end(span_ptr: *anyopaque, options: ?otel_api.trace.SpanEndOptions) void {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        self.end(options);
    }

    fn recordException(span_ptr: *anyopaque, exception: anyerror, attributes: ?[]const AttributeKeyValue, timestamp: ?i64) anyerror!void {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        return self.recordException(exception, attributes, timestamp);
    }

    fn deinit(span_ptr: *anyopaque) void {
        const self = @as(*RecordingSpan, @ptrCast(@alignCast(span_ptr)));
        self.deinit();
    }
};

test "RecordingSpan basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a test span context
    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = SpanContext.SAMPLED_FLAG,
        .trace_state = null,
        .is_remote = false,
    };

    // No-op processor for testing
    var processor_called = false;
    const TestProcessor = struct {
        fn onEnd(processor: *anyopaque, span: *RecordingSpan) void {
            _ = span;
            const called_ptr = @as(*bool, @ptrCast(@alignCast(processor)));
            called_ptr.* = true;
        }
    };

    // Create span
    const recording = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        .internal,
        getTimestamp(),
        &.{},
        &.{},
        SpanLimits.default,
        &processor_called,
        TestProcessor.onEnd,
    );
    defer recording.deinit();

    var span = recording.span();

    // Test basic operations
    try testing.expect(span.isRecording());
    try testing.expectEqual(span_context, span.getSpanContext());

    // Set attributes
    try span.setAttribute("key1", AttributeValue{ .string = "value1" });
    try span.setAttribute("key2", AttributeValue{ .int = 42 });

    // Add event
    try span.addEvent(Event{ .name = "test-event", .timestamp_ns = 0, .attributes = null });

    // Set status
    try span.setStatus(Status.ok("All good"));

    // End span
    span.end(null);
    try testing.expect(!span.isRecording());
    try testing.expect(processor_called);
}

test "RecordingSpan prevents modifications after end" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const recording = try RecordingSpan.init(
        allocator,
        "test-span",
        span_context,
        null,
        .internal,
        getTimestamp(),
        &.{},
        &.{},
        SpanLimits.default,
        undefined,
        null,
    );
    defer recording.deinit();

    var span = recording.span();

    // End the span
    span.end(null);

    // Try to modify after end (should be no-ops)
    try span.setAttribute("key", AttributeValue{ .string = "value" });
    try span.addEvent(Event{ .name = "event", .timestamp_ns = 0, .attributes = null });
    try span.setStatus(Status.err("Should not change"));

    // Verify nothing was added
    try testing.expect(recording.attributes == null);
    try testing.expect(recording.events == null);
    try testing.expectEqual(Status.unset(), recording.status);
}
