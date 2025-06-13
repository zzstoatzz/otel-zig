//! OpenTelemetry SpanContext
//!
//! SpanContext represents the immutable portion of a span that must be propagated
//! to child spans and across process boundaries. It contains the trace identifier,
//! span identifier, trace flags, and trace state according to the W3C Trace Context
//! specification.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#spancontext
//! See: https://www.w3.org/TR/trace-context/

const std = @import("std");
const Random = std.Random;
const types = @import("../common/types.zig");
const TraceId = types.TraceId;
const SpanId = types.SpanId;

/// SpanContext represents the immutable span identifier and associated metadata
pub const SpanContext = struct {
    /// 128-bit trace identifier
    trace_id: TraceId,

    /// 64-bit span identifier
    span_id: SpanId,

    /// 8-bit trace flags containing sampling decision and other flags
    trace_flags: u8,

    /// Optional W3C trace state for vendor-specific propagation data
    trace_state: ?[]const u8,

    /// Whether this span context was extracted from a remote process
    is_remote: bool,

    /// Trace flags bit positions according to W3C specification
    pub const SAMPLED_FLAG: u8 = 0x01;

    /// Create an invalid span context (all zeros)
    pub const invalid: SpanContext = .{
        .trace_id = TraceId.fromBytes([_]u8{0} ** 16),
        .span_id = SpanId.fromBytes([_]u8{0} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    /// Generate a new span context with random trace and span IDs
    pub fn generate(random: Random) SpanContext {
        var trace_id_bytes: [16]u8 = undefined;
        var span_id_bytes: [8]u8 = undefined;

        // Generate non-zero trace_id
        while (true) {
            random.bytes(&trace_id_bytes);
            if (!std.mem.allEqual(u8, &trace_id_bytes, 0)) break;
        }

        // Generate non-zero span_id
        while (true) {
            random.bytes(&span_id_bytes);
            if (!std.mem.allEqual(u8, &span_id_bytes, 0)) break;
        }

        return SpanContext{
            .trace_id = TraceId.fromBytes(trace_id_bytes),
            .span_id = SpanId.fromBytes(span_id_bytes),
            .trace_flags = 0,
            .trace_state = null,
            .is_remote = false,
        };
    }

    /// Create a new span context with the same trace ID but new span ID
    pub fn fromTraceId(trace_id: TraceId, random: Random) SpanContext {
        var span_id_bytes: [8]u8 = undefined;

        // Generate non-zero span_id
        while (true) {
            random.bytes(&span_id_bytes);
            if (!std.mem.allEqual(u8, &span_id_bytes, 0)) break;
        }

        return SpanContext{
            .trace_id = trace_id,
            .span_id = SpanId.fromBytes(span_id_bytes),
            .trace_flags = 0,
            .trace_state = null,
            .is_remote = false,
        };
    }

    /// Check if this span context is valid (non-zero trace_id and span_id)
    pub fn isValid(self: SpanContext) bool {
        return self.trace_id.isValid() and self.span_id.isValid();
    }

    /// Check if this span is sampled according to trace flags
    pub fn isSampled(self: SpanContext) bool {
        return (self.trace_flags & SAMPLED_FLAG) != 0;
    }

    /// Create a copy of this span context with updated trace state
    pub fn withTraceState(self: SpanContext, state: ?[]const u8) SpanContext {
        return SpanContext{
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .trace_flags = self.trace_flags,
            .trace_state = state,
            .is_remote = self.is_remote,
        };
    }

    /// Create a copy of this span context marked as remote
    pub fn asRemote(self: SpanContext) SpanContext {
        return SpanContext{
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .trace_flags = self.trace_flags,
            .trace_state = self.trace_state,
            .is_remote = true,
        };
    }

    /// Create a copy of this span context with updated trace flags
    pub fn withTraceFlags(self: SpanContext, flags: u8) SpanContext {
        return SpanContext{
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .trace_flags = flags,
            .trace_state = self.trace_state,
            .is_remote = self.is_remote,
        };
    }

    /// Format span context as hex strings for debugging
    pub fn format(self: SpanContext, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("SpanContext{{trace_id={}, span_id={}, flags=0x{x:0>2}, sampled={}, remote={}", .{
            self.trace_id,
            self.span_id,
            self.trace_flags,
            self.isSampled(),
            self.is_remote,
        });

        if (self.trace_state) |state| {
            try writer.print(", state=\"{s}\"", .{state});
        }

        try writer.writeAll("}");
    }

    /// Get trace ID as hex string (32 characters)
    pub fn traceIdHex(self: SpanContext, buf: *[32]u8) []const u8 {
        const hex_bytes = std.fmt.bytesToHex(&self.trace_id.bytes, .lower);
        @memcpy(buf, &hex_bytes);
        return buf;
    }

    /// Get span ID as hex string (16 characters)
    pub fn spanIdHex(self: SpanContext, buf: *[16]u8) []const u8 {
        const hex_bytes = std.fmt.bytesToHex(&self.span_id.bytes, .lower);
        @memcpy(buf, &hex_bytes);
        return buf;
    }

    /// Parse trace ID from hex string
    pub fn parseTraceId(hex: []const u8) !?TraceId {
        const trace_id = TraceId.fromHexString(hex) catch return null;
        if (trace_id.isInvalid()) return null;
        return trace_id;
    }

    /// Parse span ID from hex string
    pub fn parseSpanId(hex: []const u8) !?SpanId {
        const span_id = SpanId.fromHexString(hex) catch return null;
        if (span_id.isInvalid()) return null;
        return span_id;
    }
};

test "SpanContext invalid" {
    const invalid = SpanContext.invalid;
    try std.testing.expect(!invalid.isValid());
    try std.testing.expect(!invalid.isSampled());
    try std.testing.expect(!invalid.is_remote);
    try std.testing.expectEqual(@as(u8, 0), invalid.trace_flags);
    try std.testing.expectEqual(@as(?[]const u8, null), invalid.trace_state);
}

test "SpanContext generate" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const ctx1 = SpanContext.generate(random);
    const ctx2 = SpanContext.generate(random);

    // Both should be valid
    try std.testing.expect(ctx1.isValid());
    try std.testing.expect(ctx2.isValid());

    // Should have different IDs
    try std.testing.expect(!std.mem.eql(u8, &ctx1.trace_id.bytes, &ctx2.trace_id.bytes));
    try std.testing.expect(!std.mem.eql(u8, &ctx1.span_id.bytes, &ctx2.span_id.bytes));

    // Should not be sampled by default
    try std.testing.expect(!ctx1.isSampled());
    try std.testing.expect(!ctx2.isSampled());

    // Should not be remote by default
    try std.testing.expect(!ctx1.is_remote);
    try std.testing.expect(!ctx2.is_remote);
}

test "SpanContext fromTraceId" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const trace_id = TraceId.fromBytes([_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 });

    const ctx1 = SpanContext.fromTraceId(trace_id, random);
    const ctx2 = SpanContext.fromTraceId(trace_id, random);

    // Both should be valid
    try std.testing.expect(ctx1.isValid());
    try std.testing.expect(ctx2.isValid());

    // Should have same trace ID
    try std.testing.expectEqualSlices(u8, &trace_id.bytes, &ctx1.trace_id.bytes);
    try std.testing.expectEqualSlices(u8, &trace_id.bytes, &ctx2.trace_id.bytes);

    // Should have different span IDs
    try std.testing.expect(!std.mem.eql(u8, &ctx1.span_id.bytes, &ctx2.span_id.bytes));
}

