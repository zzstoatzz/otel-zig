//! structures to help with the creation of pipelines attached to processors.

const std = @import("std");

pub fn PipelineBuilder(comptime ProviderT: type) type {
    return union(enum) {
        const Self = @This();
        const ProviderType = ProviderT;

        provider: ProviderType,
        invalid: anyerror,

        pub fn init(provider: ProviderType) Self {
            return .{
                .provider = provider,
            };
        }

        pub fn with(self: Self, link: anytype) Self {
            switch (self) {
                .provider => |provider| {
                    const LinkType = @TypeOf(link);

                    const processor_raw = provider.allocator.create(LinkType.ConcreteType) catch |e| return .{ .invalid = e };
                    processor_raw.* = link.make(provider.allocator) catch |e| {
                        provider.allocator.destroy(processor_raw);
                        return .{ .invalid = e };
                    };
                    const processor_interface = LinkType.convertFn(processor_raw);

                    provider.registerProcessor(processor_interface) catch |e| {
                        if (@hasDecl(LinkType.ConcreteType, "deinit")) processor_raw.deinit();
                        provider.allocator.destroy(processor_raw);
                        return .{ .invalid = e };
                    };

                    return .{ .provider = provider };
                },
                .invalid => |e| return .{ .invalid = e },
            }
        }

        pub fn done(self: Self) !void {
            return switch (self) {
                .provider => {},
                .invalid => |e| e,
            };
        }
    };
}

/// Instructions for how to create a step in a pipeline.
///
/// ConcreteT is a concrete processor or reader type, not an interface to a type.
/// InterfaceT is is the SDK interface the type implements (what the user of the pipeline will interact with)
/// ContextT is the type passed as context for the initFunc closure.
/// convertFunc must have the signature `fn(*ConcreteT) InterfaceT`
/// initFunc must have the signature `fn (ContextT, allocator) !ConcreteT`
/// connectFunc must have the signature `fn (HeadT.ConcreteType, TailT.InterfaceType) !void`
pub fn PipelineStepInstructions(
    comptime ConcreteT: type,
    comptime InterfaceT: type,
    comptime ContextT: type,
    comptime ConvertFunc: anytype,
    comptime InitFunc: anytype,
    comptime ConnectFunc: anytype,
) type {
    return struct {
        const Self = @This();
        pub const ConcreteType = ConcreteT;
        pub const InterfaceType = InterfaceT;
        pub const ContextType = ContextT;
        pub const convertFn = ConvertFunc;
        pub const initFn = InitFunc;
        pub const connectFn = ConnectFunc;

        context: ContextType,

        pub fn init(ctx: ContextType) Self {
            return .{ .context = ctx };
        }

        pub fn make(self: Self, allocator: std.mem.Allocator) !ConcreteType {
            const head = try initFn(self.context, allocator);
            errdefer if (@hasDecl(ConcreteType, "deinit")) head.deinit() else {};
            return head;
        }

        pub fn flowTo(self: Self, next_step: anytype) PipelineStepLink(Self, @TypeOf(next_step), Self.connectFn) {
            return .init(self, next_step);
        }
    };
}

pub fn PipelineStepLink(comptime HeadT: type, comptime TailT: type, comptime connectFunc: anytype) type {
    return struct {
        const Self = @This();
        pub const ConcreteType = HeadT.ConcreteType;
        pub const InterfaceType = HeadT.InterfaceType;
        pub const convertFn = HeadT.convertFn;

        pub const Head = HeadT;
        pub const Tail = TailT;

        head_step: Head,
        tail_step: Tail,

        pub fn init(head_step: Head, tail_step: Tail) Self {
            return .{
                .head_step = head_step,
                .tail_step = tail_step,
            };
        }

        pub fn make(self: Self, allocator: std.mem.Allocator) !Head.ConcreteType {
            const tail_raw = try allocator.create(Tail.ConcreteType);
            errdefer allocator.destroy(tail_raw);
            tail_raw.* = try self.tail_step.make(allocator);
            errdefer if (@hasDecl(Tail.ConcreteType, "deinit")) tail_raw.deinit() else {};
            const tail_interface = Tail.convertFn(tail_raw);

            var head_raw = try self.head_step.make(allocator);
            errdefer if (@hasDecl(Tail.ConcreteType, "deinit")) tail_raw.deinit() else {};
            try connectFunc(&head_raw, tail_interface);

            return head_raw;
        }
    };
}

pub fn PipelineDeinitConnection(_: anytype, tail: anytype) !void {
    tail.deinit();
}
