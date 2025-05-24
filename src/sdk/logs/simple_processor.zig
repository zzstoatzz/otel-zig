//! OpenTelemetry Simple Log Processor
//!
//! This module provides a simple processor implementation that immediately
//! exports each log record as it is emitted. This is useful for debugging
//! and low-volume scenarios but not recommended for production use.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md#simple-processor

const std = @import("std");
const otel_api = @import("otel-api");

const Context = otel_api.Context;
const LogRecord = otel_api.logs.LogRecord;
const LogExporter = @import("exporter.zig").LogExporter;
const ProcessorResult = @import("processor.zig").ProcessorResult;
const Resource = @import("../resource/resource.zig").Resource;

/// Simple log processor implementation
pub const SimpleLogProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: *LogExporter,
    mutex: std.Thread.Mutex,
    is_shutdown: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        exporter: *LogExporter,
    ) SimpleLogProcessor {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .is_shutdown = false,
        };
    }

    pub fn deinit(self: *SimpleLogProcessor) void {
        _ = self;
    }

    pub fn onEmit(self: *SimpleLogProcessor, record: LogRecord, ctx: Context, resource: *const Resource) void {
        _ = ctx;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return;
        }

        // Export single record immediately
        const records = [_]LogRecord{record};
        _ = self.exporter.exportRecords(&records, resource);
    }

    pub fn forceFlush(self: *SimpleLogProcessor, timeout_ms: ?u64) ProcessorResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = self.exporter.forceFlush(timeout_ms);
        return if (result == .success) .success else .failure;
    }

    pub fn shutdown(self: *SimpleLogProcessor, timeout_ms: ?u64) ProcessorResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;

        // Shutdown the exporter
        const result = self.exporter.shutdown(timeout_ms);
        return if (result == .success) .success else .failure;
    }
};

/// Create a simple processor
pub fn createSimpleProcessor(
    allocator: std.mem.Allocator,
    exporter: *LogExporter,
) !*SimpleLogProcessor {
    const processor = try allocator.create(SimpleLogProcessor);
    processor.* = SimpleLogProcessor.init(allocator, exporter);
    return processor;
}

test "SimpleLogProcessor basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a test exporter
    const TestExporter = struct {
        var export_count: usize = 0;
        var last_record_body: []const u8 = "";
        var flushed: bool = false;
        var shutdown: bool = false;

        fn exportRecords(impl: *anyopaque, records: []const LogRecord, resource: *const Resource) @import("exporter.zig").ExportResult {
            _ = impl;
            _ = resource;
            export_count += 1;
            if (records.len > 0) {
                if (records[0].body) |body| {
                    if (body == .string) {
                        last_record_body = body.string;
                    }
                }
            }
            return .success;
        }

        fn flush(impl: *anyopaque, timeout: ?u64) @import("exporter.zig").ExportResult {
            _ = impl;
            _ = timeout;
            flushed = true;
            return .success;
        }

        fn shutdownFn(impl: *anyopaque, timeout: ?u64) @import("exporter.zig").ExportResult {
            _ = impl;
            _ = timeout;
            shutdown = true;
            return .success;
        }

        fn deinit(impl: *anyopaque) void {
            _ = impl;
        }
    };

    TestExporter.export_count = 0;
    TestExporter.last_record_body = "";
    TestExporter.flushed = false;
    TestExporter.shutdown = false;

    var custom_exporter = @import("exporter.zig").createCustomExporter(
        undefined,
        TestExporter.exportRecords,
        TestExporter.flush,
        TestExporter.shutdownFn,
        TestExporter.deinit,
    );
    var exporter = LogExporter{ .custom = &custom_exporter };

    var processor = try createSimpleProcessor(allocator, &exporter);
    defer {
        processor.deinit();
        allocator.destroy(processor);
    }

    const ctx = Context.empty(testing.allocator);
    const test_resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer test_resource.deinitOwned(allocator);

    // Test immediate export
    const record1 = LogRecord{
        .severity_number = .info,
        .body = otel_api.AttributeValue{ .string = "test message" },
    };
    processor.onEmit(record1, ctx, &test_resource);

    try testing.expectEqual(@as(usize, 1), TestExporter.export_count);
    try testing.expectEqualStrings("test message", TestExporter.last_record_body);

    // Test another record
    const record2 = LogRecord{
        .severity_number = .@"error",
        .body = otel_api.AttributeValue{ .string = "Test log message" },
    };
    processor.onEmit(record2, ctx, &test_resource);

    try testing.expectEqual(@as(usize, 2), TestExporter.export_count);
    try testing.expectEqualStrings("Test log message", TestExporter.last_record_body);

    // Test force flush
    const flush_result = processor.forceFlush(5000);
    try testing.expectEqual(ProcessorResult.success, flush_result);
    try testing.expect(TestExporter.flushed);

    // Test shutdown
    const shutdown_result = processor.shutdown(5000);
    try testing.expectEqual(ProcessorResult.success, shutdown_result);
    try testing.expect(TestExporter.shutdown);

    // Test that emission after shutdown is ignored
    const old_count = TestExporter.export_count;
    processor.onEmit(record1, ctx, &test_resource);
    try testing.expectEqual(old_count, TestExporter.export_count);
}

