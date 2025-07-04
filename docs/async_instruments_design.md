# Simplified Async Instruments Design

## Overview

This design focuses on **single-instrument callbacks only**, avoiding the complexity of multi-instrument callbacks. Based on the architectural decisions:

- ✅ Single instrument can have multiple callbacks (1:N)
- ❌ Multi-instrument callbacks (skipped for now)
- ✅ Pass all measurements downstream (no SDK-level aggregation)
- ✅ State-first parameter with compile-time type safety
- ✅ Single-threaded collection for MVP
- ✅ Configurable error handling

## Core Architecture

### Callback Function Types

```zig
// Callback function signature with compile-time state typing
pub fn ObservableCallback(comptime StateType: type, comptime ValueType: type) type {
    return *const fn (state: StateType, result: *ObservableResult(ValueType)) void;
}

// No-state callback variant
pub fn ObservableCallbackNoState(comptime ValueType: type) type {
    return *const fn (result: *ObservableResult(ValueType)) void;
}

// Type-erased callback for internal storage
pub fn TypeErasedCallback(comptime ValueType: type) type {
    return struct {
        callback_fn: *const fn (state: ?*anyopaque, result: *ObservableResult(ValueType)) void,
        state: ?*anyopaque,
    };
}
```

### Observable Result Interface

```zig
// Result interface for capturing multiple observations with different attributes
pub fn ObservableResult(comptime T: type) type {
    return struct {
        const Self = @This();
        
        pub const Measurement = struct {
            value: T,
            attributes: []const AttributeKeyValue,
            timestamp: u64,
        };
        
        measurements: *std.ArrayList(Measurement),
        timestamp: u64,
        
        pub fn init(measurements: *std.ArrayList(Measurement)) Self {
            return .{ 
                .measurements = measurements,
                .timestamp = @intCast(std.time.nanoTimestamp()),
            };
        }
        
        // Main method - observe a value with attributes
        pub fn observe(self: *Self, value: T, attributes: []const AttributeKeyValue) void {
            self.measurements.append(.{
                .value = value,
                .attributes = attributes,
                .timestamp = self.timestamp,
            }) catch {
                std.log.err("Failed to record observation: out of memory", .{});
                return;
            };
        }
    };
}
```

### Observable Instruments API

```zig
// Observable Counter
pub fn ObservableCounter(comptime T: type) type {
    return union(enum) {
        noop: []const u8,
        bridge: AsyncInstrumentBridge,

        pub fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |name| name,
                .bridge => |bridge| bridge.getNameFn(bridge.instrument_ptr),
            };
        }

        pub fn enabled(self: *const @This()) bool {
            return switch (self.*) {
                .noop => false,
                .bridge => |bridge| bridge.enabledFn(bridge.instrument_ptr),
            };
        }

        // Register callback with state
        pub fn registerCallback(
            self: *@This(),
            comptime StateType: type,
            callback: ObservableCallback(StateType, T),
            state: StateType,
        ) !CallbackHandle {
            return switch (self.*) {
                .noop => CallbackHandle.noop(),
                .bridge => |bridge| bridge.registerCallbackFn(
                    bridge.instrument_ptr,
                    createTypeErasedCallback(StateType, T, callback),
                    @ptrCast(@constCast(&state)),
                ),
            };
        }

        // Register callback without state
        pub fn registerCallbackNoState(
            self: *@This(),
            callback: ObservableCallbackNoState(T),
        ) !CallbackHandle {
            return switch (self.*) {
                .noop => CallbackHandle.noop(),
                .bridge => |bridge| bridge.registerCallbackFn(
                    bridge.instrument_ptr,
                    createTypeErasedCallbackNoState(T, callback),
                    null,
                ),
            };
        }
    };
}

// Helper function to create type-erased callback with state
fn createTypeErasedCallback(
    comptime StateType: type,
    comptime ValueType: type,
    callback: ObservableCallback(StateType, ValueType),
) *const fn (state: ?*anyopaque, result: *ObservableResult(ValueType)) void {
    const Wrapper = struct {
        pub fn call(state: ?*anyopaque, result: *ObservableResult(ValueType)) void {
            const typed_state: StateType = @ptrCast(@alignCast(state.?));
            callback(typed_state, result);
        }
    };
    return Wrapper.call;
}

// Helper function to create type-erased callback without state
fn createTypeErasedCallbackNoState(
    comptime ValueType: type,
    callback: ObservableCallbackNoState(ValueType),
) *const fn (state: ?*anyopaque, result: *ObservableResult(ValueType)) void {
    const Wrapper = struct {
        pub fn call(state: ?*anyopaque, result: *ObservableResult(ValueType)) void {
            _ = state; // Unused
            callback(result);
        }
    };
    return Wrapper.call;
}

// Observable Gauge (similar structure)
pub fn ObservableGauge(comptime T: type) type {
    // Same implementation as ObservableCounter
    // Just different semantic meaning
    return ObservableCounter(T);
}

// Observable UpDownCounter (similar structure)
pub fn ObservableUpDownCounter(comptime T: type) type {
    // Same implementation as ObservableCounter
    // Just different semantic meaning
    return ObservableCounter(T);
}
```

