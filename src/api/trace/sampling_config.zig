//! OpenTelemetry Sampling Configuration
//!
//! This module defines the sampling interface and types according to the
//! OpenTelemetry specification. The API provides the interface definition
//! and a no-op implementation. Concrete samplers are provided by the SDK.
//!
//! See: https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling

const std = @import("std");
const Context = @import("../context/root.zig").Context;
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
const TraceId = @import("../common/types.zig").TraceId;
const spans = @import("span.zig");

/// SamplingDecision determines how a span should be handled
pub const SamplingDecision = enum {
    /// Drop the span - IsRecording will be false, span will not be recorded
    drop,

    /// Record but don't sample - IsRecording will be true, but Sampled flag will not be set
    record_only,

    /// Record and sample - IsRecording will be true and Sampled flag will be set
    record_and_sample,

    /// Check if this decision indicates the span should be recorded
    pub fn shouldRecord(self: SamplingDecision) bool {
        return switch (self) {
            .drop => false,
            .record_only, .record_and_sample => true,
        };
    }

    /// Check if this decision indicates the span should be sampled
    pub fn shouldSample(self: SamplingDecision) bool {
        return switch (self) {
            .drop, .record_only => false,
            .record_and_sample => true,
        };
    }

    /// Format SamplingDecision for debugging
    pub fn format(self: SamplingDecision, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(@tagName(self));
    }
};

/// SamplingResult contains the output of a sampling decision
pub const SamplingResult = struct {
    /// The sampling decision
    decision: SamplingDecision,

    /// Additional attributes to add to the span (optional)
    attributes: ?[]const AttributeKeyValue = null,

    /// Trace state to associate with the span (optional)
    trace_state: ?[]const u8 = null,

    /// Create a simple sampling result with just a decision
    pub fn simple(decision: SamplingDecision) SamplingResult {
        return SamplingResult{
            .decision = decision,
        };
    }

    /// Create a sampling result with attributes
    pub fn withAttributes(decision: SamplingDecision, attributes: []const AttributeKeyValue) SamplingResult {
        return SamplingResult{
            .decision = decision,
            .attributes = attributes,
        };
    }

    /// Create a sampling result with trace state
    pub fn withTraceState(decision: SamplingDecision, trace_state: []const u8) SamplingResult {
        return SamplingResult{
            .decision = decision,
            .trace_state = trace_state,
        };
    }

    /// Create a sampling result with both attributes and trace state
    pub fn full(decision: SamplingDecision, attributes: ?[]const AttributeKeyValue, trace_state: ?[]const u8) SamplingResult {
        return SamplingResult{
            .decision = decision,
            .attributes = attributes,
            .trace_state = trace_state,
        };
    }

    /// Check if this result has additional attributes
    pub fn hasAttributes(self: SamplingResult) bool {
        return self.attributes != null and self.attributes.?.len > 0;
    }

    /// Check if this result has trace state
    pub fn hasTraceState(self: SamplingResult) bool {
        return self.trace_state != null and self.trace_state.?.len > 0;
    }

    /// Format SamplingResult for debugging
    pub fn format(self: SamplingResult, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("SamplingResult{{decision={}", .{self.decision});

        if (self.attributes) |attrs| {
            try writer.print(", attributes=[", .{});
            for (attrs, 0..) |attr, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{}={}", .{ std.fmt.fmtSliceEscapeUpper(attr.key), attr.value });
            }
            try writer.writeAll("]");
        }

        if (self.trace_state) |state| {
            try writer.print(", trace_state=\"{s}\"", .{state});
        }

        try writer.writeAll("}");
    }
};

/// Parameters passed to the shouldSample method
pub const SampleParams = struct {
    /// Context with parent span information
    context: Context,

    /// Trace ID of the span to be created
    trace_id: TraceId,

    /// Name of the span to be created
    span_name: []const u8,

    /// Kind of the span to be created
    span_kind: spans.SpanKind,

    /// Initial attributes of the span to be created (optional)
    attributes: ?[]const AttributeKeyValue = null,

    /// Links that will be associated with the span (optional)
    links: ?[]const spans.Link = null,
};

