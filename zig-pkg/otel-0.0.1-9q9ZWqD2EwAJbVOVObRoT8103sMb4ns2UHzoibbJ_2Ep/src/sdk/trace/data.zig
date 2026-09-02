//! OpenTelemetry SDK Recording Span Implementation
//!
//! This module provides the concrete implementation of the Span interface
//! for the SDK. RecordingSpan accumulates telemetry data during its lifetime
//! and becomes immutable after ending.

const std = @import("std");
const io = std.Options.debug_io;const api = @import("otel-api");

const Span = api.trace.Span;
const AttributeValue = api.common.AttributeValue;
const AttributeKeyValue = api.common.AttributeKeyValue;
const OpenTelemetryError = api.common.OpenTelemetryError;
const Context = api.Context;

// Import validation functions from API layer
const validateAttributeKey = api.trace.validateAttributeKey;
const validateSpanName = api.trace.validateSpanName;
const reportValidationError = api.common.reportValidationError;

const SpanLimits = api.trace.SpanLimits;

const StandardTracer = @import("tracer.zig").StandardTracer;

// Span data represents the immutable span after it has ended.
pub const SpanData = struct {
    // span identification
    scope: api.InstrumentationScope,
    ctx: api.trace.Span.Context,
    parent_ctx: ?api.trace.Span.Context,

    // span description
    name: []const u8,
    kind: api.trace.Span.Kind,
    status: api.trace.Span.Status,
    start_time: i64,
    end_time: i64,
    attributes: []api.AttributeKeyValue,

    // sub-collections
    events: []api.trace.Span.Event,
    links: []api.trace.Span.Link,

    pub fn initOwned(allocator: std.mem.Allocator, unowned: SpanData) !SpanData {
        // TODO inspect what we need to do with the SpanContext fields.
        const name = try allocator.dupe(u8, unowned.name);
        errdefer allocator.free(name);

        const status = api.trace.Span.Status{
            .code = unowned.status.code,
            .description = if (unowned.status.description) |desc| try allocator.dupe(u8, desc) else null,
        };
        errdefer if (status.description) |desc| allocator.free(desc);

        const attributes = try api.AttributeKeyValue.initOwnedSlice(allocator, unowned.attributes);
        errdefer api.AttributeKeyValue.deinitOwnedSlice(allocator, attributes);

        const events = try allocator.alloc(Span.Event, unowned.events.len);
        errdefer allocator.free(events);
        for (0..unowned.events.len) |h| {
            errdefer for (0..h) |i| {
                if (h == i) break;
                allocator.free(events[i].name);
                api.AttributeKeyValue.deinitOwnedSlice(allocator, events[i].attributes);
            };

            const event_name = try allocator.dupe(u8, unowned.events[h].name);
            errdefer allocator.free(event_name);

            const event_attributes = try api.AttributeKeyValue.initOwnedSlice(allocator, unowned.events[h].attributes);
            errdefer api.AttributeKeyValue.deinitOwnedSlice(allocator, event_attributes);

            events[h] = .{
                .timestamp_ns = unowned.events[h].timestamp_ns,
                .name = event_name,
                .attributes = event_attributes,
            };
        }
        errdefer for (events) |event| {
            allocator.free(event.name);
            api.AttributeKeyValue.deinitOwnedSlice(allocator, event.attributes);
        };

        const links = try allocator.alloc(api.trace.Span.Link, unowned.links.len);
        errdefer allocator.free(links);
        for (0..unowned.links.len) |h| {
            errdefer for (0..h) |i| {
                if (h == i) break;
                api.AttributeKeyValue.deinitOwnedSlice(allocator, links[i].attributes);
            };

            const link_attributes = try api.AttributeKeyValue.initOwnedSlice(allocator, unowned.links[h].attributes);
            errdefer api.AttributeKeyValue.deinitOwnedSlice(allocator, link_attributes);

            links[h] = .{
                .span_context = unowned.links[h].span_context,
                .attributes = link_attributes,
            };
        }
        errdefer for (links) |link| api.AttributeKeyValue.deinitOwnedSlice(allocator, link.attributes);

        return SpanData{
            .scope = unowned.scope,
            .ctx = unowned.ctx,
            .parent_ctx = unowned.parent_ctx,
            .name = name,
            .kind = unowned.kind,
            .status = status,
            .start_time = unowned.start_time,
            .end_time = unowned.end_time,
            .attributes = attributes,
            .events = events,
            .links = links,
        };
    }

    pub fn deinitOwned(self: SpanData, allocator: std.mem.Allocator) void {
        // TODO inspect what we need to do with SpanContext fields.
        allocator.free(self.name);
        if (self.status.description) |desc| allocator.free(desc);
        api.AttributeKeyValue.deinitOwnedSlice(allocator, self.attributes);
        for (self.events) |event| {
            api.AttributeKeyValue.deinitOwnedSlice(allocator, event.attributes);
            allocator.free(event.name);
        }
        allocator.free(self.events);
        for (self.links) |link| {
            api.AttributeKeyValue.deinitOwnedSlice(allocator, link.attributes);
        }
        allocator.free(self.links);
    }
};