### Callback Handle

```zig
// Handle for managing callback lifecycle
pub const CallbackHandle = struct {
    const Self = @This();
    
    instrument_ptr: ?*anyopaque,
    unregister_fn: ?*const fn (instrument_ptr: *anyopaque, callback_id: usize) void,
    callback_id: usize,
    
    pub fn noop() Self {
        return .{
            .instrument_ptr = null,
            .unregister_fn = null,
            .callback_id = 0,
        };
    }
    
    pub fn init(
        instrument_ptr: *anyopaque,
        unregister_fn: *const fn (instrument_ptr: *anyopaque, callback_id: usize) void,
        callback_id: usize,
    ) Self {
        return .{
            .instrument_ptr = instrument_ptr,
            .unregister_fn = unregister_fn,
            .callback_id = callback_id,
        };
    }
    
    pub fn unregister(self: *Self) void {
        if (self.unregister_fn) |unregister_fn| {
            if (self.instrument_ptr) |instrument_ptr| {
                unregister_fn(instrument_ptr, self.callback_id);
            }
        }
        self.* = Self.noop();
    }
};
```

### Meter API Extensions

```zig
// Add to Meter union
pub const Meter = union(enum) {
    noop: InstrumentationScope,
    bridge: MeterBridge,

    // ... existing methods ...

    pub fn createObservableCounter(
        self: *Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !ObservableCounter(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("ObservableCounters must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => |_| ObservableCounter(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createObservableCounterI64Fn(bridge.meter_ptr, name, description, unit),
                f64 => bridge.createObservableCounterF64Fn(bridge.meter_ptr, name, description, unit),
                else => unreachable,
            },
        };
    }

    pub fn createObservableGauge(
        self: *Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !ObservableGauge(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("ObservableGauges must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => |_| ObservableGauge(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createObservableGaugeI64Fn(bridge.meter_ptr, name, description, unit),
                f64 => bridge.createObservableGaugeF64Fn(bridge.meter_ptr, name, description, unit),
                else => unreachable,
            },
        };
    }

    pub fn createObservableUpDownCounter(
        self: *Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !ObservableUpDownCounter(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("ObservableUpDownCounters must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => |_| ObservableUpDownCounter(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createObservableUpDownCounterI64Fn(bridge.meter_ptr, name, description, unit),
                f64 => bridge.createObservableUpDownCounterF64Fn(bridge.meter_ptr, name, description, unit),
                else => unreachable,
            },
        };
    }
};
```

### Bridge Extensions

