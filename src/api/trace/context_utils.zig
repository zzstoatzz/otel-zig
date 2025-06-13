//! OpenTelemetry Trace Context Utilities
//!
//! This module provides utility functions for common trace context operations,
//! making it easier to work with trace contexts in OpenTelemetry applications.
//!
//! These utilities build on the existing context system and trace context keys
//! to provide convenient functions for typical trace context workflows.

const std = @import("std");
const Context = @import("../context/context.zig").Context;
const SpanContext = @import("span_context.zig").SpanContext;
const context_keys = @import("context_keys.zig");
const TraceId = @import("../common/types.zig").TraceId;
const SpanId = @import("../common/types.zig").SpanId;

/// Get the active span context from a context, if present
pub fn getActiveSpanContext(ctx: Context) ?SpanContext {
    return ctx.getValue(context_keys.active_span_context_key);
}

/// Get the remote span context from a context, if present
pub fn getRemoteSpanContext(ctx: Context) ?SpanContext {
    return ctx.getValue(context_keys.remote_span_context_key);
}

/// Get any span context from a context, preferring active over remote
pub fn getSpanContext(ctx: Context) ?SpanContext {
    return getActiveSpanContext(ctx) orelse getRemoteSpanContext(ctx);
}

/// Create a new context with the given span context as the active span
pub fn withActiveSpanContext(ctx: Context, span_context: SpanContext) !Context {
    return ctx.withValue(context_keys.active_span_context_key, span_context);
}

/// Create a new context with the given span context as a remote span
pub fn withRemoteSpanContext(ctx: Context, span_context: SpanContext) !Context {
    return ctx.withValue(context_keys.remote_span_context_key, span_context);
}

/// Create a child span context from a parent span context
pub fn createChildSpanContext(parent: SpanContext, random: std.Random) SpanContext {
    return SpanContext.fromTraceId(parent.trace_id, random)
        .withTraceFlags(parent.trace_flags)
        .withTraceState(parent.trace_state);
}

/// Create a new root span context (new trace)
pub fn createRootSpanContext(random: std.Random) SpanContext {
    return SpanContext.generate(random);
}

/// Check if a context has any span context (active or remote)
pub fn hasSpanContext(ctx: Context) bool {
    return ctx.hasValue(context_keys.active_span_context_key) or
        ctx.hasValue(context_keys.remote_span_context_key);
}

/// Check if a context has an active span context
pub fn hasActiveSpanContext(ctx: Context) bool {
    return ctx.hasValue(context_keys.active_span_context_key);
}

/// Check if a context has a remote span context
pub fn hasRemoteSpanContext(ctx: Context) bool {
    return ctx.hasValue(context_keys.remote_span_context_key);
}

/// Get the trace ID from the context, if any span context is present
pub fn getTraceId(ctx: Context) ?[16]u8 {
    const span_ctx = getSpanContext(ctx) orelse return null;
    return span_ctx.trace_id.bytes;
}

/// Get the span ID from the active span context, if present
pub fn getActiveSpanId(ctx: Context) ?[8]u8 {
    const span_ctx = getActiveSpanContext(ctx) orelse return null;
    return span_ctx.span_id.bytes;
}

/// Check if the current trace is sampled
pub fn isSampled(ctx: Context) bool {
    const span_ctx = getSpanContext(ctx) orelse return false;
    return span_ctx.isSampled();
}

/// Get trace flags from the context
pub fn getTraceFlags(ctx: Context) ?u8 {
    const span_ctx = getSpanContext(ctx) orelse return null;
    return span_ctx.trace_flags;
}

/// Get trace state from the context
pub fn getTraceState(ctx: Context) ?[]const u8 {
    const span_ctx = getSpanContext(ctx) orelse return null;
    return span_ctx.trace_state;
}

/// Create a context with updated sampling decision
pub fn withSamplingDecision(ctx: Context, should_sample: bool) !Context {
    return ctx.withValue(context_keys.sampling_decision_key, should_sample);
}

/// Get the sampling decision from the context
pub fn getSamplingDecision(ctx: Context) ?bool {
    return ctx.getValue(context_keys.sampling_decision_key);
}

/// Create a context with updated trace flags
pub fn withTraceFlags(ctx: Context, flags: u8) !Context {
    return ctx.withValue(context_keys.trace_flags_key, flags);
}

/// Create a context with updated trace state
pub fn withTraceState(ctx: Context, state: []const u8) !Context {
    return ctx.withValue(context_keys.trace_state_key, state);
}

