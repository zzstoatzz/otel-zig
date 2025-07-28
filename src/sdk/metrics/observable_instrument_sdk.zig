//! OpenTelemetry Observable Instrument SDK Implementation
//!
//! This module provides the concrete SDK implementation for observable/async instruments.
//! It includes callback management, metric collection, and performance monitoring.

const std = @import("std");
const api = @import("otel-api");
const metrics_data = @import("data.zig");

// API imports
const ObservableResult = api.metrics.ObservableResult;
const TypeErasedCallback = api.metrics.TypeErasedCallback;
const CallbackHandle = api.metrics.CallbackHandle;
const AsyncInstrumentBridge = api.metrics.AsyncInstrumentBridge;
const AttributeKeyValue = api.common.AttributeKeyValue;

// Error handling imports
const reportCallbackError = api.common.reportCallbackError;
const reportCallbackErrorWithSource = api.common.reportCallbackErrorWithSource;

// SDK imports
const AsyncInstrumentConfig = @import("async_instrument_config.zig").AsyncInstrumentConfig;
const CallbackErrorPolicy = @import("async_instrument_config.zig").CallbackErrorPolicy;
const MetricData = metrics_data.MetricData;
const MetricDataPoint = metrics_data.MetricDataPoint;
const MetricType = metrics_data.MetricType;
const MetricValue = metrics_data.MetricValue;
const Resource = @import("../resource/resource.zig").Resource;

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

        reportCallbackError(.meter, "executeCallback", error_message, context);
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