```zig
// Extended MeterBridge with async instrument creation
pub const MeterBridge = struct {
    // ... existing fields ...
    
    // Observable instrument creation functions
    createObservableCounterI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableCounter(i64),
    createObservableCounterF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableCounter(f64),
    createObservableGaugeI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableGauge(i64),
    createObservableGaugeF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableGauge(f64),
    createObservableUpDownCounterI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableUpDownCounter(i64),
    createObservableUpDownCounterF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableUpDownCounter(f64),

    // Extended init function includes new VTable entries
    pub fn init(ptr: anytype) MeterBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            // ... existing VTable functions ...
            
            pub fn createObservableCounterI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableCounter(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableCounterI64(self, name, description, unit);
            }
            pub fn createObservableCounterF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableCounter(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableCounterF64(self, name, description, unit);
            }
            pub fn createObservableGaugeI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableGauge(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableGaugeI64(self, name, description, unit);
            }
            pub fn createObservableGaugeF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableGauge(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableGaugeF64(self, name, description, unit);
            }
            pub fn createObservableUpDownCounterI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableUpDownCounter(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableUpDownCounterI64(self, name, description, unit);
            }
            pub fn createObservableUpDownCounterF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8) anyerror!ObservableUpDownCounter(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableUpDownCounterF64(self, name, description, unit);
            }
        };

        return .{
            // ... existing fields ...
            .createObservableCounterI64Fn = VTable.createObservableCounterI64,
            .createObservableCounterF64Fn = VTable.createObservableCounterF64,
            .createObservableGaugeI64Fn = VTable.createObservableGaugeI64,
            .createObservableGaugeF64Fn = VTable.createObservableGaugeF64,
            .createObservableUpDownCounterI64Fn = VTable.createObservableUpDownCounterI64,
            .createObservableUpDownCounterF64Fn = VTable.createObservableUpDownCounterF64,
        };
    }
};

// Bridge for async instruments
pub const AsyncInstrumentBridge = struct {
    instrument_ptr: *anyopaque,
    getNameFn: *const fn (instrument_ptr: *anyopaque) []const u8,
    enabledFn: *const fn (instrument_ptr: *anyopaque) bool,
    registerCallbackFn: *const fn (instrument_ptr: *anyopaque, callback_fn: anytype, state: ?*anyopaque) anyerror!CallbackHandle,

    pub fn init(ptr: anytype) AsyncInstrumentBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn getName(pointer: *anyopaque) []const u8 {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getName(self);
            }
            pub fn enabled(pointer: *anyopaque) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.enabled(self);
            }
            pub fn registerCallback(pointer: *anyopaque, callback_fn: anytype, state: ?*anyopaque) anyerror!CallbackHandle {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.registerCallback(self, callback_fn, state);
            }
        };

        return .{
            .instrument_ptr = ptr,
            .getNameFn = VTable.getName,
            .enabledFn = VTable.enabled,
            .registerCallbackFn = VTable.registerCallback,
        };
    }
};
```

## SDK Implementation

### Error Handling Configuration

```zig
// Configurable error handling policies
pub const CallbackErrorPolicy = enum {
    fail_fast,      // First error fails entire collection
    log_continue,   // Log errors but continue collection (default)
    silent_ignore,  // Ignore errors completely
};

pub const AsyncInstrumentConfig = struct {
    error_policy: CallbackErrorPolicy = .log_continue,
    max_measurements_per_callback: ?usize = null,
    warn_on_no_measurements: bool = true,
    track_callback_metrics: bool = true,
};
```

### SDK Observable Instrument Implementation

