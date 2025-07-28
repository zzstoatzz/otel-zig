//! Batch Log Record Processor Example
//!
//! This example demonstrates how to use the BatchLogRecordProcessor to collect
//! and export log records in batches at regular intervals, which is more
//! efficient than exporting each record individually.
//!
//! Run with: zig build example-logs-batch

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting Batch Log Record Processor Example", .{});

    // Set up global logger provider with batch processor
    const log_provider = try otel_sdk.logs.setupGlobalProvider(
        allocator,
        .{otel_sdk.logs.BatchLogRecordProcessor.PipelineStep.init(.{
            .export_interval_ms = 2000, // Export every 2 seconds
            .max_queue_size = 100, // Queue up to 100 records before dropping
        }).flowTo(otel_exporters.console.StreamLogExporter(std.fs.File.Writer).PipelineStep.init(.{}))},
    );
    defer {
        log_provider.deinit();
        log_provider.destroy();
    }

    // Get a logger from the global provider
    const scope = try otel_api.InstrumentationScope.initSimple("batch.example", "1.0.0");
    var logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);

    std.log.info("Emitting log records - they will be batched and exported every 2 seconds", .{});

    // Create some attributes for richer logging
    const attributes = [_]otel_api.AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "batch-example" } },
        .{ .key = "batch.size", .value = .{ .int = 5 } },
    };

    const ctx = otel_api.Context.init(allocator);

    // Emit multiple log records quickly - they should be batched
    for (0..10) |i| {
        const message = try std.fmt.allocPrint(allocator, "Batch log message #{d}", .{i + 1});
        defer allocator.free(message);

        logger.emitLogRecord(
            ctx,
            if (i % 3 == 0) .warn else .info,
            .{ .string = message },
            if (i < 5) &attributes else null,
            null, // timestamp (will be auto-generated)
            null, // observed_timestamp (will be auto-generated)
            if (i % 2 == 0) "batch.event" else null,
            if (i % 3 == 0) "WARN" else "INFO",
            null, // trace_id
            null, // span_id
            null, // flags
        );

        // Small delay to show batching behavior
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    std.log.info("Finished emitting log records. Waiting for batch export...", .{});

    // Wait a bit to see the batch export in action
    std.time.sleep(3 * std.time.ns_per_s);

    // Emit a few more records to demonstrate multiple batches
    std.log.info("Emitting more log records for second batch...", .{});

    for (10..15) |i| {
        const message = try std.fmt.allocPrint(allocator, "Second batch message #{d}", .{i + 1});
        defer allocator.free(message);

        logger.emitLogRecord(
            ctx,
            .@"error",
            .{ .string = message },
            null,
            null,
            null,
            "error.event",
            "ERROR",
            null,
            null,
            null,
        );

        std.time.sleep(50 * std.time.ns_per_ms);
    }

    std.log.info("Force flushing remaining records...", .{});

    // Force flush any remaining buffered records
    const flush_result = log_provider.forceFlush(5000);
    switch (flush_result) {
        .success => std.log.info("Successfully flushed all log records", .{}),
        .failure => std.log.warn("Failed to flush some log records", .{}),
        .timeout => std.log.warn("Flush operation timed out", .{}),
    }

    std.log.info("Batch Log Record Processor Example completed", .{});
}