/// SDK implementation of ObservableCounter
pub fn SdkObservableCounter(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Entry for a registered callback
        const CallbackEntry = struct {
            callback: TypeErasedCallback,
            id: u64,
            metrics: CallbackMetrics,
        };

        /// Instrument metadata
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,

        /// Callback management
        callbacks: std.ArrayList(CallbackEntry),
        next_callback_id: u64,

        /// Configuration and state
        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex,
        config: AsyncInstrumentConfig,
        instrument_metrics: CallbackMetrics,

        /// Initialize the observable counter
        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            config: AsyncInstrumentConfig,
        ) Self {
            return Self{
                .name = name,
                .description = description,
                .unit = unit,
                .callbacks = std.ArrayList(CallbackEntry).init(allocator),
                .next_callback_id = 1,
                .allocator = allocator,
                .mutex = std.Thread.Mutex{},
                .config = config,
                .instrument_metrics = CallbackMetrics{},
            };
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Clean up callback metrics
            for (self.callbacks.items) |*entry| {
                entry.metrics.deinit(self.allocator);
            }
            self.callbacks.deinit();
            self.instrument_metrics.deinit(self.allocator);
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
        pub fn registerCallback(self: *Self, callback: TypeErasedCallback) CallbackHandle {
            self.mutex.lock();
            defer self.mutex.unlock();

            const callback_id = self.next_callback_id;
            self.next_callback_id += 1;

            const entry = CallbackEntry{
                .callback = callback,
                .id = callback_id,
                .metrics = CallbackMetrics{},
            };

            self.callbacks.append(entry) catch {
                // Return noop handle on allocation failure
                return CallbackHandle.noop();
            };

            return CallbackHandle.init(self, unregisterCallback, callback_id);
        }

        /// Unregister a callback (internal method)
        fn unregisterCallback(instrument_ptr: *anyopaque, callback_id: u64) void {
            const self: *Self = @ptrCast(@alignCast(instrument_ptr));

            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.callbacks.items, 0..) |entry, i| {
                if (entry.id == callback_id) {
                    var removed_entry = self.callbacks.swapRemove(i);
                    removed_entry.metrics.deinit(self.allocator);
                    break;
                }
            }
        }

        /// Collect measurements from all callbacks
        pub fn collect(self: *Self, allocator: std.mem.Allocator) ![]MetricDataPoint {
            self.mutex.lock();
            defer self.mutex.unlock();

            var data_points = std.ArrayList(MetricDataPoint).init(allocator);
            defer data_points.deinit();

            const collection_start = std.time.nanoTimestamp();

            for (self.callbacks.items) |*entry| {
                const callback_start = std.time.nanoTimestamp();

                // Execute callback and collect measurements
                const measurements = self.executeCallback(allocator, entry) catch |err| {
                    const error_message = switch (err) {
                        error.OutOfMemory => "Out of memory during callback execution",
                    };

                    if (self.config.track_callback_metrics) {
                        entry.metrics.recordError(self.allocator, error_message, entry.id, self.name);
                    }

                    switch (self.config.error_policy) {
                        .fail_fast => return err,
                        .log_continue => {
                            continue;
                        },
                        .silent_ignore => continue,
                    }
                };
                defer allocator.free(measurements);

                const callback_end = std.time.nanoTimestamp();
                const execution_time = @as(u64, @intCast(callback_end - callback_start));

                if (self.config.track_callback_metrics) {
                    entry.metrics.recordExecution(execution_time);
                }

                // Convert measurements to data points
                for (measurements) |measurement| {
                    const data_point = MetricDataPoint{
                        .value = switch (T) {
                            i64 => MetricValue{ .i64_sum = measurement.value },
                            f64 => MetricValue{ .f64_sum = measurement.value },
                            else => unreachable,
                        },
                        .attributes = measurement.attributes,
                        .timestamp_ns = @intCast(measurement.timestamp orelse collection_start),
                        .start_timestamp_ns = null,
                    };
                    try data_points.append(data_point);
                }

                // Warn if no measurements were produced
                if (self.config.warn_on_no_measurements and measurements.len == 0) {
                    // Warning already reported via reportCallbackError
                }
            }

            const collection_end = std.time.nanoTimestamp();
            const total_execution_time = @as(u64, @intCast(collection_end - collection_start));

            if (self.config.track_callback_metrics) {
                self.instrument_metrics.recordExecution(total_execution_time);
            }

            return data_points.toOwnedSlice();
        }

        /// Execute a single callback with proper error handling and timing
        fn executeCallback(self: *Self, allocator: std.mem.Allocator, entry: *CallbackEntry) ![]ObservableResult(T).Measurement {
            const start_time = if (self.config.track_callback_metrics) std.time.nanoTimestamp() else 0;

            var result = ObservableResult(T).init(allocator, null);
            defer result.deinit();

            // Execute the callback - callbacks are void functions, so we detect errors by observing behavior
            entry.callback.callback_fn(@ptrCast(&result), entry.callback.state);

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
                    reportCallbackError(.meter, "executeCallback", warn_msg, self.name);
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
                reportCallbackError(.meter, "executeCallback", warn_msg, self.name);
            }

            return result.measurements.toOwnedSlice();
        }

        /// Create MetricData from collected measurements
        pub fn createMetricData(self: *Self, allocator: std.mem.Allocator, scope: api.common.InstrumentationScope, resource: Resource) !MetricData {
            const data_points = try self.collect(allocator);

            return MetricData{
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
        pub fn exportCallbackMetrics(self: *Self, allocator: std.mem.Allocator) ![]MetricData {
            if (!self.config.track_callback_metrics) {
                return &[_]MetricData{};
            }

            var metrics = std.ArrayList(MetricData).init(allocator);

            // Overall instrument metrics
            const instrument_metrics = self.getInstrumentMetrics();

            // Execution count metric
            if (instrument_metrics.total_executions > 0) {
                const exec_count_points = try allocator.alloc(MetricDataPoint, 1);
                exec_count_points[0] = MetricDataPoint{
                    .value = .{ .i64_sum = @intCast(instrument_metrics.total_executions) },
                    .attributes = &[_]AttributeKeyValue{
                        .{ .key = "instrument", .value = .{ .string = self.name } },
                    },
                    .timestamp_ns = @intCast(std.time.nanoTimestamp()),
                    .start_timestamp_ns = null,
                };

                try metrics.append(MetricData{
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

/// SDK implementation of ObservableGauge (identical to ObservableCounter)
pub fn SdkObservableGauge(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Entry for a registered callback
        const CallbackEntry = struct {
            callback: TypeErasedCallback,
            id: u64,
            metrics: CallbackMetrics,
        };

        /// Instrument metadata
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,

        /// Callback management
        callbacks: std.ArrayList(CallbackEntry),
        next_callback_id: u64,

        /// Configuration and state
        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex,
        config: AsyncInstrumentConfig,
        instrument_metrics: CallbackMetrics,

        /// Initialize the observable gauge
        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            config: AsyncInstrumentConfig,
        ) Self {
            return Self{
                .name = name,
                .description = description,
                .unit = unit,
                .callbacks = std.ArrayList(CallbackEntry).init(allocator),
                .next_callback_id = 1,
                .allocator = allocator,
                .mutex = std.Thread.Mutex{},
                .config = config,
                .instrument_metrics = CallbackMetrics{},
            };
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Clean up callback metrics
            for (self.callbacks.items) |*entry| {
                entry.metrics.deinit(self.allocator);
            }
            self.callbacks.deinit();
            self.instrument_metrics.deinit(self.allocator);
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
        pub fn registerCallback(self: *Self, callback: TypeErasedCallback) CallbackHandle {
            self.mutex.lock();
            defer self.mutex.unlock();

            const callback_id = self.next_callback_id;
            self.next_callback_id += 1;

            const entry = CallbackEntry{
                .callback = callback,
                .id = callback_id,
                .metrics = CallbackMetrics{},
            };

            self.callbacks.append(entry) catch {
                // Return noop handle on allocation failure
                return CallbackHandle.noop();
            };

            return CallbackHandle.init(self, unregisterCallback, callback_id);
        }

        /// Unregister a callback (internal method)
        fn unregisterCallback(instrument_ptr: *anyopaque, callback_id: u64) void {
            const self: *Self = @ptrCast(@alignCast(instrument_ptr));

            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.callbacks.items, 0..) |entry, i| {
                if (entry.id == callback_id) {
                    var removed_entry = self.callbacks.swapRemove(i);
                    removed_entry.metrics.deinit(self.allocator);
                    break;
                }
            }
        }

        /// Collect measurements from all callbacks
        pub fn collect(self: *Self, allocator: std.mem.Allocator) ![]MetricDataPoint {
            self.mutex.lock();
            defer self.mutex.unlock();

            var data_points = std.ArrayList(MetricDataPoint).init(allocator);
            defer data_points.deinit();

            const collection_start = std.time.nanoTimestamp();

            for (self.callbacks.items) |*entry| {
                const callback_start = std.time.nanoTimestamp();

                // Execute callback and collect measurements
                const measurements = self.executeCallback(allocator, entry) catch |err| {
                    const error_message = switch (err) {
                        error.OutOfMemory => "Out of memory during callback execution",
                    };

                    if (self.config.track_callback_metrics) {
                        entry.metrics.recordError(self.allocator, error_message, entry.id, self.name);
                    }

                    switch (self.config.error_policy) {
                        .fail_fast => return err,
                        .log_continue => {
                            continue;
                        },
                        .silent_ignore => continue,
                    }
                };
                defer allocator.free(measurements);

                const callback_end = std.time.nanoTimestamp();
                const execution_time = @as(u64, @intCast(callback_end - callback_start));

                if (self.config.track_callback_metrics) {
                    entry.metrics.recordExecution(execution_time);
                }

                // Convert measurements to data points (gauges use current timestamp, no start timestamp)
                for (measurements) |measurement| {
                    const data_point = MetricDataPoint{
                        .value = switch (T) {
                            i64 => MetricValue{ .i64_gauge = measurement.value },
                            f64 => MetricValue{ .f64_gauge = measurement.value },
                            else => unreachable,
                        },
                        .attributes = measurement.attributes,
                        .timestamp_ns = @intCast(measurement.timestamp orelse collection_start),
                        .start_timestamp_ns = null, // Gauges don't have start timestamps
                    };
                    try data_points.append(data_point);
                }

                // Warn if no measurements were produced
                if (self.config.warn_on_no_measurements and measurements.len == 0) {
                    // Warning already reported via reportCallbackError
                }
            }

            const collection_end = std.time.nanoTimestamp();
            const total_execution_time = @as(u64, @intCast(collection_end - collection_start));

            if (self.config.track_callback_metrics) {
                self.instrument_metrics.recordExecution(total_execution_time);
            }

            return data_points.toOwnedSlice();
        }

        /// Execute a single callback with proper error handling and timing
        fn executeCallback(self: *Self, allocator: std.mem.Allocator, entry: *CallbackEntry) ![]ObservableResult(T).Measurement {
            const start_time = if (self.config.track_callback_metrics) std.time.nanoTimestamp() else 0;

            var result = ObservableResult(T).init(allocator, null);
            defer result.deinit();

            // Execute the callback - callbacks are void functions, so we detect errors by observing behavior
            entry.callback.callback_fn(@ptrCast(&result), entry.callback.state);

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
                    reportCallbackError(.meter, "executeCallback", warn_msg, self.name);
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
                reportCallbackError(.meter, "executeCallback", warn_msg, self.name);
            }

            return result.measurements.toOwnedSlice();
        }

        /// Create MetricData from collected measurements
        pub fn createMetricData(self: *Self, allocator: std.mem.Allocator, scope: api.common.InstrumentationScope, resource: Resource) !MetricData {
            const data_points = try self.collect(allocator);

            return MetricData{
                .name = self.name,
                .description = self.description,
                .unit = self.unit,
                .type = .gauge,
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
        pub fn exportCallbackMetrics(self: *Self, allocator: std.mem.Allocator) ![]MetricData {
            if (!self.config.track_callback_metrics) {
                return &[_]MetricData{};
            }

            var metrics = std.ArrayList(MetricData).init(allocator);

            // Overall instrument metrics
            const instrument_metrics = self.getInstrumentMetrics();

            // Execution count metric
            if (instrument_metrics.total_executions > 0) {
                const exec_count_points = try allocator.alloc(MetricDataPoint, 1);
                exec_count_points[0] = MetricDataPoint{
                    .value = .{ .i64_sum = @intCast(instrument_metrics.total_executions) },
                    .attributes = &[_]AttributeKeyValue{
                        .{ .key = "instrument", .value = .{ .string = self.name } },
                    },
                    .timestamp_ns = @intCast(std.time.nanoTimestamp()),
                    .start_timestamp_ns = null,
                };

                try metrics.append(MetricData{
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

/// SDK implementation of ObservableUpDownCounter
pub fn SdkObservableUpDownCounter(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Entry for a registered callback
        const CallbackEntry = struct {
            callback: TypeErasedCallback,
            id: u64,
            metrics: CallbackMetrics,
        };

        /// Instrument metadata
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,

        /// Callback management
        callbacks: std.ArrayList(CallbackEntry),
        next_callback_id: u64,

        /// Configuration and state
        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex,
        config: AsyncInstrumentConfig,
        instrument_metrics: CallbackMetrics,

        /// Initialize the observable up-down counter
        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            config: AsyncInstrumentConfig,
        ) Self {
            return Self{
                .name = name,
                .description = description,
                .unit = unit,
                .callbacks = std.ArrayList(CallbackEntry).init(allocator),
                .next_callback_id = 1,
                .allocator = allocator,
                .mutex = std.Thread.Mutex{},
                .config = config,
                .instrument_metrics = CallbackMetrics{},
            };
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Clean up callback metrics
            for (self.callbacks.items) |*entry| {
                entry.metrics.deinit(self.allocator);
            }
            self.callbacks.deinit();
            self.instrument_metrics.deinit(self.allocator);
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
        pub fn registerCallback(self: *Self, callback: TypeErasedCallback) CallbackHandle {
            self.mutex.lock();
            defer self.mutex.unlock();

            const callback_id = self.next_callback_id;
            self.next_callback_id += 1;

            const entry = CallbackEntry{
                .callback = callback,
                .id = callback_id,
                .metrics = CallbackMetrics{},
            };

            self.callbacks.append(entry) catch {
                // Return noop handle on allocation failure
                return CallbackHandle.noop();
            };

            return CallbackHandle.init(self, unregisterCallback, callback_id);
        }

        /// Unregister a callback (internal method)
        fn unregisterCallback(instrument_ptr: *anyopaque, callback_id: u64) void {
            const self: *Self = @ptrCast(@alignCast(instrument_ptr));

            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.callbacks.items, 0..) |entry, i| {
                if (entry.id == callback_id) {
                    var removed_entry = self.callbacks.swapRemove(i);
                    removed_entry.metrics.deinit(self.allocator);
                    break;
                }
            }
        }

        /// Collect measurements from all callbacks
        pub fn collect(self: *Self, allocator: std.mem.Allocator) ![]MetricDataPoint {
            self.mutex.lock();
            defer self.mutex.unlock();

            var data_points = std.ArrayList(MetricDataPoint).init(allocator);
            defer data_points.deinit();

            const collection_start = std.time.nanoTimestamp();

            for (self.callbacks.items) |*entry| {
                const callback_start = std.time.nanoTimestamp();

                // Execute callback and collect measurements
                const measurements = self.executeCallback(allocator, entry) catch |err| {
                    const error_message = switch (err) {
                        error.OutOfMemory => "Out of memory during callback execution",
                    };

                    if (self.config.track_callback_metrics) {
                        entry.metrics.recordError(self.allocator, error_message, entry.id, self.name);
                    }

                    switch (self.config.error_policy) {
                        .fail_fast => return err,
                        .log_continue => {
                            continue;
                        },
                        .silent_ignore => continue,
                    }
                };
                defer allocator.free(measurements);

                const callback_end = std.time.nanoTimestamp();
                const execution_time = @as(u64, @intCast(callback_end - callback_start));

                if (self.config.track_callback_metrics) {
                    entry.metrics.recordExecution(execution_time);
                }

                // Convert measurements to data points (up-down counters use sum values)
                for (measurements) |measurement| {
                    const data_point = MetricDataPoint{
                        .value = switch (T) {
                            i64 => MetricValue{ .i64_sum = measurement.value },
                            f64 => MetricValue{ .f64_sum = measurement.value },
                            else => unreachable,
                        },
                        .attributes = measurement.attributes,
                        .timestamp_ns = @intCast(measurement.timestamp orelse collection_start),
                        .start_timestamp_ns = null, // Up-down counters don't have start timestamps
                    };
                    try data_points.append(data_point);
                }

                // Warn if no measurements were produced
                if (self.config.warn_on_no_measurements and measurements.len == 0) {
                    // Warning already reported via reportCallbackError
                }
            }

            const collection_end = std.time.nanoTimestamp();
            const total_execution_time = @as(u64, @intCast(collection_end - collection_start));

            if (self.config.track_callback_metrics) {
                self.instrument_metrics.recordExecution(total_execution_time);
            }

            return data_points.toOwnedSlice();
        }

        /// Execute a single callback with proper error handling and timing
        fn executeCallback(self: *Self, allocator: std.mem.Allocator, entry: *CallbackEntry) ![]ObservableResult(T).Measurement {
            const start_time = if (self.config.track_callback_metrics) std.time.nanoTimestamp() else 0;

            var result = ObservableResult(T).init(allocator, null);
            defer result.deinit();

            // Execute the callback - callbacks are void functions, so we detect errors by observing behavior
            entry.callback.callback_fn(@ptrCast(&result), entry.callback.state);

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
                    reportCallbackError(.meter, "executeCallback", warn_msg, self.name);
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
                reportCallbackError(.meter, "executeCallback", warn_msg, self.name);
            }

            return result.measurements.toOwnedSlice();
        }

        /// Create MetricData from collected measurements
        pub fn createMetricData(self: *Self, allocator: std.mem.Allocator, scope: api.common.InstrumentationScope, resource: Resource) !MetricData {
            const data_points = try self.collect(allocator);

            return MetricData{
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
        pub fn exportCallbackMetrics(self: *Self, allocator: std.mem.Allocator) ![]MetricData {
            if (!self.config.track_callback_metrics) {
                return &[_]MetricData{};
            }

            var metrics = std.ArrayList(MetricData).init(allocator);

            // Overall instrument metrics
            const instrument_metrics = self.getInstrumentMetrics();

            // Execution count metric
            if (instrument_metrics.total_executions > 0) {
                const exec_count_points = try allocator.alloc(MetricDataPoint, 1);
                exec_count_points[0] = MetricDataPoint{
                    .value = .{ .i64_sum = @intCast(instrument_metrics.total_executions) },
                    .attributes = &[_]AttributeKeyValue{
                        .{ .key = "instrument", .value = .{ .string = self.name } },
                    },
                    .timestamp_ns = @intCast(std.time.nanoTimestamp()),
                    .start_timestamp_ns = null,
                };

                try metrics.append(MetricData{
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

test "observable instrument semantic differences" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = AsyncInstrumentConfig{
        .error_policy = .log_continue,
        .max_measurements_per_callback = null,
        .warn_on_no_measurements = false,
        .track_callback_metrics = false,
    };

    const scope = api.common.InstrumentationScope{
        .name = "test",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &[_]api.common.AttributeKeyValue{},
    };

    const resource = @import("../resource/resource.zig").Resource{
        .attributes = &[_]api.common.AttributeKeyValue{},
        .schema_url = null,
    };

    // Test Counter (sum type)
    var counter = SdkObservableCounter(i64).init(allocator, "test.counter", "A test counter", "1", config);
    defer counter.deinit();

    const counter_data = try counter.createMetricData(allocator, scope, resource);
    defer allocator.free(counter_data.data_points);

    try std.testing.expectEqual(MetricType.sum, counter_data.type);
    try std.testing.expectEqualStrings("test.counter", counter_data.name);

    // Test Gauge (gauge type)
    var gauge = SdkObservableGauge(f64).init(allocator, "test.gauge", "A test gauge", "°C", config);
    defer gauge.deinit();

    const gauge_data = try gauge.createMetricData(allocator, scope, resource);
    defer allocator.free(gauge_data.data_points);

    try std.testing.expectEqual(MetricType.gauge, gauge_data.type);
    try std.testing.expectEqualStrings("test.gauge", gauge_data.name);

    // Test UpDownCounter (sum type)
    var updown = SdkObservableUpDownCounter(i64).init(allocator, "test.updown", "A test up-down counter", "bytes", config);
    defer updown.deinit();

    const updown_data = try updown.createMetricData(allocator, scope, resource);
    defer allocator.free(updown_data.data_points);

    try std.testing.expectEqual(MetricType.sum, updown_data.type);
    try std.testing.expectEqualStrings("test.updown", updown_data.name);
}

test "observable instrument metric value types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = AsyncInstrumentConfig{
        .error_policy = .log_continue,
        .max_measurements_per_callback = null,
        .warn_on_no_measurements = false,
        .track_callback_metrics = false,
    };

    // Test that Counter uses i64_sum/f64_sum
    var counter_i64 = SdkObservableCounter(i64).init(allocator, "test.counter.i64", null, null, config);
    defer counter_i64.deinit();

    const TestCallback = struct {
        fn callback(result_ptr: *anyopaque, state: ?*anyopaque) void {
            _ = state;
            const result: *ObservableResult(i64) = @ptrCast(@alignCast(result_ptr));
            result.observe(42, &[_]AttributeKeyValue{}, null) catch {};
        }
    };

    const test_callback = TypeErasedCallback{
        .callback_fn = TestCallback.callback,
        .state = null,
        .has_state = false,
    };

    _ = counter_i64.registerCallback(test_callback);
    const counter_points = try counter_i64.collect(allocator);
    defer allocator.free(counter_points);

    try std.testing.expect(counter_points.len == 1);
    try std.testing.expect(counter_points[0].value == .i64_sum);
    try std.testing.expectEqual(@as(i64, 42), counter_points[0].value.i64_sum);

    // Test that Gauge uses i64_gauge/f64_gauge
    var gauge_f64 = SdkObservableGauge(f64).init(allocator, "test.gauge.f64", null, null, config);
    defer gauge_f64.deinit();

    const TestCallbackF64 = struct {
        fn gaugeCallback(result_ptr: *anyopaque, state: ?*anyopaque) void {
            _ = state;
            const result: *ObservableResult(f64) = @ptrCast(@alignCast(result_ptr));
            result.observe(3.14, &[_]AttributeKeyValue{}, null) catch {};
        }
    };

    const callback_f64 = TypeErasedCallback{
        .callback_fn = TestCallbackF64.gaugeCallback,
        .state = null,
        .has_state = false,
    };

    _ = gauge_f64.registerCallback(callback_f64);
    const gauge_points = try gauge_f64.collect(allocator);
    defer allocator.free(gauge_points);

    try std.testing.expect(gauge_points.len == 1);
    try std.testing.expect(gauge_points[0].value == .f64_gauge);
    try std.testing.expectEqual(@as(f64, 3.14), gauge_points[0].value.f64_gauge);

    // Test that UpDownCounter uses i64_sum/f64_sum
    var updown_i64 = SdkObservableUpDownCounter(i64).init(allocator, "test.updown.i64", null, null, config);
    defer updown_i64.deinit();

    _ = updown_i64.registerCallback(test_callback);
    const updown_points = try updown_i64.collect(allocator);
    defer allocator.free(updown_points);

    try std.testing.expect(updown_points.len == 1);
    try std.testing.expect(updown_points[0].value == .i64_sum);
    try std.testing.expectEqual(@as(i64, 42), updown_points[0].value.i64_sum);
}

test "callback metrics basic functionality" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use mock error handler to capture errors instead of printing to stderr
    var mock_error_handler = api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    api.common.setMockErrorHandler(&mock_error_handler);
    defer api.common.clearMockErrorHandler();

    var metrics = CallbackMetrics{};
    defer metrics.deinit(allocator);

    // Test recording executions
    metrics.recordExecution(1000);
    metrics.recordExecution(2000);
    metrics.recordExecution(500);

    try testing.expectEqual(@as(u64, 3), metrics.total_executions);
    try testing.expectEqual(@as(u64, 3500), metrics.total_execution_time_ns);
    try testing.expectEqual(@as(u64, 2000), metrics.max_execution_time_ns);
    try testing.expectEqual(@as(u64, 500), metrics.min_execution_time_ns);
    try testing.expectEqual(@as(u64, 1166), metrics.getAverageExecutionTimeNs());

    // Test recording errors
    metrics.recordError(allocator, "Test error", 123, "test.instrument");
    try testing.expectEqual(@as(u64, 1), metrics.error_count);
    try testing.expect(metrics.last_error != null);
    try testing.expectEqualStrings("Test error", metrics.last_error.?);

    // Verify error was captured by mock handler
    try testing.expectEqual(@as(usize, 1), mock_error_handler.errorCount());
    const captured_error = mock_error_handler.getError(0).?;
    try testing.expectEqual(api.common.Component.meter, captured_error.component);
    try testing.expectEqual(api.common.ErrorType.callback, captured_error.error_type);
    try testing.expectEqualStrings("Test error", captured_error.message);
}

test "observable counter basic functionality" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test_counter",
        "Test counter",
        "1",
        AsyncInstrumentConfig.default(),
    );
    defer counter.deinit();

    // Test basic properties
    try testing.expectEqualStrings("test_counter", counter.getName());
    try testing.expect(counter.enabled());

    // Test callback registration
    const TestCallback = struct {
        fn callback(result: *ObservableResult(i64), state: *i32) void {
            const value = state.*;
            result.observeValue(value) catch {};
        }
    };

    var state: i32 = 42;
    const callback = TypeErasedCallback{
        .callback_fn = struct {
            fn call(result_ptr: *anyopaque, state_ptr: ?*anyopaque) void {
                const result: *ObservableResult(i64) = @ptrCast(@alignCast(result_ptr));
                const typed_state: *i32 = @ptrCast(@alignCast(state_ptr.?));
                TestCallback.callback(result, typed_state);
            }
        }.call,
        .state = &state,
        .has_state = true,
    };
    const handle = counter.registerCallback(callback);

    // Test collection
    const data_points = try counter.collect(allocator);
    defer allocator.free(data_points);

    try testing.expectEqual(@as(usize, 1), data_points.len);
    try testing.expectEqual(@as(i64, 42), data_points[0].value.i64_sum);

    // Test unregistration
    handle.unregister();

    const empty_data_points = try counter.collect(allocator);
    defer allocator.free(empty_data_points);
    try testing.expectEqual(@as(usize, 0), empty_data_points.len);
}
