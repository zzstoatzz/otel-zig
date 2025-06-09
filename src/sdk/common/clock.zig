//! OpenTelemetry SDK Clock Utilities
//!
//! This module provides time-related utilities for the SDK implementation.
//! It includes interfaces for different clock types and convenience functions
//! for getting timestamps in various formats.

const std = @import("std");

/// Clock interface for time operations
pub const Clock = union(enum) {
    system: SystemClock,
    monotonic: MonotonicClock,
    custom: CustomClock,

    /// Get current time in nanoseconds since Unix epoch
    pub fn now(self: *const Clock) i64 {
        return switch (self.*) {
            .system => |clock| clock.now(),
            .monotonic => |clock| clock.now(),
            .custom => |clock| clock.now(),
        };
    }
};

/// System clock that returns wall clock time
pub const SystemClock = struct {
    pub fn init() SystemClock {
        return .{};
    }

    pub fn now(self: *const SystemClock) i64 {
        _ = self;
        return @intCast(std.time.nanoTimestamp());
    }
};

/// Monotonic clock for measuring durations
pub const MonotonicClock = struct {
    start_time: i128,

    pub fn init() MonotonicClock {
        return .{
            .start_time = std.time.nanoTimestamp(),
        };
    }

    pub fn now(self: *const MonotonicClock) i64 {
        const current = std.time.nanoTimestamp();
        return @intCast(current - self.start_time);
    }
};

/// Custom clock with user-provided time function
pub const CustomClock = struct {
    impl: *anyopaque,
    nowFn: *const fn (impl: *anyopaque) i64,

    pub fn init(impl: *anyopaque, nowFn: *const fn (impl: *anyopaque) i64) CustomClock {
        return .{
            .impl = impl,
            .nowFn = nowFn,
        };
    }

    pub fn now(self: *const CustomClock) i64 {
        return self.nowFn(self.impl);
    }
};

/// Get current timestamp in nanoseconds since Unix epoch
pub fn getTimestamp() i64 {
    return @intCast(std.time.nanoTimestamp());
}

/// Get monotonic time for duration measurements
pub fn getMonotonicTime() i128 {
    return std.time.nanoTimestamp();
}

/// Convert nanoseconds to milliseconds
pub fn nanosToMillis(nanos: i64) i64 {
    return @divTrunc(nanos, std.time.ns_per_ms);
}

/// Convert milliseconds to nanoseconds
pub fn millisToNanos(millis: i64) i64 {
    return millis * std.time.ns_per_ms;
}

/// Format timestamp as ISO 8601 string
pub fn formatTimestamp(allocator: std.mem.Allocator, timestamp_ns: i64) ![]u8 {
    const seconds = @divTrunc(timestamp_ns, std.time.ns_per_s);
    const nanos = @as(u64, @intCast(@mod(timestamp_ns, std.time.ns_per_s)));

    // Use standard library epoch calculations
    const epoch_seconds = @as(u64, @intCast(@max(0, seconds)));

    // Calculate days since Unix epoch (1970-01-01)
    const epoch_days = epoch_seconds / (24 * 60 * 60);
    const day_seconds = epoch_seconds % (24 * 60 * 60);

    // Calculate date components using simpler algorithm
    var days_remaining = epoch_days;
    var year: u32 = 1970;

    // Find the year
    while (true) {
        const days_in_year = if (isLeapYear(year)) @as(u64, 366) else @as(u64, 365);
        if (days_remaining < days_in_year) break;
        days_remaining -= days_in_year;
        year += 1;
    }

    // Find the month and day
    const is_leap = isLeapYear(year);
    const month_days = if (is_leap)
        [_]u32{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u32 = 1;
    for (month_days) |days_in_month| {
        if (days_remaining < days_in_month) break;
        days_remaining -= days_in_month;
        month += 1;
    }
    const day = @as(u32, @intCast(days_remaining + 1));

    // Calculate time components
    const hours = day_seconds / 3600;
    const minutes = (day_seconds % 3600) / 60;
    const secs = day_seconds % 60;

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z", .{
        year, month, day, hours, minutes, secs, nanos,
    });
}

// Helper function for leap year calculation
fn isLeapYear(year: u32) bool {
    return (year % 4 == 0) and ((year % 100 != 0) or (year % 400 == 0));
}

test "SystemClock operations" {
    const testing = std.testing;

    const clock = SystemClock.init();
    const time1 = clock.now();
    std.time.sleep(1 * std.time.ns_per_ms);
    const time2 = clock.now();

    try testing.expect(time2 > time1);
}

test "MonotonicClock operations" {
    const testing = std.testing;

    const clock = MonotonicClock.init();
    const time1 = clock.now();
    std.time.sleep(1 * std.time.ns_per_ms);
    const time2 = clock.now();

    try testing.expect(time2 > time1);
}

test "CustomClock operations" {
    const testing = std.testing;

    const TestClock = struct {
        time: i64,

        fn now(impl: *anyopaque) i64 {
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            return self.time;
        }
    };

    var test_clock = TestClock{ .time = 1234567890 };
    const custom = CustomClock.init(&test_clock, TestClock.now);

    try testing.expectEqual(@as(i64, 1234567890), custom.now());

    test_clock.time = 9876543210;
    try testing.expectEqual(@as(i64, 9876543210), custom.now());
}

test "time conversion functions" {
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 1000), nanosToMillis(1000000000));
    try testing.expectEqual(@as(i64, 1000000000), millisToNanos(1000));
}

test "formatTimestamp" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Unix epoch (0)
    const timestamp1 = try formatTimestamp(allocator, 0);
    defer allocator.free(timestamp1);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000000000Z", timestamp1);

    // Test a known timestamp
    const timestamp2 = try formatTimestamp(allocator, 1609459200000000000); // 2021-01-01 00:00:00
    defer allocator.free(timestamp2);
    try testing.expectEqualStrings("2021-01-01T00:00:00.000000000Z", timestamp2);
}
