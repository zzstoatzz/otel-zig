//! OpenTelemetry Sampling Configuration
//!
//! This module defines the sampling interface and types according to the
//! OpenTelemetry specification. The API provides the interface definition
//! and a no-op implementation. Concrete samplers are provided by the SDK.
//!
//! See: https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling

const std = @import("std");
const api = struct {
    const AttributeKeyValue = @import("../common/attributes.zig").AttributeKeyValue;
    const ContextBuilder = @import("../context/context.zig").ContextBuilder;
    const ContextKeyValue = @import("../context/context.zig").ContextKeyValue;
    const common = struct {
        const TraceId = @import("../common/types.zig").TraceId;
    };
    const trace = struct {
        const Span = @import("span.zig").Span;
    };
};

/// Sampler interface using tagged union for compile-time polymorphism.
/// In the API layer, only the noop implementation is provided.
/// SDK implementations will extend this with concrete samplers.
pub const Sampler = union(enum) {
    drop: void,
    keep: void,
    bridge: Bridge, // SDK sampler bridge

    /// Make a sampling decision for a span about to be created
    pub fn shouldSample(self: Sampler, params: Params) Result {
        return switch (self) {
            .drop => Result{ .decision = .drop },
            .keep => Result{ .decision = .record_and_sample },
            .bridge => |bridge| bridge.shouldSampleFn(bridge.sampler_ptr, params),
        };
    }

    /// Get a description of this sampler
    pub fn getDescription(self: Sampler) []const u8 {
        return switch (self) {
            .drop => "AlwaysOffSampler",
            .keep => "AlwaysOnSampler",
            .bridge => |bridge| bridge.getDescriptionFn(bridge.sampler_ptr),
        };
    }

    /// SamplingResult contains the output of a sampling decision
    pub const Result = struct {
        /// The sampling decision
        decision: Decision,

        /// Additional attributes to add to the span (optional)
        attributes: ?[]const api.AttributeKeyValue = null,

        /// Trace state to associate with the span (optional)
        trace_state: ?[]const u8 = null,
    };

    /// SamplingDecision determines how a span should be handled
    pub const Decision = enum {
        /// Drop the span - IsRecording will be false, span will not be recorded
        drop,

        /// Record but don't sample - IsRecording will be true, but Sampled flag will not be set
        record_only,

        /// Record and sample - IsRecording will be true and Sampled flag will be set
        record_and_sample,

        /// Check if this decision indicates the span should be recorded
        pub fn shouldRecord(self: Decision) bool {
            return switch (self) {
                .drop => false,
                .record_only, .record_and_sample => true,
            };
        }

        /// Check if this decision indicates the span should be sampled
        pub fn shouldSample(self: Decision) bool {
            return switch (self) {
                .drop, .record_only => false,
                .record_and_sample => true,
            };
        }
    };

    /// Parameters passed to the shouldSample method
    pub const Params = struct {
        /// Allocator to use for any required memory.
        allocator: std.mem.Allocator,

        /// Context with parent span information
        context: []const api.ContextKeyValue,

        /// Trace ID of the span to be created
        trace_id: api.common.TraceId,

        /// Name of the span to be created
        span_name: []const u8,

        /// Kind of the span to be created
        span_kind: api.trace.Span.Kind,

        /// Initial attributes of the span to be created (optional)
        attributes: ?[]const api.AttributeKeyValue = null,

        /// Links that will be associated with the span (optional)
        links: ?[]const api.trace.Span.Link = null,

        /// Parent span context, for accessing trace state and flags.u
        parent_ctx: ?api.trace.Span.Context = null,
    };

    /// Bridge structure that holds SDK sampler pointer and vtable
    pub const Bridge = struct {
        sampler_ptr: *anyopaque,
        shouldSampleFn: *const fn (sampler_ptr: *anyopaque, params: Params) Result,
        getDescriptionFn: *const fn (sampler_ptr: *anyopaque) []const u8,

        pub fn init(ptr: anytype) Bridge {
            const T = @TypeOf(ptr);
            const ptr_info = @typeInfo(T);

            const VTable = struct {
                pub fn shouldSample(pointer: *anyopaque, params: Params) Result {
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
};

// Tests

test "SamplingDecision behavior" {
    const testing = std.testing;

    // Test drop decision
    const drop = Sampler.Decision.drop;
    try testing.expect(!drop.shouldRecord());
    try testing.expect(!drop.shouldSample());

    // Test record_only decision
    const record_only = Sampler.Decision.record_only;
    try testing.expect(record_only.shouldRecord());
    try testing.expect(!record_only.shouldSample());

    // Test record_and_sample decision
    const record_and_sample = Sampler.Decision.record_and_sample;
    try testing.expect(record_and_sample.shouldRecord());
    try testing.expect(record_and_sample.shouldSample());
}

test "Sampler keep variant" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    const sampler = Sampler{ .keep = {} };
    const trace_id = api.common.TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    const params = Sampler.Params{
        .allocator = allocator,
        .context = ctx,
        .trace_id = trace_id,
        .span_name = "test-span",
        .span_kind = .internal,
    };

    // Test shouldSample method
    const result = sampler.shouldSample(params);
    try testing.expectEqual(Sampler.Decision.record_and_sample, result.decision);

    // Test getDescription method
    const description = sampler.getDescription();
    try testing.expectEqualStrings("AlwaysOnSampler", description);
}

test "Sampler drop variant" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    const sampler = Sampler{ .drop = {} };
    const trace_id = api.common.TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    const params = Sampler.Params{
        .allocator = allocator,
        .context = ctx,
        .trace_id = trace_id,
        .span_name = "test-span",
        .span_kind = .internal,
    };

    // Test shouldSample method
    const result = sampler.shouldSample(params);
    try testing.expectEqual(Sampler.Decision.drop, result.decision);

    // Test getDescription method
    const description = sampler.getDescription();
    try testing.expectEqualStrings("AlwaysOffSampler", description);
}

test "SamplerBridge functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock sampler implementation for testing
    const AllwaysRecordOnlySampler = struct {
        pub fn shouldSample(_: *const @This(), _: Sampler.Params) Sampler.Result {
            return Sampler.Result{ .decision = .record_only };
        }

        pub fn getDescription(_: *const @This()) []const u8 {
            return "MockSampler";
        }
    };

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    var mock_sampler = AllwaysRecordOnlySampler{};
    const sampler = Sampler{ .bridge = .init(&mock_sampler) };

    const trace_id = api.common.TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    const params = Sampler.Params{
        .allocator = allocator,
        .context = ctx,
        .trace_id = trace_id,
        .span_name = "test-span",
        .span_kind = .producer,
    };

    // Test shouldSample through bridge
    const result = sampler.shouldSample(params);
    try testing.expectEqual(Sampler.Decision.record_only, result.decision);

    // Test getDescription through bridge
    const description = sampler.getDescription();
    try testing.expectEqualStrings("MockSampler", description);
}
