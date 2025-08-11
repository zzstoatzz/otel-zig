//! OpenTelemetry Observable Instrument SDK Implementation
//!
//! This module provides the concrete SDK implementation for observable/async instruments.
//! It includes callback management, metric collection, and performance monitoring.

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const AsyncInstrumentConfig = @import("async_instrument_config.zig").AsyncInstrumentConfig;
    const InstrumentType = @import("metadata.zig").InstrumentType;
    const Meter = @import("meter.zig").Meter;
    const MetricData = @import("data.zig").MetricData;
    const MetricDataPoint = @import("data.zig").MetricDataPoint;
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const MetricValue = @import("data.zig").MetricValue;
    const Reader = @import("reader.zig").Reader;
    const Resource = @import("../resource/resource.zig").Resource;
    const ViewApplication = @import("view.zig").ViewApplication;
};

/// Metrics for tracking callback performance
pub const CallbackMetrics = struct {
    /// Total number of callback executions
    total_executions: u64 = 0,
    /// Total execution time in nanoseconds
    total_execution_time_ns: u64 = 0,
    /// Maximum execution time in nanoseconds
    max_execution_time_ns: u64 = 0,
    /// Minimum execution time in nanoseconds
    min_execution_time_ns: u64 = std.math.maxInt(u64),
    /// Total number of callback errors
    error_count: u64 = 0,
    /// Last execution time in nanoseconds
    last_execution_time_ns: ?u64 = null,
    /// Last error message (owned by CallbackMetrics)
    last_error: ?[]u8 = null,

    /// Record a successful callback execution
    pub fn recordExecution(self: *CallbackMetrics, execution_time_ns: u64) void {
        self.total_executions += 1;
        self.total_execution_time_ns += execution_time_ns;
        self.max_execution_time_ns = @max(self.max_execution_time_ns, execution_time_ns);
        self.min_execution_time_ns = @min(self.min_execution_time_ns, execution_time_ns);
        self.last_execution_time_ns = execution_time_ns;
    }

    /// Record a callback error and report to error handler
    pub fn recordError(self: *CallbackMetrics, allocator: std.mem.Allocator, error_message: []const u8, callback_id: ?u64, instrument_name: ?[]const u8) void {
        self.error_count += 1;

        // Free previous error message if it exists
        if (self.last_error) |old_error| {
            allocator.free(old_error);
        }

        // Clone the error message
        self.last_error = allocator.dupe(u8, error_message) catch null;

        // Report to error handler with context
        var context_buffer: [256]u8 = undefined;
        const context = if (callback_id != null and instrument_name != null)
            std.fmt.bufPrint(&context_buffer, "callback_id={}, instrument={s}", .{ callback_id.?, instrument_name.? }) catch "callback_error"
        else if (callback_id != null)
            std.fmt.bufPrint(&context_buffer, "callback_id={}", .{callback_id.?}) catch "callback_error"
        else if (instrument_name != null)
            std.fmt.bufPrint(&context_buffer, "instrument={s}", .{instrument_name.?}) catch "callback_error"
        else
            "callback_error";

        api.common.reportCallbackError(.meter, "executeCallback", error_message, context);
    }

    /// Get average execution time in nanoseconds
    pub fn getAverageExecutionTimeNs(self: *const CallbackMetrics) u64 {
        if (self.total_executions == 0) return 0;
        return self.total_execution_time_ns / self.total_executions;
    }

    /// Clean up resources
    pub fn deinit(self: *CallbackMetrics, allocator: std.mem.Allocator) void {
        if (self.last_error) |error_msg| {
            allocator.free(error_msg);
            self.last_error = null;
        }
    }
};

