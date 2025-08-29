const std = @import("std");

const Timeout = @This();

start: i64,
timeout: ?u64,

pub inline fn init(timeout_ms: ?u64) Timeout {
    return .{
        .start = std.time.milliTimestamp(),
        .timeout = timeout_ms,
    };
}

pub inline fn elapsed(self: *const Timeout) u64 {
    return @as(u64, @intCast(std.time.milliTimestamp() - self.start));
}

pub inline fn isExpired(self: *const Timeout) bool {
    return if (self.timeout) |to| to <= self.elapsed() else false;
}

pub inline fn remaining(self: *const Timeout) !?u64 {
    return if (self.timeout) |to| blk: {
        const spent = self.elapsed();
        break :blk if (to <= spent) error.expired_timeout else to - spent;
    } else null;
}