/// Sampler interface using tagged union for compile-time polymorphism.
/// In the API layer, only the noop implementation is provided.
/// SDK implementations will extend this with concrete samplers.
pub const Sampler = union(enum) {
    drop: void,
    keep: void,
    bridge: SamplerBridge, // SDK sampler bridge

    /// Make a sampling decision for a span about to be created
    pub fn shouldSample(self: Sampler, params: SampleParams) SamplingResult {
        return switch (self) {
            .drop => SamplingResult.simple(.drop),
            .keep => SamplingResult.simple(.record_and_sample),
            .bridge => |bridge| bridge.shouldSampleFn(bridge.sampler_ptr, params),
        };
    }

    /// Get a description of this sampler
    pub fn getDescription(self: Sampler) []const u8 {
        return switch (self) {
            .drop => "Drop all sampler",
            .keep => "Keep all sampler",
            .bridge => |bridge| bridge.getDescriptionFn(bridge.sampler_ptr),
        };
    }
};

/// Bridge structure that holds SDK sampler pointer and vtable
pub const SamplerBridge = struct {
    sampler_ptr: *anyopaque,
    shouldSampleFn: *const fn (sampler_ptr: *anyopaque, params: SampleParams) SamplingResult,
    getDescriptionFn: *const fn (sampler_ptr: *anyopaque) []const u8,

    pub fn init(ptr: anytype) SamplerBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn shouldSample(pointer: *anyopaque, params: SampleParams) SamplingResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.shouldSample(self, params);
            }

            pub fn getDescription(pointer: *anyopaque) []const u8 {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getDescription(self);
            }
        };

        return .{
            .sampler_ptr = ptr,
            .shouldSampleFn = VTable.shouldSample,
            .getDescriptionFn = VTable.getDescription,
        };
    }
};

// Tests

test "SamplingDecision behavior" {
    const testing = std.testing;

    // Test drop decision
    const drop = SamplingDecision.drop;
    try testing.expect(!drop.shouldRecord());
    try testing.expect(!drop.shouldSample());

    // Test record_only decision
    const record_only = SamplingDecision.record_only;
    try testing.expect(record_only.shouldRecord());
    try testing.expect(!record_only.shouldSample());

    // Test record_and_sample decision
    const record_and_sample = SamplingDecision.record_and_sample;
    try testing.expect(record_and_sample.shouldRecord());
    try testing.expect(record_and_sample.shouldSample());
}

test "SamplingResult creation" {
    const testing = std.testing;
    const AttributeValue = @import("../common/root.zig").AttributeValue;

    // Test simple result
    const simple = SamplingResult.simple(.record_and_sample);
    try testing.expectEqual(SamplingDecision.record_and_sample, simple.decision);
    try testing.expect(simple.attributes == null);
    try testing.expect(simple.trace_state == null);
    try testing.expect(!simple.hasAttributes());
    try testing.expect(!simple.hasTraceState());

    // Test result with attributes
    const attrs = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "sampler", .value = AttributeValue{ .string = "test" } },
    };
    const with_attrs = SamplingResult.withAttributes(.record_only, &attrs);
    try testing.expectEqual(SamplingDecision.record_only, with_attrs.decision);
    try testing.expect(with_attrs.hasAttributes());
    try testing.expectEqual(@as(usize, 1), with_attrs.attributes.?.len);
    try testing.expectEqualStrings("sampler", with_attrs.attributes.?[0].key);

    // Test result with trace state
    const with_state = SamplingResult.withTraceState(.drop, "sampler=test");
    try testing.expectEqual(SamplingDecision.drop, with_state.decision);
    try testing.expect(with_state.hasTraceState());
    try testing.expectEqualStrings("sampler=test", with_state.trace_state.?);

    // Test full result
    const full = SamplingResult.full(.record_and_sample, &attrs, "state=value");
    try testing.expectEqual(SamplingDecision.record_and_sample, full.decision);
    try testing.expect(full.hasAttributes());
    try testing.expect(full.hasTraceState());
    try testing.expectEqualStrings("state=value", full.trace_state.?);
}

test "SamplingResult edge cases" {
    const testing = std.testing;

    // Test with empty attributes
    const empty_attrs = [_]AttributeKeyValue{};
    const result_empty_attrs = SamplingResult.withAttributes(.record_only, &empty_attrs);
    try testing.expect(!result_empty_attrs.hasAttributes()); // Empty array should report false

    // Test with empty trace state
    const result_empty_state = SamplingResult.withTraceState(.drop, "");
    try testing.expect(!result_empty_state.hasTraceState()); // Empty string should report false

    // Test null values in full constructor
    const result_nulls = SamplingResult.full(.record_and_sample, null, null);
    try testing.expect(!result_nulls.hasAttributes());
    try testing.expect(!result_nulls.hasTraceState());
}