/// Wrapper for the different Observable types.
///
/// The spec says that observables all behave the same way, as far as the
/// callback is concerned : the call back should return the current absolute
/// value, not a delta. The SDK has the responsibilty of creating the right
/// temporality. In our implementation that is delegated to the reader stored
/// aggregations, not to the instrument.
pub fn Observable(comptime T: type) type {
    comptime switch (T) {
        i64, f64 => {},
        else => @compileError("ObservableInstrument must be of type i64 or f64"),
    };

    return struct {
        const Self = @This();

        /// Entry for a registered callback
        const CallbackEntry = struct {
            callback: api.metrics.TypeErasedCallback(T),
            id: u64,
            metrics: CallbackMetrics,
        };

        /// Instrument metadata
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        instrument_type: sdk.InstrumentType,
        meter: *sdk.Meter,
        metadata_hash: u64,

        /// Callback management
        callbacks: std.ArrayList(CallbackEntry),
        next_callback_id: u64,

        /// Configuration and state
        mutex: std.Thread.Mutex,
        config: sdk.AsyncInstrumentConfig,
        instrument_metrics: CallbackMetrics,

        /// View support
        views: []sdk.ViewApplication,

        /// Initialize the observable counter
        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            instrument_type: sdk.InstrumentType,
            parent_meter: *sdk.Meter,
            config: sdk.AsyncInstrumentConfig,
        ) !Self {
            // Precompute the hash values that don't change per datapoint.
            const metadata_hash = sdk.MetricMetadata.computeHash(
                name,
                unit orelse "",
                instrument_type,
                &parent_meter.scope,
            );

            // Get the views that apply to this instrument.
            const view_applications = try parent_meter.provider.applyViews(
                name,
                instrument_type,
                unit orelse "",
                description,
                parent_meter.scope.name,
                parent_meter.scope.version,
                parent_meter.scope.schema_url,
                parent_meter.allocator,
            );

            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .instrument_type = instrument_type,
                .meter = parent_meter,
                .metadata_hash = metadata_hash,
                .callbacks = std.ArrayList(CallbackEntry).init(parent_meter.allocator),
                .next_callback_id = 1,
                .mutex = std.Thread.Mutex{},
                .config = config,
                .instrument_metrics = CallbackMetrics{},
                .views = view_applications,
            };
        }

        /// Clean up resources
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Clean up callback metrics
            for (self.callbacks.items) |*entry| {
                entry.metrics.deinit(allocator);
            }
            self.callbacks.deinit();
            self.instrument_metrics.deinit(allocator);
            allocator.free(self.views);
        }

        /// Get the name of this instrument
        pub fn getName(self: *const Self) []const u8 {
            return self.name;
        }

        /// Check if this instrument is enabled
        pub fn enabled(self: *const Self) bool {
            _ = self;
            return true; // SDK instruments are always enabled
        }

        /// Register a callback
        pub fn registerCallback(self: *Self, callback: api.metrics.TypeErasedCallback(T)) api.metrics.CallbackHandle {
            self.mutex.lock();
            defer self.mutex.unlock();

            const callback_id = self.next_callback_id;

            const entry = CallbackEntry{
                .callback = callback,
                .id = callback_id,
                .metrics = CallbackMetrics{},
            };

            self.callbacks.append(entry) catch {
                // Return noop handle on allocation failure
                return .noop;
            };

            self.next_callback_id += 1;
            return .init(self, unregisterCallback, callback_id);
        }

        /// Unregister a callback (internal method)
        fn unregisterCallback(instrument_ptr: *anyopaque, callback_id: u64) void {
            const self: *Self = @ptrCast(@alignCast(instrument_ptr));

            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.callbacks.items, 0..) |entry, i| {
                if (entry.id == callback_id) {
                    var removed_entry = self.callbacks.swapRemove(i);
                    removed_entry.metrics.deinit(self.meter.allocator);
                    break;
                }
            }
        }

        /// Trigger callbacks and record measurements.
        ///
        /// `allocator` is expected to be the readers allocator, to reduce copies.
        /// `points` is the readers export queue, to avoid copies.
        /// `reader` is the specific reader that triggered this observation.
        pub fn triggerObserve(self: *Self, allocator: std.mem.Allocator, reader: sdk.Reader) void {
            const collection_start = std.time.nanoTimestamp();

            var buffer: std.ArrayListUnmanaged(api.metrics.ObservableResult(T).Measurement) = .{};
            defer buffer.deinit(allocator);

            // lock for iteration over the callbacks.
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                for (self.callbacks.items) |*entry| {
                    const callback_start = std.time.nanoTimestamp();

                    // Execute callback and collect measurements
                    const measurements = self.executeCallback(allocator, entry) catch |err| {
                        const error_message = switch (err) {
                            error.OutOfMemory => "Out of memory during callback execution",
                        };

                        if (self.config.track_callback_metrics) {
                            entry.metrics.recordError(self.meter.allocator, error_message, entry.id, self.name);
                        }

                        switch (self.config.error_policy) {
                            .fail_fast => break,
                            .log_continue => {
                                api.common.reportError(.{
                                    .component = .meter,
                                    .context = null,
                                    .error_type = .internal,
                                    .message = error_message,
                                    .operation = "observable callback execution",
                                    .source_error = err,
                                });
                                continue;
                            },
                            .silent_ignore => continue,
                        }
                    };
                    defer allocator.free(measurements);

                    // buffer the measurements we did get.
                    if (measurements.len > 0) {
                        buffer.appendSlice(allocator, measurements) catch |err| {
                            switch (self.config.error_policy) {
                                .fail_fast => break,
                                .log_continue => {
                                    api.common.reportError(.{
                                        .component = .meter,
                                        .context = null,
                                        .error_type = .internal,
                                        .message = "Out of memory during callback aggregation.",
                                        .operation = "observable callback collection",
                                        .source_error = err,
                                    });
                                    continue;
                                },
                                .silent_ignore => continue,
                            }
                        };
                    }

                    const callback_end = std.time.nanoTimestamp();
                    const execution_time = @as(u64, @intCast(callback_end - callback_start));

                    if (self.config.track_callback_metrics) {
                        entry.metrics.recordExecution(execution_time);
                    }
                }
            }

            // Convert measurements to data points
            for (buffer.items) |measurement| {
                // Process each view application
                for (self.views) |view| {
                    // Skip drop aggregations
                    if (view.drops()) continue;

                    // Transform attributes according to view
                    const attrs = view.transformAttributes(measurement.attributes, allocator) catch |e| blk: {
                        api.common.reportErrorWithAllocator(.{
                            .component = .meter,
                            .context = null,
                            .error_type = .internal,
                            .message = "Unable to transform attributes with view",
                            .operation = "StandardCounter.addI64()",
                            .source_error = e,
                        }, allocator);
                        break :blk measurement.attributes; // On error, use original attributes
                    };

                    const metadata = sdk.MetricMetadata{
                        .name = view.getName(self.name),
                        .description = view.getDescription(self.description) orelse "",
                        .unit = self.unit orelse "", // Unit not transformable per spec
                        .instrument_type = self.instrument_type,
                        .instrumentation_scope = self.meter.scope,
                    };

                    reader.recordMeasurement(
                        switch (T) {
                            i64 => .{ .i64 = measurement.value },
                            f64 => .{ .f64 = measurement.value },
                            else => unreachable,
                        },
                        attrs,
                        metadata,
                        self.metadata_hash,
                    );
                }
            }

            const collection_end = std.time.nanoTimestamp();
            const total_execution_time = @as(u64, @intCast(collection_end - collection_start));

            if (self.config.track_callback_metrics) {
                self.instrument_metrics.recordExecution(total_execution_time);
            }
        }

        /// Execute a single callback with proper error handling and timing
        fn executeCallback(self: *Self, allocator: std.mem.Allocator, entry: *CallbackEntry) ![]api.metrics.ObservableResult(T).Measurement {
            const start_time = if (self.config.track_callback_metrics) std.time.nanoTimestamp() else 0;

            var result = api.metrics.ObservableResult(T).init(allocator);
            defer result.deinit();

            // Execute the callback - callbacks are void functions, so we detect errors by observing behavior
            switch (entry.callback) {
                .state => |cb| cb.callback_fn(allocator, &result, cb.state),
                .stateless => |cbFn| cbFn(allocator, &result),
            }

            // Record timing if enabled
            if (self.config.track_callback_metrics) {
                const end_time = std.time.nanoTimestamp();
                const execution_time = @as(u64, @intCast(end_time - start_time));
                entry.metrics.recordExecution(execution_time);
            }

            // Check measurement limit
            if (self.config.max_measurements_per_callback) |limit| {
                if (result.measurements.items.len > limit) {
                    const warn_msg = "Callback produced too many measurements";
                    // Warning already reported via reportCallbackError
                    if (self.config.track_callback_metrics) {
                        entry.metrics.recordError(allocator, warn_msg, entry.id, self.name);
                    }
                    api.common.reportCallbackError(.meter, "executeCallback", warn_msg, self.name);
                    // Truncate to limit
                    result.measurements.shrinkRetainingCapacity(limit);
                }
            }

            // Warn if no measurements were produced and policy requires it
            if (self.config.warn_on_no_measurements and result.measurements.items.len == 0) {
                const warn_msg = "Callback produced no measurements";
                // Warning already reported via reportCallbackError
                if (self.config.track_callback_metrics) {
                    entry.metrics.recordError(allocator, warn_msg, entry.id, self.name);
                }
                api.common.reportCallbackError(.meter, "executeCallback", warn_msg, self.name);
            }

            return result.measurements.toOwnedSlice();
        }

        /// Create MetricData from collected measurements
        pub fn createMetricData(self: *Self, allocator: std.mem.Allocator, scope: api.common.InstrumentationScope, resource: sdk.Resource) !sdk.MetricData {
            const data_points = try self.collect(allocator);

            return .{
                .name = self.name,
                .description = self.description,
                .unit = self.unit,
                .type = .sum,
                .data_points = data_points,
                .scope = scope,
                .resource = resource,
            };
        }

        /// Destroy the instrument
        pub fn destroy(self: *Self) void {
            self.allocator.destroy(self);
        }

        /// Get overall instrument metrics
        pub fn getInstrumentMetrics(self: *Self) CallbackMetrics {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.instrument_metrics;
        }

        /// Get metrics for a specific callback
        pub fn getCallbackMetrics(self: *Self, callback_id: u64) ?CallbackMetrics {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.callbacks.items) |entry| {
                if (entry.id == callback_id) {
                    return entry.metrics;
                }
            }
            return null;
        }

        /// Get metrics for all callbacks
        pub fn getAllCallbackMetrics(self: *Self, allocator: std.mem.Allocator) ![]CallbackMetrics {
            self.mutex.lock();
            defer self.mutex.unlock();

            var metrics = std.ArrayList(CallbackMetrics).init(allocator);
            for (self.callbacks.items) |entry| {
                try metrics.append(entry.metrics);
            }
            return metrics.toOwnedSlice();
        }

        /// Export callback performance metrics as MetricData
        pub fn exportCallbackMetrics(self: *Self, allocator: std.mem.Allocator) ![]sdk.MetricData {
            if (!self.config.track_callback_metrics) {
                return &[_]sdk.MetricData{};
            }

            var metrics = std.ArrayList(sdk.MetricData).init(allocator);

            // Overall instrument metrics
            const instrument_metrics = self.getInstrumentMetrics();

            // Execution count metric
            if (instrument_metrics.total_executions > 0) {
                const exec_count_points = try allocator.alloc(sdk.MetricDataPoint, 1);
                exec_count_points[0] = .{
                    .value = .{ .i64_sum = @intCast(instrument_metrics.total_executions) },
                    .attributes = &[_]api.AttributeKeyValue{
                        .{ .key = "instrument", .value = .{ .string = self.name } },
                    },
                    .timestamp_ns = @intCast(std.time.nanoTimestamp()),
                    .start_timestamp_ns = null,
                };

                try metrics.append(sdk.MetricData{
                    .name = "otel.async_instrument.callback.executions",
                    .description = "Total number of callback executions",
                    .unit = "1",
                    .type = .sum,
                    .data_points = exec_count_points,
                });
            }

            return metrics.toOwnedSlice();
        }
    };
}