/// Bridge implementation for RecordingSpan to implement the Span interface
pub const RecordingSpan = struct {
    tracer: *StandardTracer,
    name: []const u8,
    status: api.trace.Span.Status,
    attributes: []api.AttributeKeyValue,
    events: std.ArrayList(api.trace.Span.Event),
    links: std.ArrayList(api.trace.Span.Link),

    pub fn init(tracer: *StandardTracer, name: []const u8) !RecordingSpan {
        const default_name = try tracer.provider.allocator.dupe(u8, name);
        errdefer tracer.provider.allocator.free(default_name);
        const default_attributes = try api.AttributeKeyValue.initOwnedSlice(tracer.provider.allocator, &.{});
        errdefer api.AttributeKeyValue.deinitOwnedSlice(tracer.provider.allocator, default_attributes);

        return .{
            .tracer = tracer,
            .name = default_name,
            .status = .default,
            .attributes = default_attributes,
            .events = .empty,
            .links = .empty,
        };
    }

    pub fn deinit(self: *RecordingSpan) void {
        self.tracer.provider.allocator.free(self.name);
        if (self.status.description) |desc| self.tracer.provider.allocator.free(desc);
        api.AttributeKeyValue.deinitOwnedSlice(self.tracer.provider.allocator, self.attributes);
        for (self.events.items) |event| {
            self.tracer.provider.allocator.free(event.name);
            api.AttributeKeyValue.deinitOwnedSlice(self.tracer.provider.allocator, event.attributes);
        }
        self.events.deinit(self.tracer.provider.allocator);
        self.links.deinit(self.tracer.provider.allocator);
        self.tracer.provider.allocator.destroy(self);
    }

    pub fn updateName(self: *RecordingSpan, new_name: []const u8) void {
        if (!validateSpanName(new_name)) {
            reportValidationError(.tracer, "Span.updateName", "Empty span name provided", null);
            // Continue with empty name (spec allows it, but we report it in debug)
        }
        const old_name = self.name;
        self.name = self.tracer.provider.allocator.dupe(u8, new_name) catch return;
        self.tracer.provider.allocator.free(old_name);
    }

    pub fn setStatus(self: *RecordingSpan, new_status: api.trace.Span.Status) void {
        if (self.status.description) |desc| self.tracer.provider.allocator.free(desc);
        const new_desc = if (new_status.description) |desc| self.tracer.provider.allocator.dupe(u8, desc) catch null else null;
        self.status = .{
            .code = new_status.code,
            .description = new_desc,
        };
    }

    pub fn setAttribute(self: *RecordingSpan, entry: AttributeKeyValue) void {
        const old_attributes = self.attributes;
        self.attributes = api.AttributeBuilder.init(self.tracer.provider.allocator)
            .addMany(old_attributes)
            .add(entry)
            .finish(self.tracer.provider.allocator) catch return;
        api.AttributeKeyValue.deinitOwnedSlice(self.tracer.provider.allocator, old_attributes);
    }

    pub fn setAttributes(self: *RecordingSpan, entries: []const AttributeKeyValue) void {
        const old_attributes = self.attributes;
        self.attributes = api.AttributeBuilder.init(self.tracer.provider.allocator)
            .addMany(old_attributes)
            .addMany(entries)
            .finish(self.tracer.provider.allocator) catch return;
        api.AttributeKeyValue.deinitOwnedSlice(self.tracer.provider.allocator, old_attributes);
    }

    pub fn addEvent(self: *RecordingSpan, event: api.trace.Span.Event) void {
        // Deep copy: the event must survive until end() exports it, but the
        // caller's name/attributes may reference stack or soon-freed memory
        // (recordException's merged attributes were exactly that — a
        // use-after-free segfault at export time). Owned copies are freed in
        // deinit(); SpanData.initOwned makes its own copy for the processor.
        const allocator = self.tracer.provider.allocator;
        const owned_name = allocator.dupe(u8, event.name) catch return;
        const owned_attributes = api.AttributeKeyValue.initOwnedSlice(allocator, event.attributes) catch {
            allocator.free(owned_name);
            return;
        };
        self.events.append(allocator, .{
            .timestamp_ns = event.timestamp_ns,
            .name = owned_name,
            .attributes = owned_attributes,
        }) catch {
            allocator.free(owned_name);
            api.AttributeKeyValue.deinitOwnedSlice(allocator, owned_attributes);
        };
    }

    pub fn addLink(self: *RecordingSpan, link: api.trace.Span.Link) anyerror!void {
        // TODO: this should deep copy the link for memory safety.
        self.links.append(self.tracer.provider.allocator, link) catch {};
    }

    pub fn addLinks(self: *RecordingSpan, links: []const api.trace.Span.Link) anyerror!void {
        // TODO: this should deep copy the links for memory safety.
        self.links.appendSlice(self.tracer.provider.allocator, links) catch {};
    }

    pub fn end(self: *RecordingSpan, bridge: api.trace.Span.Bridge, options: ?api.trace.Span.EndOptions) void {
        const default_ts: i64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        const end_ts = if (options) |opts| opts.end_time_ns orelse default_ts else default_ts;

        // Notify processor if available
        for (self.tracer.provider.processors.items) |*processor| {
            processor.onEnd(SpanData{
                .scope = self.tracer.scope,
                .ctx = bridge.ctx,
                .parent_ctx = bridge.parent_ctx,
                .name = self.name,
                .kind = bridge.kind,
                .status = self.status,
                .start_time = bridge.start_ns,
                .end_time = bridge.end_ns orelse end_ts,
                .attributes = self.attributes,
                .events = self.events.items,
                .links = self.links.items,
            }, self.tracer.provider.resource);
        }
    }

    pub fn recordException(self: *RecordingSpan, exception: anyerror, attributes: ?[]const AttributeKeyValue, timestamp: ?i64) anyerror!void {
        // TODO: these names should come from semconv, if they are defined there.
        const convention_attributes = &[_]AttributeKeyValue{ .{
            .key = "exception.type",
            .value = AttributeValue{ .string = @errorName(exception) },
        }, .{
            .key = "exception.message",
            .value = AttributeValue{ .string = @errorName(exception) },
        } };

        const allocator = self.tracer.provider.allocator;
        const merged = try api.AttributeBuilder.init(allocator)
            .addMany(attributes orelse &.{})
            .addMany(convention_attributes)
            .finish(allocator);
        defer api.AttributeKeyValue.deinitOwnedSlice(allocator, merged);

        const default_ts: i64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        self.addEvent(.{
            .name = "exception",
            .timestamp_ns = timestamp orelse default_ts,
            .attributes = merged,
        });
    }
};