test "SimpleLogProcessor concurrent access" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestExporter = struct {
        var export_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

        fn exportRecords(impl: *anyopaque, records: []const LogRecord, resource: *const Resource) @import("exporter.zig").ExportResult {
            _ = impl;
            _ = records;
            _ = resource;
            _ = export_count.fetchAdd(1, .monotonic);
            return .success;
        }

        fn flush(impl: *anyopaque, timeout: ?u64) @import("exporter.zig").ExportResult {
            _ = impl;
            _ = timeout;
            return .success;
        }

        fn shutdown(impl: *anyopaque, timeout: ?u64) @import("exporter.zig").ExportResult {
            _ = impl;
            _ = timeout;
            return .success;
        }

        fn deinit(impl: *anyopaque) void {
            _ = impl;
        }
    };

    TestExporter.export_count.store(0, .monotonic);

    var custom_exporter = @import("exporter.zig").createCustomExporter(
        undefined,
        TestExporter.exportRecords,
        TestExporter.flush,
        TestExporter.shutdown,
        TestExporter.deinit,
    );
    var exporter = LogExporter{ .custom = &custom_exporter };

    var processor = try createSimpleProcessor(allocator, &exporter);
    defer {
        processor.deinit();
        allocator.destroy(processor);
    }

    const ctx = Context.empty(testing.allocator);
    const test_resource = try @import("../resource/resource.zig").getDefaultResource(allocator);
    defer test_resource.deinitOwned(allocator);

    // Spawn multiple threads to emit records
    const thread_count = 4;
    const records_per_thread = 25;
    var threads: [thread_count]std.Thread = undefined;

    const ThreadContext = struct {
        processor: *SimpleLogProcessor,
        thread_id: usize,
        ctx: Context,
        resource: *const Resource,
    };

    const threadFn = struct {
        fn run(thread_ctx: ThreadContext) void {
            const record = LogRecord{
                .severity_number = .info,
                .body = otel_api.AttributeValue{ .string = "concurrent test" },
            };

            for (0..records_per_thread) |_| {
                thread_ctx.processor.onEmit(record, thread_ctx.ctx, thread_ctx.resource);
            }
        }
    }.run;

    // Start threads
    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, threadFn, .{
            ThreadContext{
                .processor = processor,
                .thread_id = i,
                .ctx = ctx,
                .resource = &test_resource,
            },
        });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Verify all records were exported
    const total_expected = thread_count * records_per_thread;
    try testing.expectEqual(total_expected, TestExporter.export_count.load(.monotonic));
}