```zig
// Callback execution metrics
pub const CallbackMetrics = struct {
    total_executions: u64 = 0,
    total_execution_time_ns: u64 = 0,
    max_execution_time_ns: u64 = 0,
    min_execution_time_ns: u64 = std.math.maxInt(u64),
    error_count: u64 = 0,
    last_execution_time_ns: u64 = 0,
    last_error: ?[]const u8 = null,
    
    pub fn recordExecution(self: *CallbackMetrics, duration_ns: u64) void {
        self.total_executions += 1;
        self.total_execution_time_ns += duration_ns;
        self.last_execution_time_ns = duration_ns;
        self.max_execution_time_ns = @max(self.max_execution_time_ns, duration_ns);
        self.min_execution_time_ns = @min(self.min_execution_time_ns, duration_ns);
    }
    
    pub fn recordError(self: *CallbackMetrics, error_msg: []const u8) void {
        self.error_count += 1;
        self.last_error = error_msg;
    }
    
    pub fn getAverageExecutionTimeNs(self: *const CallbackMetrics) u64 {
        if (self.total_executions == 0) return 0;
        return self.total_execution_time_ns / self.total_executions;
    }
};

pub fn SdkObservableCounter(comptime T: type) type {
    return struct {
        const Self = @This();
        
        const CallbackEntry = struct {
            callback_fn: *const fn (state: ?*anyopaque, result: *ObservableResult(T)) void,
            state: ?*anyopaque,
            id: usize,
            metrics: CallbackMetrics,
        };
        
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        callbacks: std.ArrayList(CallbackEntry),
        next_callback_id: usize,
        parent_meter: *BasicMeter,
        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex,
        config: AsyncInstrumentConfig,
        instrument_metrics: CallbackMetrics,
        
        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            parent_meter: *BasicMeter,
            config: AsyncInstrumentConfig,
        ) Self {
            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .callbacks = std.ArrayList(CallbackEntry).init(allocator),
                .next_callback_id = 1,
                .parent_meter = parent_meter,
                .allocator = allocator,
                .mutex = std.Thread.Mutex{},
                .config = config,
                .instrument_metrics = .{},
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.callbacks.deinit();
        }
        
        pub fn getName(self: *const Self) []const u8 {
            return self.name;
        }
        
        pub fn enabled(self: *const Self) bool {
            return !self.parent_meter.is_shutdown and self.callbacks.items.len > 0;
        }
        
        pub fn registerCallback(
            self: *Self,
            callback_fn: *const fn (state: ?*anyopaque, result: *ObservableResult(T)) void,
            state: ?*anyopaque,
        ) !CallbackHandle {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            const callback_id = self.next_callback_id;
            self.next_callback_id += 1;
            
            try self.callbacks.append(.{
                .callback_fn = callback_fn,
                .state = state,
                .id = callback_id,
                .metrics = .{},
            });
            
            return CallbackHandle.init(
                @ptrCast(self),
                unregisterCallback,
                callback_id,
            );
        }
        
        fn unregisterCallback(instrument_ptr: *anyopaque, callback_id: usize) void {
            const self: *Self = @ptrCast(@alignCast(instrument_ptr));
            
            self.mutex.lock();
            defer self.mutex.unlock();
            
            // Find and remove callback by ID
            for (self.callbacks.items, 0..) |callback, i| {
                if (callback.id == callback_id) {
                    _ = self.callbacks.orderedRemove(i);
                    break;
                }
            }
        
            // Optional: Export callback metrics as internal metrics
            if (self.async_config.track_callback_metrics) {
                try self.exportCallbackMetrics(metrics);
            }
        }
    
        fn exportCallbackMetrics(self: *BasicMeter, metrics: *std.ArrayList(MetricData)) !void {
            // Export aggregated callback execution metrics
            for (self.observable_counters_i64.items) |counter| {
                const instrument_metrics = counter.getInstrumentMetrics();
                if (instrument_metrics.total_executions > 0) {
                    // Create internal metric for callback execution time
                    const metric_name = try std.fmt.allocPrint(
                        self.allocator,
                        "otel.sdk.metrics.callback.duration_ns[instrument={s}]",
                        .{counter.getName()},
                    );
                    defer self.allocator.free(metric_name);
                
                    // Export as a gauge with average execution time
                    const avg_time = instrument_metrics.getAverageExecutionTimeNs();
                    const gauge_data = MetricData{
                        .name = metric_name,
                        .description = "Average callback execution duration in nanoseconds",
                        .unit = "ns",
                        .data = .{ .gauge = .{ .datapoints = &[_]NumberDataPoint(f64){
                            .{
                                .value = @as(f64, @floatFromInt(avg_time)),
                                .attributes = &[_]AttributeKeyValue{
                                    .{ .key = "instrument.name", .value = .{ .string = counter.getName() } },
                                    .{ .key = "instrument.type", .value = .{ .string = "observable_counter" } },
                                    .{ .key = "callback.errors", .value = .{ .int = @as(i64, @intCast(instrument_metrics.error_count)) } },
                                    .{ .key = "callback.executions", .value = .{ .int = @as(i64, @intCast(instrument_metrics.total_executions)) } },
                                },
                                .timestamp = @intCast(std.time.nanoTimestamp()),
                            },
                        } } },
                    };
                    try metrics.append(gauge_data);
                }
            }
        }
        
        pub fn collect(self: *Self) !?MetricData {
            if (!self.enabled()) return null;
            
            var all_measurements = std.ArrayList(ObservableResult(T).Measurement).init(self.allocator);
            defer all_measurements.deinit();
            
            // Execute all callbacks
            self.mutex.lock();
            defer self.mutex.unlock();
            
            for (self.callbacks.items, 0..) |callback, i| {
                var callback_measurements = std.ArrayList(ObservableResult(T).Measurement).init(self.allocator);
                defer callback_measurements.deinit();
                
                var result = ObservableResult(T).init(&callback_measurements);
                
                const start_time = std.time.nanoTimestamp();
                const exec_result = self.executeCallback(callback, &result);
                const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
                
                // Update callback-specific metrics
                var callback_entry = &self.callbacks.items[i];
                callback_entry.metrics.recordExecution(duration);
                
                // Update instrument-level metrics
                self.instrument_metrics.recordExecution(duration);
                
                // Handle execution errors
                exec_result catch |err| {
                    callback_entry.metrics.recordError(@errorName(err));
                    self.instrument_metrics.recordError(@errorName(err));
                    
                    switch (self.config.error_policy) {
                        .fail_fast => return err,
                        .log_continue => {
                            std.log.err("Callback execution failed for instrument '{}': {}", .{ self.name, err });
                            continue;
                        },
                        .silent_ignore => continue,
                    }
                };
                
                // Check measurement limits
                if (self.config.max_measurements_per_callback) |max| {
                    if (callback_measurements.items.len > max) {
                        std.log.warn("Callback for instrument '{}' exceeded maximum measurements ({} > {})", .{ self.name, callback_measurements.items.len, max });
                        callback_measurements.shrinkRetainingCapacity(max);
                    }
                }
                
                // Add to overall measurements (pass everything downstream)
                try all_measurements.appendSlice(callback_measurements.items);
            }
            
            if (all_measurements.items.len == 0) return null;
            
            // Convert measurements to MetricData
            return self.createMetricData(all_measurements.items);
        }
        
        fn executeCallback(self: *Self, callback: CallbackEntry, result: *ObservableResult(T)) !void {
            // Execute the callback function
            // This is a simple wrapper that could be extended with timeout handling
            callback.callback_fn(callback.state, result);
        }
        
        fn createMetricData(self: *Self, measurements: []const ObservableResult(T).Measurement) !MetricData {
            var data_points = try self.allocator.alloc(MetricDataPoint, measurements.len);
            errdefer self.allocator.free(data_points);
            
            for (measurements, 0..) |measurement, i| {
                data_points[i] = .{
                    .timestamp_ns = measurement.timestamp,
                    .start_timestamp_ns = null, // Async instruments don't track start time
                    .attributes = measurement.attributes,
                    .value = switch (T) {
                        i64 => .{ .i64_sum = measurement.value },
                        f64 => .{ .f64_sum = measurement.value },
                        else => unreachable,
                    },
                };
            }
            
            return .{
                .name = self.name,
                .description = self.description,
                .unit = self.unit,
                .type = .sum, // For counters
                .data_points = data_points,
                .scope = self.parent_meter.scope,
                .resource = self.parent_meter.resource,
            };
        }
        
        pub fn destroy(self: *Self) void {
            self.allocator.destroy(self);
        }
        
        // Metrics query methods
        pub fn getInstrumentMetrics(self: *const Self) CallbackMetrics {
            return self.instrument_metrics;
        }
        
        pub fn getCallbackMetrics(self: *const Self, callback_id: usize) ?CallbackMetrics {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            for (self.callbacks.items) |callback| {
                if (callback.id == callback_id) {
                    return callback.metrics;
                }
            }
            return null;
        }
        
        pub fn getAllCallbackMetrics(self: *const Self) ![]const CallbackMetrics {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            var metrics = try self.allocator.alloc(CallbackMetrics, self.callbacks.items.len);
            for (self.callbacks.items, 0..) |callback, i| {
                metrics[i] = callback.metrics;
            }
            return metrics;
        }
    };
}

// SdkObservableGauge and SdkObservableUpDownCounter are similar
// but with different MetricType (.gauge vs .sum)
```

