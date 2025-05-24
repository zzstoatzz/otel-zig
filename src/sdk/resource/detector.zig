//! OpenTelemetry SDK Resource Detector
//!
//! This module provides resource detection capabilities for automatically
//! discovering resource attributes from the environment, process, and host.
//!
//! ## Components
//! - `ResourceDetector` - Interface for resource detection
//! - `DefaultDetector` - Combines multiple detectors
//! - `ProcessDetector` - Detects process attributes (PID, executable name, etc.)
//! - `HostDetector` - Detects host attributes (hostname, OS, etc.)
//! - `EnvironmentDetector` - Detects from OTEL_RESOURCE_ATTRIBUTES env var
//!
//! ## Usage
//! ```zig
//! const resource = try detectResource(allocator);
//! defer resource.deinit();
//! ```

const std = @import("std");
const builtin = @import("builtin");
const otel_api = @import("otel-api");
const Resource = @import("resource.zig").Resource;

const AttributeValue = otel_api.common.AttributeValue;
const KeyValue = otel_api.common.KeyValue;
const AttributeBuilder = otel_api.common.AttributeBuilder;

/// Resource detector interface using tagged union
pub const ResourceDetector = union(enum) {
    default: DefaultDetector,
    process: ProcessDetector,
    host: HostDetector,
    environment: EnvironmentDetector,
    custom: CustomDetector,

    /// Detect resource attributes
    pub fn detect(self: *ResourceDetector, allocator: std.mem.Allocator) anyerror!Resource {
        return switch (self.*) {
            .default => |*detector| detector.detect(allocator),
            .process => |*detector| detector.detect(allocator),
            .host => |*detector| detector.detect(allocator),
            .environment => |*detector| detector.detect(allocator),
            .custom => |*detector| detector.detect(allocator),
        };
    }
};

/// Default detector that combines multiple detectors
pub const DefaultDetector = struct {
    detectors: []ResourceDetector,

    pub fn init(detectors: []ResourceDetector) DefaultDetector {
        return .{ .detectors = detectors };
    }

    pub fn detect(self: *DefaultDetector, allocator: std.mem.Allocator) anyerror!Resource {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var builder = AttributeBuilder.init(arena.allocator());
        errdefer builder.deinit();

        // Add default SDK attributes
        try builder.addString("telemetry.sdk.name", "opentelemetry");
        try builder.addString("telemetry.sdk.language", "zig");
        try builder.addString("telemetry.sdk.version", "0.1.0");

        // Run all detectors
        for (self.detectors) |*detector| {
            // Intentionally letting the arena deal with the free.
            // Otherwise the strings are freed before the finish.
            const detected = try detector.detect(arena.allocator());
            try builder.addKeyValues(detected.attributes);
        }

        const attrs = try builder.finish(allocator);
        return Resource.init(attrs, null);
    }
};

/// Process resource detector
pub const ProcessDetector = struct {
    pub fn init() ProcessDetector {
        return .{};
    }

    pub fn detect(self: *ProcessDetector, allocator: std.mem.Allocator) anyerror!Resource {
        _ = self;
        var attrs = std.ArrayList(KeyValue).init(allocator);
        defer attrs.deinit();

        // Detect process attributes
        const pid = std.c.getpid();
        // const pid = std.os.linux.getpid();
        try attrs.append(KeyValue.init("process.pid", .{ .int = @intCast(pid) }));

        // Get executable path
        switch (builtin.os.tag) {
            .macos => {
                var buf: [std.fs.max_path_bytes:0]u8 = undefined;
                var size: u32 = buf.len;

                if (std.c._NSGetExecutablePath(&buf, &size) == 0) {
                    const path = std.mem.sliceTo(&buf, 0);
                    const basename = std.fs.path.basename(path);
                    try attrs.append(KeyValue.init("process.executable.path", .{ .string = path }));
                    try attrs.append(KeyValue.init("process.executable.name", .{ .string = basename }));
                }
            },
            else => @compileError("unsupported OS."),
        }

        // Command line args (if available)
        if (std.process.argsAlloc(allocator)) |args| {
            defer std.process.argsFree(allocator, args);
            if (args.len > 0) {
                try attrs.append(KeyValue.init("process.command", .{ .string = args[0] }));
            }
        } else |_| {}

        const owned_attrs = try attrs.toOwnedSlice();
        return Resource.init(owned_attrs, null);
    }
};

