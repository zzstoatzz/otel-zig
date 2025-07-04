//! Observable Process Metrics Example
//!
//! This example demonstrates real-world usage of observable instruments by
//! monitoring actual process metrics like CPU usage, memory consumption,
//! file descriptors, and network connections. This showcases practical
//! use cases for async/observable instruments.
//!
//! Run with: zig build example-observable-process

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

// Process metrics state
const ProcessMetrics = struct {
    allocator: std.mem.Allocator,
    pid: u32,
    page_size: usize,

    // Cached values
    last_cpu_time: u64 = 0,
    last_check_time: i64 = 0,
    cpu_percent: f64 = 0.0,

    pub fn init(allocator: std.mem.Allocator) ProcessMetrics {
        return ProcessMetrics{
            .allocator = allocator,
            .pid = @as(u32, @intCast(std.os.linux.getpid())),
            .page_size = 4096, // Standard page size
        };
    }

    pub fn updateCpuUsage(self: *ProcessMetrics) void {
        const current_time = std.time.milliTimestamp();

        if (self.last_check_time == 0) {
            self.last_check_time = current_time;
            self.last_cpu_time = self.getCpuTime() catch 0;
            return;
        }

        const cpu_time = self.getCpuTime() catch return;
        const time_diff = current_time - self.last_check_time;
        const cpu_diff = cpu_time - self.last_cpu_time;

        if (time_diff > 0) {
            // Convert to percentage (cpu time is in clock ticks, usually 100 per second)
            self.cpu_percent = @as(f64, @floatFromInt(cpu_diff)) / (@as(f64, @floatFromInt(time_diff)) / 1000.0) / 100.0 * 100.0;
            if (self.cpu_percent > 100.0) self.cpu_percent = 100.0;
        }

        self.last_cpu_time = cpu_time;
        self.last_check_time = current_time;
    }

    fn getCpuTime(self: *ProcessMetrics) !u64 {
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "/proc/{}/stat", .{self.pid});

        const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024);
        defer self.allocator.free(content);

        // Parse the stat file - fields 14 and 15 are utime and stime
        var it = std.mem.splitScalar(u8, content, ' ');
        var field_index: u32 = 0;
        var utime: u64 = 0;
        var stime: u64 = 0;

        while (it.next()) |field| {
            field_index += 1;
            if (field_index == 14) {
                utime = std.fmt.parseInt(u64, field, 10) catch 0;
            } else if (field_index == 15) {
                stime = std.fmt.parseInt(u64, field, 10) catch 0;
                break;
            }
        }

        return utime + stime;
    }

    pub fn getMemoryUsage(self: *ProcessMetrics) u64 {
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/proc/{}/statm", .{self.pid}) catch return 0;

        const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 256) catch return 0;
        defer self.allocator.free(content);

        // First field is total virtual memory in pages
        var it = std.mem.splitScalar(u8, content, ' ');
        if (it.next()) |first_field| {
            const pages = std.fmt.parseInt(u64, std.mem.trim(u8, first_field, " \n"), 10) catch return 0;
            return pages * self.page_size;
        }

        return 0;
    }

    pub fn getResidentMemory(self: *ProcessMetrics) u64 {
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/proc/{}/statm", .{self.pid}) catch return 0;

        const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 256) catch return 0;
        defer self.allocator.free(content);

        // Second field is resident memory in pages
        var it = std.mem.splitScalar(u8, content, ' ');
        _ = it.next(); // skip first
        if (it.next()) |second_field| {
            const pages = std.fmt.parseInt(u64, std.mem.trim(u8, second_field, " \n"), 10) catch return 0;
            return pages * self.page_size;
        }

        return 0;
    }

    pub fn getFileDescriptorCount(self: *ProcessMetrics) u64 {
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/proc/{}/fd", .{self.pid}) catch return 0;

        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var count: u64 = 0;
        var iterator = dir.iterate();
        while (iterator.next() catch null) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                count += 1;
            }
        }

        return count;
    }

    pub fn getThreadCount(self: *ProcessMetrics) u64 {
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/proc/{}/task", .{self.pid}) catch return 0;

        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return 1;
        defer dir.close();

        var count: u64 = 0;
        var iterator = dir.iterate();
        while (iterator.next() catch null) |entry| {
            if (entry.kind == .directory) {
                count += 1;
            }
        }

        return if (count > 0) count else 1;
    }
};

var process_metrics: ProcessMetrics = undefined;

// Callback functions for different metrics
fn cpuUsageCallback(result: *otel_api.metrics.ObservableResult(f64), state: *ProcessMetrics) void {
    state.updateCpuUsage();

    const attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "process.pid", .value = .{ .int = @intCast(state.pid) } },
        .{ .key = "metric.type", .value = .{ .string = "cpu_usage" } },
    };

    result.observe(state.cpu_percent, &attrs, null) catch {};
}