### BasicMeter Extensions

```zig
// Add to BasicMeter struct
pub const BasicMeter = struct {
    // ... existing fields ...
    
    // Observable instrument collections
    observable_counters_i64: std.ArrayList(*SdkObservableCounter(i64)),
    observable_counters_f64: std.ArrayList(*SdkObservableCounter(f64)),
    observable_gauges_i64: std.ArrayList(*SdkObservableGauge(i64)),
    observable_gauges_f64: std.ArrayList(*SdkObservableGauge(f64)),
    observable_updown_counters_i64: std.ArrayList(*SdkObservableUpDownCounter(i64)),
    observable_updown_counters_f64: std.ArrayList(*SdkObservableUpDownCounter(f64)),
    
    // Async instrument configuration
    async_config: AsyncInstrumentConfig = .{},
    
    // ... existing methods ...
    
    pub fn createObservableCounterI64(
        self: *BasicMeter,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
    ) !ObservableCounter(i64) {
        if (self.is_shutdown) {
            return ObservableCounter(i64){ .noop = name };
        }
        
        const validated_name = validateInstrumentName(name);
        const validated_desc = validateInstrumentDescription(description);
        const validated_unit = validateInstrumentUnit(unit);
        
        const instrument = try self.allocator.create(SdkObservableCounter(i64));
        instrument.* = SdkObservableCounter(i64).init(
            self.allocator,
            validated_name,
            validated_desc,
            validated_unit,
            self,
            self.async_config,
        );
        
        try self.observable_counters_i64.append(instrument);
        
        return ObservableCounter(i64){
            .bridge = AsyncInstrumentBridge.init(instrument),
        };
    }
    
    // Similar methods for other observable instrument types...
    
    pub fn collectMetrics(self: *BasicMeter) ![]MetricData {
        var metrics = std.ArrayList(MetricData).init(self.allocator);
        errdefer {
            for (metrics.items) |metric| {
                self.allocator.free(metric.data_points);
            }
            metrics.deinit();
        }
        
        // Collect synchronous instruments (existing)
        try self.collectSynchronousMetrics(&metrics);
        
        // Collect asynchronous instruments (new)
        try self.collectAsynchronousMetrics(&metrics);
        
        return metrics.toOwnedSlice();
    }
    
    fn collectAsynchronousMetrics(self: *BasicMeter, metrics: *std.ArrayList(MetricData)) !void {
        // Collect observable counters
        for (self.observable_counters_i64.items) |instrument| {
            if (try instrument.collect()) |metric_data| {
                try metrics.append(metric_data);
            }
        }
        
        for (self.observable_counters_f64.items) |instrument| {
            if (try instrument.collect()) |metric_data| {
                try metrics.append(metric_data);
            }
        }
        
        // Similar for gauges and updown counters...
        
        // Export callback metrics if enabled
        if (self.async_config.track_callback_metrics) {
            try self.exportCallbackMetrics(metrics);
        }
    }
};
```

