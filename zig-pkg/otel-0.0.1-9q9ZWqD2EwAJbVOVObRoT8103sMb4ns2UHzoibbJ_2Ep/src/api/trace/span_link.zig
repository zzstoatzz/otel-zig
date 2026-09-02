const std = @import("std");
const api = struct {
    const AttributeKeyValue = @import("../common/attributes.zig").AttributeKeyValue;
    const trace = struct {
        const Span = @import("span.zig").Span;
    };
};

const Link = @This();

/// The span context of the linked span
span_context: api.trace.Span.Context,

/// Optional attributes providing additional context about the link
attributes: []const api.AttributeKeyValue = &.{},