fn memoryUsageCallback(result: *otel_api.metrics.ObservableResult(i64), state: *ProcessMetrics) void {
    const virtual_memory = state.getMemoryUsage();
    const resident_memory = state.getResidentMemory();

    const virtual_attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "process.pid", .value = .{ .int = @intCast(state.pid) } },
        .{ .key = "memory.type", .value = .{ .string = "virtual" } },
    };

    const resident_attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "process.pid", .value = .{ .int = @intCast(state.pid) } },
        .{ .key = "memory.type", .value = .{ .string = "resident" } },
    };

    result.observe(@intCast(virtual_memory), &virtual_attrs, null) catch {};
    result.observe(@intCast(resident_memory), &resident_attrs, null) catch {};
}

fn resourceUsageCallback(result: *otel_api.metrics.ObservableResult(i64), state: *ProcessMetrics) void {
    const fd_count = state.getFileDescriptorCount();
    const thread_count = state.getThreadCount();

    const fd_attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "process.pid", .value = .{ .int = @intCast(state.pid) } },
        .{ .key = "resource.type", .value = .{ .string = "file_descriptors" } },
    };

    const thread_attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "process.pid", .value = .{ .int = @intCast(state.pid) } },
        .{ .key = "resource.type", .value = .{ .string = "threads" } },
    };

    result.observe(@intCast(fd_count), &fd_attrs, null) catch {};
    result.observe(@intCast(thread_count), &thread_attrs, null) catch {};
}

// System-wide metrics callback
fn systemUptimeCallback(result: *otel_api.metrics.ObservableResult(f64)) void {
    const file = std.fs.openFileAbsolute("/proc/uptime", .{}) catch return;
    defer file.close();

    var buf: [64]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return;
    const content = buf[0..bytes_read];

    var it = std.mem.splitScalar(u8, content, ' ');
    if (it.next()) |uptime_str| {
        const uptime = std.fmt.parseFloat(f64, std.mem.trim(u8, uptime_str, " \n")) catch return;

        const attrs = [_]otel_api.common.AttributeKeyValue{
            .{ .key = "metric.source", .value = .{ .string = "proc_uptime" } },
        };

        result.observe(uptime, &attrs, null) catch {};
    }
}