## Usage Examples

### Multiple Callbacks for Process Metrics

```zig
// Different state types for different callback purposes
const ProcessState = struct {
    pid: u32,
};

const SystemState = struct {
    proc_stat_path: []const u8,
};

// Callback 1: Individual process memory
fn processMemoryCallback(state: *ProcessState, result: *ObservableResult(i64)) void {
    const memory = getProcessMemory(state.pid) catch return;
    result.observe(memory, &[_]AttributeKeyValue{
        .{ .key = "pid", .value = .{ .int = @intCast(state.pid) } },
        .{ .key = "type", .value = .{ .string = "process" } },
    });
}

// Callback 2: System-wide memory from /proc/meminfo
fn systemMemoryCallback(state: *SystemState, result: *ObservableResult(i64)) void {
    const mem_info = readMemInfo(state.proc_stat_path) catch return;
    
    result.observe(mem_info.total, &[_]AttributeKeyValue{
        .{ .key = "type", .value = .{ .string = "total" } },
    });
    
    result.observe(mem_info.available, &[_]AttributeKeyValue{
        .{ .key = "type", .value = .{ .string = "available" } },
    });
    
    result.observe(mem_info.free, &[_]AttributeKeyValue{
        .{ .key = "type", .value = .{ .string = "free" } },
    });
}

// Usage
var process_state = ProcessState{ .pid = 1234 };
var system_state = SystemState{ .proc_stat_path = "/proc/meminfo" };

const memory_gauge = try meter.createObservableGauge(i64, "memory.usage", "Memory usage in bytes", "bytes");

// Register multiple callbacks to same instrument
const handle1 = try memory_gauge.registerCallback(*ProcessState, processMemoryCallback, &process_state);
const handle2 = try memory_gauge.registerCallback(*SystemState, systemMemoryCallback, &system_state);

defer {
    handle1.unregister();
    handle2.unregister();
}

// During collection, both callbacks execute and all measurements are passed downstream
```