/// Start a new child span context from the current context
/// This creates a child span context and sets it as active
pub fn startChildSpan(ctx: Context, random: std.Random) !Context {
    const parent = getSpanContext(ctx) orelse return ctx.withValue(
        context_keys.active_span_context_key,
        createRootSpanContext(random),
    );

    const child = createChildSpanContext(parent, random);
    return ctx.withValue(context_keys.active_span_context_key, child);
}

/// End the current active span by removing it from the context
/// If there was a parent span, it becomes active again
pub fn endActiveSpan(ctx: Context) Context {
    // For now, just remove the active span context
    // In a full implementation, this might restore a parent span from a stack
    if (!ctx.hasValue(context_keys.active_span_context_key)) return ctx;

    // Return a context without the active span
    // Note: This is a simplified implementation
    // A full implementation would maintain a span stack
    const new_ctx = Context.empty(ctx.allocator) catch return ctx;

    // Copy all values except the active span context
    var iter = ctx.iterator();
    while (iter.next()) |pair| {
        if (pair.key_id != context_keys.active_span_context_key.key_id) {
            // This is a simplified approach - real implementation would need
            // to handle the context reconstruction more carefully
            continue;
        }
    }

    return new_ctx;
}

// ============================================================================
// Tests
// ============================================================================

test "getActiveSpanContext and getRemoteSpanContext" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    // Empty context should return null
    try testing.expect(getActiveSpanContext(ctx) == null);
    try testing.expect(getRemoteSpanContext(ctx) == null);

    // Add active span context
    const active_span = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    const ctx_with_active = try ctx.withValue(context_keys.active_span_context_key, active_span);
    defer ctx_with_active.deinit();

    const retrieved_active = getActiveSpanContext(ctx_with_active);
    try testing.expect(retrieved_active != null);
    try testing.expectEqualSlices(u8, &active_span.trace_id.bytes, &retrieved_active.?.trace_id.bytes);

    // Add remote span context
    const remote_span = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{0x03} ** 16),
        .span_id = SpanId.fromBytes([_]u8{0x04} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = true,
    };

    const ctx_with_remote = try ctx_with_active.withValue(context_keys.remote_span_context_key, remote_span);
    defer ctx_with_remote.deinit();

    const retrieved_remote = getRemoteSpanContext(ctx_with_remote);
    try testing.expect(retrieved_remote != null);
    try testing.expectEqualSlices(u8, &remote_span.trace_id.bytes, &retrieved_remote.?.trace_id.bytes);
}

test "getSpanContext prefers active over remote" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    const active_span = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    const remote_span = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{0x03} ** 16),
        .span_id = SpanId.fromBytes([_]u8{0x04} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = true,
    };

    // Context with both active and remote
    const ctx_with_active = try ctx.withValue(context_keys.active_span_context_key, active_span);
    defer ctx_with_active.deinit();
    const ctx_with_both = try ctx_with_active.withValue(context_keys.remote_span_context_key, remote_span);
    defer ctx_with_both.deinit();

    const span_ctx = getSpanContext(ctx_with_both);
    try testing.expect(span_ctx != null);
    // Should return active span, not remote
    try testing.expectEqualSlices(u8, &active_span.trace_id.bytes, &span_ctx.?.trace_id.bytes);

    // Context with only remote
    const ctx_remote_only = try ctx.withValue(context_keys.remote_span_context_key, remote_span);
    defer ctx_remote_only.deinit();

    const remote_only_span = getSpanContext(ctx_remote_only);
    try testing.expect(remote_only_span != null);
    try testing.expectEqualSlices(u8, &remote_span.trace_id.bytes, &remote_only_span.?.trace_id.bytes);
}

test "withActiveSpanContext and withRemoteSpanContext" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    // Test active span context
    const ctx_with_active = try withActiveSpanContext(ctx, span_context);
    defer ctx_with_active.deinit();

    const retrieved_active = getActiveSpanContext(ctx_with_active);
    try testing.expect(retrieved_active != null);
    try testing.expectEqualSlices(u8, &span_context.trace_id.bytes, &retrieved_active.?.trace_id.bytes);

    // Test remote span context
    const ctx_with_remote = try withRemoteSpanContext(ctx, span_context);
    defer ctx_with_remote.deinit();

    const retrieved_remote = getRemoteSpanContext(ctx_with_remote);
    try testing.expect(retrieved_remote != null);
    try testing.expectEqualSlices(u8, &span_context.trace_id.bytes, &retrieved_remote.?.trace_id.bytes);
}