test "recordException deep-copies attributes that do not outlive the call" {
    // regression: recordException used to free its merged attribute slice
    // immediately and store the dangling pointer in the exception event
    // (falling back to a stack-local on build failure). The exporter's deep
    // copy at end() then read freed memory — a segfault on every recorded
    // error whose span outlived the call.
    const testing = std.testing;
    const allocator = testing.allocator;
    const TracerProvider = @import("tracer_provider.zig").TracerProvider;
    const Resource = @import("../resource/resource.zig").Resource;
    const createDefaultIdGenerator = @import("id_generator.zig").createDefaultIdGenerator;
    const samplers = @import("samplers/root.zig");
    const SpanProcessor = @import("processor.zig").SpanProcessor;

    var provider_ptr = TracerProvider.init(
        allocator,
        Resource{ .attributes = &.{}, .schema_url = null },
        createDefaultIdGenerator(),
        samplers.always_on,
    );
    try provider_ptr.registerProcessor(SpanProcessor{ .noop = {} });
    defer provider_ptr.deinit();

    var tp = provider_ptr.tracerProvider();
    const tracer = try tp.getTracerWithScope(.{
        .name = "uaf-regression",
        .version = null,
        .schema_url = null,
        .attributes = &.{},
    });

    var span = try tracer.startSpan("op", null, &.{});
    defer span.deinit();

    // the attribute value lives in caller memory that is mutated and freed
    // right after the call — the span must have copied it by then
    const transient = try allocator.dupe(u8, "request context detail");
    try span.recordException(error.TestBoom, &[_]AttributeKeyValue{
        .{ .key = "ctx", .value = .{ .string = transient } },
    }, null);
    @memset(transient, 'X');
    allocator.free(transient);

    span.end(null);

    const rec: *RecordingSpan = @ptrCast(@alignCast(span.bridge.span_ptr));
    try testing.expectEqual(@as(usize, 1), rec.events.items.len);
    const ev = rec.events.items[0];
    try testing.expectEqualStrings("exception", ev.name);
    const ctx_attr = AttributeKeyValue.scanSlice(ev.attributes, "ctx") orelse return error.MissingAttribute;
    try testing.expectEqualStrings("request context detail", ctx_attr.value.string);
    const exc_type = AttributeKeyValue.scanSlice(ev.attributes, "exception.type") orelse return error.MissingAttribute;
    try testing.expectEqualStrings("TestBoom", exc_type.value.string);
}