### No-State Callback

```zig
fn simpleTemperatureCallback(result: *ObservableResult(f64)) void {
    const temp = getCurrentTemperature() catch return;
    result.observe(temp, &[_]AttributeKeyValue{});
}

const temp_gauge = try meter.createObservableGauge(f64, "temperature", "Current temperature", "°C");
const handle = try temp_gauge.registerCallbackNoState(simpleTemperatureCallback);
defer handle.unregister();
```

### CPU Metrics with Multiple Observations

```zig
const CpuState = struct {
    proc_stat_path: []const u8,
};

fn cpuStatsCallback(state: *CpuState, result: *ObservableResult(i64)) void {
    const cpu_stats = readProcStat(state.proc_stat_path) catch return;
    
    // Report multiple CPU cores and modes
    for (cpu_stats.cores, 0..) |core, i| {
        result.observe(core.user_time, &[_]AttributeKeyValue{
            .{ .key = "cpu", .value = .{ .int = @intCast(i) } },
            .{ .key = "mode", .value = .{ .string = "user" } },
        });
        
        result.observe(core.system_time, &[_]AttributeKeyValue{
            .{ .key = "cpu", .value = .{ .int = @intCast(i) } },
            .{ .key = "mode", .value = .{ .string = "system" } },
        });
        
        result.observe(core.idle_time, &[_]AttributeKeyValue{
            .{ .key = "cpu", .value = .{ .int = @intCast(i) } },
            .{ .key = "mode", .value = .{ .string = "idle" } },
        });
    }
}

var cpu_state = CpuState{ .proc_stat_path = "/proc/stat" };
const cpu_counter = try meter.createObservableCounter(i64, "cpu.time", "CPU time", "ns");
const handle = try cpu_counter.registerCallback(*CpuState, cpuStatsCallback, &cpu_state);
defer handle.unregister();
```

### Monitoring Callback Metrics

```zig
// Enable callback metrics tracking in configuration
const meter_config = BasicMeterConfig{
    .async_config = .{
        .track_callback_metrics = true,
        .error_policy = .log_continue,
    },
};

// Create instruments with callbacks
const memory_gauge = try meter.createObservableGauge(i64, "memory.usage", "Memory usage", "bytes");
const cpu_counter = try meter.createObservableCounter(i64, "cpu.time", "CPU time", "ns");

// Register callbacks
const mem_handle = try memory_gauge.registerCallback(*SystemState, systemMemoryCallback, &system_state);
const cpu_handle = try cpu_counter.registerCallback(*CpuState, cpuStatsCallback, &cpu_state);

// Later, query callback performance metrics
const mem_metrics = memory_gauge.getInstrumentMetrics();
std.log.info("Memory callback stats: executions={}, avg_time={}ns, errors={}", .{
    mem_metrics.total_executions,
    mem_metrics.getAverageExecutionTimeNs(),
    mem_metrics.error_count,
});

// Get metrics for a specific callback
if (cpu_counter.getCallbackMetrics(cpu_handle.callback_id)) |callback_metrics| {
    std.log.info("CPU callback: last_execution={}ns, max_time={}ns", .{
        callback_metrics.last_execution_time_ns,
        callback_metrics.max_execution_time_ns,
    });
}

// The SDK will automatically export these metrics if configured
// They'll appear as internal metrics like:
// - otel.sdk.metrics.callback.duration_ns[instrument=memory.usage]
// - otel.sdk.metrics.callback.duration_ns[instrument=cpu.time]

// Use case: Detect slow callbacks
const all_metrics = try cpu_counter.getAllCallbackMetrics();
defer meter.allocator.free(all_metrics);

for (all_metrics, 0..) |metrics, i| {
    if (metrics.max_execution_time_ns > 1_000_000) { // 1ms threshold
        std.log.warn("Callback {} is slow: max_time={}ms", .{
            i,
            metrics.max_execution_time_ns / 1_000_000,
        });
    }
}

// Use case: Monitor callback health
if (mem_metrics.error_count > 0) {
    std.log.err("Memory callback has errors: {} failures, last error: {s}", .{
        mem_metrics.error_count,
        mem_metrics.last_error orelse "unknown",
    });
}