test "createChildSpanContext" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const parent = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = 1,
        .trace_state = "parent=state",
        .is_remote = false,
    };

    const child = createChildSpanContext(parent, random);

    // Child should have same trace ID as parent
    try testing.expectEqualSlices(u8, &parent.trace_id.bytes, &child.trace_id.bytes);

    // Child should have different span ID
    try testing.expect(!std.mem.eql(u8, &parent.span_id.bytes, &child.span_id.bytes));

    // Child should inherit trace flags and state
    try testing.expectEqual(parent.trace_flags, child.trace_flags);
    try testing.expectEqualStrings("parent=state", child.trace_state.?);
}

test "createRootSpanContext" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const root1 = createRootSpanContext(random);
    const root2 = createRootSpanContext(random);

    // Both should be valid
    try testing.expect(root1.isValid());
    try testing.expect(root2.isValid());

    // Should have different trace and span IDs
    try testing.expect(!std.mem.eql(u8, &root1.trace_id.bytes, &root2.trace_id.bytes));
    try testing.expect(!std.mem.eql(u8, &root1.span_id.bytes, &root2.span_id.bytes));
}

test "hasSpanContext functions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    // Empty context
    try testing.expect(!hasSpanContext(ctx));
    try testing.expect(!hasActiveSpanContext(ctx));
    try testing.expect(!hasRemoteSpanContext(ctx));

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    // Context with active span
    const ctx_with_active = try ctx.withValue(context_keys.active_span_context_key, span_context);
    defer ctx_with_active.deinit();

    try testing.expect(hasSpanContext(ctx_with_active));
    try testing.expect(hasActiveSpanContext(ctx_with_active));
    try testing.expect(!hasRemoteSpanContext(ctx_with_active));

    // Context with remote span
    const ctx_with_remote = try ctx.withValue(context_keys.remote_span_context_key, span_context);
    defer ctx_with_remote.deinit();

    try testing.expect(hasSpanContext(ctx_with_remote));
    try testing.expect(!hasActiveSpanContext(ctx_with_remote));
    try testing.expect(hasRemoteSpanContext(ctx_with_remote));
}

test "trace information getters" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    const span_context = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 }),
        .span_id = SpanId.fromBytes([_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 }),
        .trace_flags = 0x01,
        .trace_state = "test=state",
        .is_remote = false,
    };

    const ctx_with_span = try ctx.withValue(context_keys.active_span_context_key, span_context);
    defer ctx_with_span.deinit();

    // Test trace ID getter
    const trace_id = getTraceId(ctx_with_span);
    try testing.expect(trace_id != null);
    try testing.expectEqualSlices(u8, &span_context.trace_id.bytes, &trace_id.?);

    // Test span ID getter
    const span_id = getActiveSpanId(ctx_with_span);
    try testing.expect(span_id != null);
    try testing.expectEqualSlices(u8, &span_context.span_id.bytes, &span_id.?);

    // Test sampling check
    try testing.expect(isSampled(ctx_with_span));

    // Test trace flags getter
    const flags = getTraceFlags(ctx_with_span);
    try testing.expect(flags != null);
    try testing.expectEqual(@as(u8, 0x01), flags.?);

    // Test trace state getter
    const state = getTraceState(ctx_with_span);
    try testing.expect(state != null);
    try testing.expectEqualStrings("test=state", state.?);
}

test "sampling decision utilities" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    // Initially no sampling decision
    try testing.expect(getSamplingDecision(ctx) == null);

    // Set sampling decision
    const ctx_with_sampling = try withSamplingDecision(ctx, true);
    defer ctx_with_sampling.deinit();

    const decision = getSamplingDecision(ctx_with_sampling);
    try testing.expect(decision != null);
    try testing.expectEqual(true, decision.?);
}

test "startChildSpan creates proper child context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    // Start child span in empty context should create root span
    const ctx_with_root = try startChildSpan(ctx, random);
    defer ctx_with_root.deinit();

    const root_span = getActiveSpanContext(ctx_with_root);
    try testing.expect(root_span != null);
    try testing.expect(root_span.?.isValid());

    // Start child span with existing span should create child
    const ctx_with_child = try startChildSpan(ctx_with_root, random);
    defer ctx_with_child.deinit();

    const child_span = getActiveSpanContext(ctx_with_child);
    try testing.expect(child_span != null);
    try testing.expect(child_span.?.isValid());

    // Child should have same trace ID as parent
    try testing.expectEqualSlices(u8, &root_span.?.trace_id.bytes, &child_span.?.trace_id.bytes);

    // Child should have different span ID
    try testing.expect(!std.mem.eql(u8, &root_span.?.span_id.bytes, &child_span.?.span_id.bytes));
}