test "SamplingDecision format" {
    const testing = std.testing;

    var buf: [32]u8 = undefined;

    const drop_formatted = try std.fmt.bufPrint(&buf, "{}", .{SamplingDecision.drop});
    try testing.expectEqualStrings("drop", drop_formatted);

    const record_only_formatted = try std.fmt.bufPrint(&buf, "{}", .{SamplingDecision.record_only});
    try testing.expectEqualStrings("record_only", record_only_formatted);

    const record_and_sample_formatted = try std.fmt.bufPrint(&buf, "{}", .{SamplingDecision.record_and_sample});
    try testing.expectEqualStrings("record_and_sample", record_and_sample_formatted);
}

test "SamplingResult format" {
    const testing = std.testing;
    const AttributeValue = @import("../common/root.zig").AttributeValue;

    var buf: [512]u8 = undefined;

    // Test simple result formatting
    const simple = SamplingResult.simple(.drop);
    const simple_formatted = try std.fmt.bufPrint(&buf, "{}", .{simple});
    try testing.expect(std.mem.indexOf(u8, simple_formatted, "SamplingResult{decision=drop}") != null);

    // Test result with attributes formatting
    const attrs = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "test", .value = AttributeValue{ .string = "value" } },
    };
    const with_attrs = SamplingResult.withAttributes(.record_only, &attrs);
    const attrs_formatted = try std.fmt.bufPrint(&buf, "{}", .{with_attrs});
    try testing.expect(std.mem.indexOf(u8, attrs_formatted, "decision=record_only") != null);
    try testing.expect(std.mem.indexOf(u8, attrs_formatted, "attributes=[") != null);
    try testing.expect(std.mem.indexOf(u8, attrs_formatted, "test=") != null);

    // Test result with trace state formatting
    const with_state = SamplingResult.withTraceState(.record_and_sample, "state=test");
    const state_formatted = try std.fmt.bufPrint(&buf, "{}", .{with_state});
    try testing.expect(std.mem.indexOf(u8, state_formatted, "decision=record_and_sample") != null);
    try testing.expect(std.mem.indexOf(u8, state_formatted, "trace_state=\"state=test\"") != null);
}

test "SampleParams creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    const trace_id = TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    const params = SampleParams{
        .context = ctx,
        .trace_id = trace_id,
        .span_name = "test-span",
        .span_kind = .client,
    };

    try testing.expectEqualSlices(u8, &trace_id.bytes, &params.trace_id.bytes);
    try testing.expectEqualStrings("test-span", params.span_name);
    try testing.expectEqual(spans.SpanKind.client, params.span_kind);
    try testing.expect(params.attributes == null);
    try testing.expect(params.links == null);
}

test "Sampler keep variant" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    const sampler = Sampler{ .keep = {} };
    const trace_id = TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    const params = SampleParams{
        .context = ctx,
        .trace_id = trace_id,
        .span_name = "test-span",
        .span_kind = .internal,
    };

    // Test shouldSample method
    const result = sampler.shouldSample(params);
    try testing.expectEqual(SamplingDecision.record_and_sample, result.decision);

    // Test getDescription method
    const description = sampler.getDescription();
    try testing.expectEqualStrings("Keep all sampler", description);
}

test "Sampler drop variant" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    const sampler = Sampler{ .drop = {} };
    const trace_id = TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    const params = SampleParams{
        .context = ctx,
        .trace_id = trace_id,
        .span_name = "test-span",
        .span_kind = .internal,
    };

    // Test shouldSample method
    const result = sampler.shouldSample(params);
    try testing.expectEqual(SamplingDecision.drop, result.decision);

    // Test getDescription method
    const description = sampler.getDescription();
    try testing.expectEqualStrings("Drop all sampler", description);
}

test "SamplerBridge functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock sampler implementation for testing
    const MockSampler = struct {
        decision: SamplingDecision,

        const Self = @This();

        pub fn shouldSample(self: *const Self, params: SampleParams) SamplingResult {
            _ = params;
            return SamplingResult.simple(self.decision);
        }

        pub fn getDescription(self: *const Self) []const u8 {
            _ = self;
            return "MockSampler";
        }
    };

    var ctx = Context.empty(allocator);
    defer ctx.deinit();

    var mock_sampler = MockSampler{ .decision = .drop };
    const bridge = SamplerBridge.init(&mock_sampler);
    const sampler = Sampler{ .bridge = bridge };

    const trace_id = TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    const params = SampleParams{
        .context = ctx,
        .trace_id = trace_id,
        .span_name = "test-span",
        .span_kind = .producer,
    };

    // Test shouldSample through bridge
    const result = sampler.shouldSample(params);
    try testing.expectEqual(SamplingDecision.drop, result.decision);

    // Test getDescription through bridge
    const description = sampler.getDescription();
    try testing.expectEqualStrings("MockSampler", description);
}