// Load average callback
fn systemLoadCallback(result: *otel_api.metrics.ObservableResult(f64)) void {
    const file = std.fs.openFileAbsolute("/proc/loadavg", .{}) catch return;
    defer file.close();

    var buf: [128]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return;
    const content = buf[0..bytes_read];

    var it = std.mem.splitScalar(u8, content, ' ');

    // Load averages: 1min, 5min, 15min
    const load_periods = [_][]const u8{ "1min", "5min", "15min" };

    for (load_periods) |period| {
        if (it.next()) |load_str| {
            const load = std.fmt.parseFloat(f64, std.mem.trim(u8, load_str, " \n")) catch continue;

            const attrs = [_]otel_api.common.AttributeKeyValue{
                .{ .key = "load.period", .value = .{ .string = period } },
                .{ .key = "metric.source", .value = .{ .string = "proc_loadavg" } },
            };

            result.observe(load, &attrs, null) catch {};
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== OpenTelemetry Observable Process Metrics Example ===", .{});
    std.log.info("Monitoring process PID: {}", .{@as(u32, @intCast(std.os.linux.getpid()))});

    // Initialize process metrics
    process_metrics = ProcessMetrics.init(allocator);

    // Set up OpenTelemetry with console exporter
    std.log.info("Setting up OpenTelemetry with console exporter...", .{});
    const provider = try otel_sdk.metrics.setupGlobalProvider(
        allocator,
        .{otel_sdk.metrics.BasicMetricProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.console.ConsoleMetricExporter.PipelineStep.init(.{}))},
    );
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Get a meter
    const scope = try otel_api.InstrumentationScope.initSimple("process.monitoring", "1.0.0");
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    std.log.info("Creating observable instruments for process monitoring...", .{});

    // Create observable instruments
    var cpu_gauge = try meter.createObservableGauge(f64, "process.cpu.usage", "Process CPU usage percentage", "percent", null, &[_]otel_api.metrics.TypeErasedCallback{});
    var memory_gauge = try meter.createObservableGauge(i64, "process.memory.usage", "Process memory usage", "bytes", null, &[_]otel_api.metrics.TypeErasedCallback{});
    var resource_gauge = try meter.createObservableGauge(i64, "process.resource.usage", "Process resource usage", "count", null, &[_]otel_api.metrics.TypeErasedCallback{});
    var uptime_gauge = try meter.createObservableGauge(f64, "system.uptime", "System uptime", "seconds", null, &[_]otel_api.metrics.TypeErasedCallback{});
    var load_gauge = try meter.createObservableGauge(f64, "system.load.average", "System load average", "ratio", null, &[_]otel_api.metrics.TypeErasedCallback{});

    std.log.info("Registering process monitoring callbacks...", .{});

    // Register callbacks
    const cpu_handle = try cpu_gauge.registerCallback(ProcessMetrics, cpuUsageCallback, &process_metrics);
    const memory_handle = try memory_gauge.registerCallback(ProcessMetrics, memoryUsageCallback, &process_metrics);
    const resource_handle = try resource_gauge.registerCallback(ProcessMetrics, resourceUsageCallback, &process_metrics);
    const uptime_handle = try uptime_gauge.registerCallbackNoState(systemUptimeCallback);
    const load_handle = try load_gauge.registerCallbackNoState(systemLoadCallback);

    defer {
        cpu_handle.unregister();
        memory_handle.unregister();
        resource_handle.unregister();
        uptime_handle.unregister();
        load_handle.unregister();
    }

    std.log.info("✓ All process monitoring callbacks registered", .{});
    std.log.info("", .{});

    // Monitor process for a while
    std.log.info("Starting process monitoring (will run for 30 seconds)...", .{});
    std.log.info("You can run some commands in another terminal to see metrics change:", .{});
    std.log.info("  - Run 'stress --cpu 1 --timeout 10s' to increase CPU usage", .{});
    std.log.info("  - Open many files with 'find /usr -name \"*.so\" | head -100 | xargs ls -l > /dev/null'", .{});
    std.log.info("", .{});

    // Create some workload to generate interesting metrics
    var background_work_thread: ?std.Thread = null;

    // Background work to generate some CPU and memory activity
    const BackgroundWork = struct {
        fn doWork() void {
            var data = std.ArrayList(u8).init(std.heap.page_allocator);
            defer data.deinit();

            for (0..100) |cycle| {
                // Allocate some memory
                data.appendNTimes(0, 1024 * 10) catch break; // 10KB per cycle

                // Do some CPU work
                var sum: u64 = 0;
                for (0..10000) |i| {
                    sum +%= i * i;
                }

                // Sleep briefly
                std.time.sleep(100 * std.time.ns_per_ms);

                // Occasionally free some memory
                if (cycle % 10 == 0 and data.items.len > 50000) {
                    data.shrinkRetainingCapacity(data.items.len / 2);
                }
            }
        }
    };

    background_work_thread = try std.Thread.spawn(.{}, BackgroundWork.doWork, .{});

    // Run monitoring for 30 seconds
    const monitoring_duration = 30; // seconds
    const collection_interval = 3; // seconds

    for (0..monitoring_duration / collection_interval) |cycle| {
        std.log.info("--- Monitoring Cycle {} ---", .{cycle + 1});

        // Display current metrics manually for demonstration
        process_metrics.updateCpuUsage();
        const memory_mb = @as(f64, @floatFromInt(process_metrics.getMemoryUsage())) / (1024.0 * 1024.0);
        const resident_mb = @as(f64, @floatFromInt(process_metrics.getResidentMemory())) / (1024.0 * 1024.0);
        const fd_count = process_metrics.getFileDescriptorCount();
        const thread_count = process_metrics.getThreadCount();

        std.log.info("Current Process Metrics:", .{});
        std.log.info("  CPU Usage: {d:.1}%", .{process_metrics.cpu_percent});
        std.log.info("  Virtual Memory: {d:.1} MB", .{memory_mb});
        std.log.info("  Resident Memory: {d:.1} MB", .{resident_mb});
        std.log.info("  File Descriptors: {}", .{fd_count});
        std.log.info("  Threads: {}", .{thread_count});
        std.log.info("", .{});

        // The actual metrics will be collected and exported automatically
        // by the OpenTelemetry periodic collection system

        std.time.sleep(collection_interval * std.time.ns_per_s);
    }

    // Wait for background work to complete
    if (background_work_thread) |thread| {
        thread.join();
    }

    std.log.info("=== Process Monitoring Complete ===", .{});
    std.log.info("This example demonstrated:", .{});
    std.log.info("  ✓ Real process CPU usage monitoring", .{});
    std.log.info("  ✓ Memory usage tracking (virtual and resident)", .{});
    std.log.info("  ✓ System resource monitoring (file descriptors, threads)", .{});
    std.log.info("  ✓ System-wide metrics (uptime, load average)", .{});
    std.log.info("  ✓ Multiple measurements per callback", .{});
    std.log.info("  ✓ Stateful and stateless callbacks", .{});
    std.log.info("  ✓ Real-world async instrument usage patterns", .{});
    std.log.info("", .{});
    std.log.info("💡 This shows how observable instruments are ideal for:", .{});
    std.log.info("   - System monitoring and observability", .{});
    std.log.info("   - Resource usage tracking", .{});
    std.log.info("   - Performance monitoring", .{});
    std.log.info("   - Any metric that represents current state", .{});
}