/// Host resource detector
pub const HostDetector = struct {
    pub fn init() HostDetector {
        return .{};
    }

    pub fn detect(self: *HostDetector, allocator: std.mem.Allocator) anyerror!Resource {
        _ = self;
        var attrs = std.ArrayList(KeyValue).init(allocator);
        defer attrs.deinit();

        // Detect host name
        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&hostname_buf)) |hostname| {
            try attrs.append(KeyValue.init("host.name", .{ .string = hostname }));
        } else |_| {}

        // Detect OS type
        const os_type = switch (builtin.target.os.tag) {
            .linux => "linux",
            .windows => "windows",
            .macos => "darwin",
            .freebsd => "freebsd",
            .openbsd => "openbsd",
            .netbsd => "netbsd",
            .dragonfly => "dragonfly",
            else => "unknown",
        };
        try attrs.append(KeyValue.init("host.type", .{ .string = os_type }));

        // Detect architecture
        const arch = switch (builtin.target.cpu.arch) {
            .x86_64 => "amd64",
            .x86 => "x86",
            .aarch64 => "arm64",
            .arm => "arm",
            .riscv64 => "riscv64",
            .wasm32 => "wasm32",
            else => "unknown",
        };
        try attrs.append(KeyValue.init("host.arch", .{ .string = arch }));

        const owned_attrs = try attrs.toOwnedSlice();
        return Resource.init(owned_attrs, null);
    }
};

/// Environment variable resource detector
pub const EnvironmentDetector = struct {
    pub fn init() EnvironmentDetector {
        return .{};
    }

    pub fn detect(self: *EnvironmentDetector, allocator: std.mem.Allocator) anyerror!Resource {
        _ = self;
        var attrs = std.ArrayList(KeyValue).init(allocator);
        defer attrs.deinit();

        // Check OTEL_RESOURCE_ATTRIBUTES
        if (std.process.getEnvVarOwned(allocator, "OTEL_RESOURCE_ATTRIBUTES")) |env_attrs| {
            defer allocator.free(env_attrs);

            // Parse key=value pairs separated by commas
            var iter = std.mem.tokenizeScalar(u8, env_attrs, ',');
            while (iter.next()) |pair| {
                const trimmed = std.mem.trim(u8, pair, " ");
                if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                    const key = trimmed[0..eq_pos];
                    const value = trimmed[eq_pos + 1 ..];
                    try attrs.append(KeyValue.init(key, .{ .string = value }));
                }
            }
        } else |_| {}

        // Check OTEL_SERVICE_NAME
        if (std.process.getEnvVarOwned(allocator, "OTEL_SERVICE_NAME")) |service_name| {
            defer allocator.free(service_name);
            try attrs.append(KeyValue.init("service.name", .{ .string = service_name }));
        } else |_| {}

        const owned_attrs = try attrs.toOwnedSlice();
        return Resource.init(owned_attrs, null);
    }
};

/// Custom detector with user-provided implementation
pub const CustomDetector = struct {
    impl: *anyopaque,
    detectFn: *const fn (impl: *anyopaque, allocator: std.mem.Allocator) anyerror!Resource,

    pub fn init(
        impl: *anyopaque,
        detectFn: *const fn (impl: *anyopaque, allocator: std.mem.Allocator) anyerror!Resource,
    ) CustomDetector {
        return .{
            .impl = impl,
            .detectFn = detectFn,
        };
    }

    pub fn detect(self: *CustomDetector, allocator: std.mem.Allocator) anyerror!Resource {
        return self.detectFn(self.impl, allocator);
    }
};

/// Detect resource using all default detectors
pub fn detectResource(allocator: std.mem.Allocator) anyerror!Resource {
    const process_detector = ResourceDetector{ .process = ProcessDetector.init() };
    const host_detector = ResourceDetector{ .host = HostDetector.init() };
    const env_detector = ResourceDetector{ .environment = EnvironmentDetector.init() };

    var detectors = [_]ResourceDetector{ process_detector, host_detector, env_detector };
    const default_detector = DefaultDetector.init(&detectors);
    var detector = ResourceDetector{ .default = default_detector };

    return detector.detect(allocator);
}

test "ProcessDetector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var detector = ProcessDetector.init();
    var resource = try detector.detect(allocator);
    defer allocator.free(resource.attributes);

    // Should have process.pid
    try testing.expect(resource.getAttribute("process.pid") != null);
    if (resource.getAttribute("process.pid")) |pid_value| {
        try testing.expect(pid_value.int > 0);
    }
}

test "HostDetector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var detector = HostDetector.init();
    var resource = try detector.detect(allocator);
    defer allocator.free(resource.attributes);

    // Should have host.type and host.arch
    try testing.expect(resource.getAttribute("host.type") != null);
    try testing.expect(resource.getAttribute("host.arch") != null);
}

test "DefaultDetector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var resource = try detectResource(allocator);
    defer resource.deinitOwned(allocator);

    // Should have SDK attributes
    try testing.expect(resource.getAttribute("telemetry.sdk.name") != null);
    try testing.expect(resource.getAttribute("telemetry.sdk.language") != null);
    try testing.expect(resource.getAttribute("telemetry.sdk.version") != null);

    // Should have process and host attributes
    try testing.expect(resource.getAttribute("process.pid") != null);
    try testing.expect(resource.getAttribute("host.type") != null);
}