test "SpanContext sampling flags" {
    var ctx = SpanContext.invalid;
    try std.testing.expect(!ctx.isSampled());

    ctx = ctx.withTraceFlags(SpanContext.SAMPLED_FLAG);
    try std.testing.expect(ctx.isSampled());
    try std.testing.expectEqual(SpanContext.SAMPLED_FLAG, ctx.trace_flags);

    ctx = ctx.withTraceFlags(0);
    try std.testing.expect(!ctx.isSampled());
}

test "SpanContext trace state" {
    var ctx = SpanContext.invalid;
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.trace_state);

    const state = "vendor1=value1,vendor2=value2";
    ctx = ctx.withTraceState(state);
    try std.testing.expectEqualStrings(state, ctx.trace_state.?);

    ctx = ctx.withTraceState(null);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.trace_state);
}

test "SpanContext remote flag" {
    var ctx = SpanContext.invalid;
    try std.testing.expect(!ctx.is_remote);

    ctx = ctx.asRemote();
    try std.testing.expect(ctx.is_remote);
}

test "SpanContext hex formatting" {
    const ctx = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }),
        .span_id = SpanId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }),
        .trace_flags = SpanContext.SAMPLED_FLAG,
        .trace_state = "vendor=value",
        .is_remote = true,
    };

    var trace_buf: [32]u8 = undefined;
    var span_buf: [16]u8 = undefined;

    const trace_hex = ctx.traceIdHex(&trace_buf);
    const span_hex = ctx.spanIdHex(&span_buf);

    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", trace_hex);
    try std.testing.expectEqualStrings("0123456789abcdef", span_hex);
}

test "SpanContext parse IDs" {
    // Valid trace ID
    const trace_id = try SpanContext.parseTraceId("0123456789abcdef0123456789abcdef");
    try std.testing.expect(trace_id != null);
    try std.testing.expectEqual(@as(u8, 0x01), trace_id.?.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xef), trace_id.?.bytes[15]);

    // Invalid trace ID (all zeros)
    const zero_trace = try SpanContext.parseTraceId("00000000000000000000000000000000");
    try std.testing.expect(zero_trace == null);

    // Invalid trace ID (wrong length)
    const short_trace = try SpanContext.parseTraceId("0123456789abcdef");
    try std.testing.expect(short_trace == null);

    // Valid span ID
    const span_id = try SpanContext.parseSpanId("0123456789abcdef");
    try std.testing.expect(span_id != null);
    try std.testing.expectEqual(@as(u8, 0x01), span_id.?.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xef), span_id.?.bytes[7]);

    // Invalid span ID (all zeros)
    const zero_span = try SpanContext.parseSpanId("0000000000000000");
    try std.testing.expect(zero_span == null);

    // Invalid span ID (wrong length)
    const short_span = try SpanContext.parseSpanId("01234567");
    try std.testing.expect(short_span == null);
}

test "SpanContext format" {
    const ctx = SpanContext{
        .trace_id = TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }),
        .span_id = SpanId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }),
        .trace_flags = SpanContext.SAMPLED_FLAG,
        .trace_state = "vendor=value",
        .is_remote = true,
    };

    var buf: [512]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{}", .{ctx});

    try std.testing.expect(std.mem.indexOf(u8, formatted, "0123456789abcdef0123456789abcdef") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "0123456789abcdef") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "sampled=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "remote=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "vendor=value") != null);
}
