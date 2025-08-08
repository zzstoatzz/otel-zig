# Multi-Aggregator Support for Metrics SDK

## Executive Summary

This document outlines the design for adding multi-aggregator support to the OpenTelemetry Zig metrics SDK. The current implementation maintains a single aggregation state per instrument, which prevents multiple readers from having independent aggregation states and reset lifecycles. This design proposes moving aggregation state from per-instrument to per-reader, enabling proper multi-reader support and laying the groundwork for future views implementation.

## Problem Statement

### Current Limitations

1. **Single Aggregation State**: Each instrument currently maintains one aggregation state shared across all readers
2. **Shared Reset Lifecycle**: All readers must share the same aggregation temporality and reset timing
3. **Mutex Contention**: Current design uses a mutex per instrument, which would become a bottleneck with per-reader aggregations
4. **No View Support**: Current architecture cannot support views that generate multiple data points from a single instrument

### Requirements

1. Support multiple readers with independent aggregation states
2. Maintain high performance with minimal lock contention
3. Use lock-free operations where possible (preferred over registry/sharding approach)
4. Support future views implementation (multiple data points per instrument)
5. Maintain backward compatibility with existing examples and tests
6. SDK-only changes (no API modifications are expected)
7. Handle attribute cardinality with hard limits (drop at limit, add an attribute, static limit value)
8. Memory ownership by MeterProvider or Aggregators (SDK components, don't need to be non-owning)
9. Integration with API error handling system for errors

## Architecture Overview

### Current Architecture

```
Instrument (owns aggregation)
    ↓ mutex-protected add/record
Aggregation State (single)
    ↓ collected by
Multiple Readers (share same state)
```

### Proposed Architecture

```
Instrument (recording interface)
    ↓ forwards measurements to all readers
Reader 1: Own Aggregation State (independent)
Reader 2: Own Aggregation State (independent)
Reader N: Own Aggregation State (independent)
    ↓ collection per reader's schedule
Individual Readers with Independent Lifecycles
```

**How this solves the problem:**
- Each reader maintains its own complete aggregation state
- No shared state means no contention between readers
- Different temporalities are natural - each reader manages its own
- Views can create multiple aggregations per reader for the same instrument
- Lock-free optimizations can be applied to the aggregation operations themselves

## Detailed Design

### Core Components

#### 1. Per-Reader Aggregation Storage

Each reader maintains its own independent aggregation state:

```zig
// Each reader owns its aggregation states
pub const ReaderAggregationState = struct {
    // Phase 1: Map from instrument pointer to dynamically allocated aggregation
    // Phase 1b: Changes to AttributeAggregationMap
    aggregations: std.AutoHashMap(*anyopaque, *Aggregation),  // instrument ptr → aggregation
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,  // Protects map access in Phase 1/1b

    // Reader's configured temporality
    temporality: AggregationTemporality,

    // Aggregation selector (determines aggregation type per instrument)
    aggregation_selector: AggregationSelector,

    // For cumulative temporality, track last collection time
    last_collection_time_ns: u64,

    pub fn recordMeasurement(
        self: *@This(),
        instrument: *anyopaque,  // Generic instrument pointer
        value: anytype,
        attributes: []const AttributeKeyValue,
        metadata: MetricMetadata
    ) void {
        // Phase 1: Thread-safe map access
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = self.aggregations.getOrPut(@ptrToInt(instrument)) catch unreachable;
        if (!result.found_existing) {
            // Dynamically allocate new aggregation
            const agg = self.allocator.create(Aggregation) catch unreachable;
            agg.* = createAggregationForType(metadata.instrument_type, metadata);
            result.value_ptr.* = agg;
        }

        result.value_ptr.*.record(value);
    }

    pub fn deinit(self: *@This()) void {
        // Clean up dynamically allocated aggregations
        var iter = self.aggregations.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.aggregations.deinit();
    }

    pub fn collect(self: *@This(), allocator: std.mem.Allocator) ![]MetricData {
        // Collect from all aggregations
        // Apply temporality conversion if needed
        // Reset delta aggregations after collection
    }
};
```

#### 2. Lock-Free Aggregation Types

For high-performance measurement recording (Phase 1c):

```zig
/// Aggregation type that views can specify to override instrument defaults
pub const AggregationType = enum {
    sum,
    histogram,
    last_value,
    drop,  // Special case: don't aggregate at all
};

pub const Aggregation = union(AggregationType) {
    sum: SumAggregation,
    histogram: HistogramAggregation,
    last_value: LastValueAggregation,
    drop: void,  // Drop aggregation - ignores all measurements

    pub fn record(self: *@This(), value: anytype) void {
        switch (self.*) {
            .sum => |*s| s.record(value),
            .histogram => |*h| h.record(value),
            .last_value => |*l| l.record(value),
            .drop => {},  // Intentionally do nothing
        }
    }
};

pub const SumAggregation = struct {
    // Phase 1/1b: mutex protected
    mutex: std.Thread.Mutex,
    value: i64,

    // Phase 1c: lock-free (mutex removed entirely)
    // value: std.atomic.Value(i64),

    // Metadata duplicated in each aggregation type
    instrument_name: []const u8,
    instrument_type: InstrumentType,
    instrument_unit: []const u8,

    pub fn record(self: *@This(), value: i64) void {
        // Phase 1/1b implementation
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value += value;

        // Phase 1c implementation (replaces above)
        // _ = self.value.fetchAdd(value, .monotonic);
    }
};

pub const HistogramAggregation = struct {
    // Phase 1/1b: Mutex protected
    mutex: std.Thread.Mutex,
    sum: f64,
    count: u64,
    min: f64,
    max: f64,
    bucket_counts: [MAX_BUCKETS]u64,

    // Phase 1c: lock-free (mutex removed, all fields atomic)
    // sum: std.atomic.Value(f64),
    // count: std.atomic.Value(u64),
    // min: std.atomic.Value(f64),
    // max: std.atomic.Value(f64),
    // bucket_counts: [MAX_BUCKETS]std.atomic.Value(u64),

    // Metadata duplicated in each aggregation type
    instrument_name: []const u8,
    instrument_type: InstrumentType,
    instrument_unit: []const u8,

    pub fn record(self: *@This(), value: f64) void {
        // Phase 1/1b implementation
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sum += value;
        self.count += 1;
        // Update min/max and buckets...

        // Phase 1c: Use atomics and CAS loops
    }
};

pub const LastValueAggregation = struct {
    // Phase 1/1b: Mutex protected
    mutex: std.Thread.Mutex,
    value: ?f64,
    timestamp: u64,

    // Phase 1c: lock-free
    // value: std.atomic.Value(?f64),
    // timestamp: std.atomic.Value(u64),

    // Metadata duplicated in each aggregation type
    instrument_name: []const u8,
    instrument_type: InstrumentType,
    instrument_unit: []const u8,

    pub fn record(self: *@This(), value: f64) void {
        // Phase 1/1b implementation
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value = value;
        self.timestamp = getCurrentTime();

        // Phase 1c: Use atomic swap
    }
};
```

#### 3. Attribute Storage and Cardinality Management

```zig
// Metadata passed from instrument to reader for aggregation creation
pub const MetricMetadata = struct {
    name: []const u8,               // May be transformed by view
    description: []const u8,        // May be transformed by view
    unit: []const u8,               // From original instrument (not transformable)
    instrument_type: InstrumentType,
    meter_name: []const u8,
    meter_version: []const u8,
    meter_schema_url: []const u8,
    metadata_hash: u64,             // Pre-computed hash of static metadata

    pub fn computeHash(self: *const @This()) u64 {
        // Hash all static fields once
        var hash: u64 = 0xcbf29ce484222325;  // FNV offset
        // Hash name, unit, meter_name, etc.
        // ... implementation details ...
        return hash;
    }
};

pub const AttributeAggregationMap = struct {
    // Map from (instrument_id + attribute_hash) to aggregation
    aggregations: std.AutoHashMap(u128, *Aggregation),

    // Pre-allocated pool of aggregations
    aggregation_pool: [MAX_CARDINALITY]Aggregation,
    next_free: usize = 0,

    // Track cardinality
    cardinality: usize = 0,
    const MAX_CARDINALITY: usize = 2000;

    // Overflow aggregation for when limit is reached
    overflow_aggregation: ?*Aggregation = null,

    pub fn getOrCreateAggregation(
        self: *@This(),
        instrument: *Instrument,
        attributes: []const AttributeKeyValue,
        metadata: MetricMetadata  // Phase 2: Use for aggregation initialization
    ) !*Aggregation {
        // Combine instrument ID and attribute hash for unique key
        const attr_hash = computeAttributeHash(attributes);
        const instrument_id = @intFromPtr(instrument);
        const combined_hash = (@as(u128, instrument_id) << 64) | attr_hash;

        if (self.aggregations.get(combined_hash)) |agg| {
            return agg;
        }

        // Check cardinality limit
        if (self.next_free >= MAX_CARDINALITY) {
            if (self.overflow_aggregation == null) {
                // Use first slot in pool for overflow
                self.overflow_aggregation = &self.aggregation_pool[0];
                self.overflow_aggregation.* = createAggregationForType(
                    metadata.instrument_type,
                    metadata.name,
                    metadata.unit
                );

                api.common.handleError(.{
                    .component = .meter,
                    .error_type = .resource_exhausted,
                    .message = "Attribute cardinality limit exceeded",
                });
            }
            return self.overflow_aggregation.?;
        }

        // Get next aggregation from pool
        const agg = &self.aggregation_pool[self.next_free];
        self.next_free += 1;

        // Initialize based on instrument type with metadata
        agg.* = createAggregationForType(
            metadata.instrument_type,
            metadata.name,
            metadata.unit
        );

        try self.aggregations.put(combined_hash, agg);
        return agg;
    }

    fn createAggregationForType(
        instrument_type: InstrumentType,
        name: []const u8,
        unit: []const u8
    ) Aggregation {
        return switch (instrument_type) {
            .Counter, .UpDownCounter => .{
                .sum = SumAggregation{
                    .mutex = .{},
                    .value = 0,
                    .instrument_name = name,
                    .instrument_type = instrument_type,
                    .instrument_unit = unit,
                },
            },
            .Histogram => .{
                .histogram = HistogramAggregation{
                    .mutex = .{},
                    .sum = 0,
                    .count = 0,
                    .min = 0,
                    .max = 0,
                    .bucket_counts = [_]u64{0} ** MAX_BUCKETS,
                    .instrument_name = name,
                    .instrument_type = instrument_type,
                    .instrument_unit = unit,
                },
            },
            .Gauge => .{
                .last_value = LastValueAggregation{
                    .mutex = .{},
                    .value = null,
                    .timestamp = 0,
                    .instrument_name = name,
                    .instrument_type = instrument_type,
                    .instrument_unit = unit,
                },
            },
        };
    }
};

fn computeAttributeHash(attributes: []const AttributeKeyValue) u64 {
    // Sort attributes for consistency
    // Use a commutative hash function
    // Return 64-bit hash
}
```

#### 4. View Application System

Views transform measurements before they reach aggregations:

```zig
// Views are stored directly on MeterProvider as a field
// No separate ViewRegistry type needed

pub const ViewApplication = struct {
    // The view that matched (or default view)
    view: *View,

    // Check if this view drops measurements
    pub fn drops(self: *@This()) bool {
        return self.view.aggregation_override == .drop;
    }

    // Transform attributes according to view
    pub fn transformAttributes(
        self: *@This(),
        input: []const AttributeKeyValue
    ) []const AttributeKeyValue {
        if (self.view.attribute_allowed_keys) |keep_keys| {
            if (keep_keys.len == 0) return &[_]AttributeKeyValue{};  // Drop all attributes
            // Filter to only specified keys
            return filterAttributes(input, keep_keys);
        }
        return input; // Keep all (null = keep all)
    }

    // Get the name for this metric stream
    pub fn getName(self: *@This(), original_name: []const u8) []const u8 {
        return self.view.name orelse original_name;
    }

    // Get the description for this metric stream
    pub fn getDescription(self: *@This(), original_desc: []const u8) []const u8 {
        return self.view.description orelse original_desc;
    }
};

pub const View = struct {
    // Default view for instruments with no matching views
    pub const default = View{
        .instrument_selector = .{},  // Matches nothing (used for default only)
        .name = null,                // Keep original name
        .description = null,          // Keep original description
        .attribute_allowed_keys = null,  // Keep all attributes
        .aggregation_override = null,  // Use default aggregation for instrument type
    };

    // View fields will be defined in Phase 2
};
```

### Phase 1: Move Aggregations to Readers

#### Goals
- Move aggregations from instruments to readers (each reader owns instrument → aggregation map)
- Support multiple readers from the start (solves multi-reader requirement)
- Invert control flow from pull-based to push-based model
- Maintain current functionality with new architecture
- Ensure all existing tests pass without modification
- Use mutex-based synchronization (lock-free comes in a later phase)

#### Control Flow Inversion

This phase fundamentally changes how metrics data flows through the system:

**Current (Pull) Model:**
```
Collection Time:
  Reader → iterates Meters → iterates Instruments → reads Aggregation
  (Reader pulls data when it wants)
```

**New (Push) Model:**
```
Measurement Time:
  Instrument → pushes to all Readers → Reader updates its Aggregation
  (Instrument pushes data immediately)

Collection Time:
  Reader → reads its own Aggregations
  (Reader already has all data)
```

This inversion is critical because:
1. Enables independent reader aggregation states
2. Removes contention between readers
3. Allows different temporalities per reader
4. Simplifies the collection process

It does cause some additional memory pressure, but that trade-off enables independence across readers.

#### Implementation Steps

1. **Refactor Instrument Types**
   ```zig
   // Old: Instrument owns aggregation
   pub fn StandardCounter(comptime T: type) type {
       return struct {
           aggregation: SumAggregation(T),
           mutex: std.Thread.Mutex,
           // ...
       };
   }

   // New: Instrument forwards to provider's readers
   pub fn StandardCounter(comptime T: type) type {
       return struct {
           meter: *Meter,  // Reference to meter (which has provider pointer)
           descriptor: InstrumentDescriptor,
           metadata_hash: u64,  // Pre-computed hash of instrument+meter metadata

           pub fn add(self: *@This(), value: T, attributes: []const AttributeKeyValue) void {
               // Phase 1: No views, just forward to readers
               const metadata = MetricMetadata{
                   .name = self.descriptor.name,
                   .description = self.descriptor.description,
                   .unit = self.descriptor.unit,
                   .instrument_type = self.descriptor.type,
                   .meter_name = self.meter.name,
                   .meter_version = self.meter.version,
                   .meter_schema_url = self.meter.schema_url,
                   .metadata_hash = self.metadata_hash,  // Pre-computed at instrument creation
               };

               // Forward to all readers
               for (self.meter.provider.readers.items) |reader| {
                   reader.recordMeasurement(self, value, attributes, metadata);
               }
           }
       };
   }
   ```

2. **Create ReaderAggregationState**
   - Each reader maintains map: instrument → aggregation
   - Dynamically allocate aggregations on first use
   - Mutex protects map access for thread safety
   - Readers own aggregations and free them in deinit()

3. **Update Architecture**
   - MeterProvider owns readers array (must be populated before global registration)
   - Meter gets pointer to MeterProvider: `provider: *MeterProvider`
   - Instruments get reference to Meter (can traverse to provider via meter.provider)
   - Measurements flow: Instrument → Provider's Readers → Reader's Aggregations
   - Each reader collects independently from its own aggregations
   - No more iteration over instruments during collection

4. **Update Tests**
   - Ensure all existing tests pass

#### Success Criteria
- `zig build test-sdk` passes
- Examples continue to work unchanged
- Multiple readers work independently
- Architecture ready for Phase 1b
- Architecture ready for lock-free conversion

### Phase 1b: Eliminate Instrument-to-Aggregation Map

#### Goals
- Remove the instrument → aggregation map
- Reader directly owns aggregations indexed by attribute combinations
- Prepare for lock-free by reducing lock points
- Maintain all Phase 1 functionality

#### Implementation Steps

1. **Refactor ReaderAggregationState**
   ```zig
   pub const ReaderAggregationState = struct {
       // Instead of: instrument → aggregation
       // Now: attribute_hash → aggregation
       aggregations: AttributeAggregationMap,

       pub fn recordMeasurement(
           self: *@This(),
           instrument: *Instrument,
           value: anytype,
           attributes: []const AttributeKeyValue,
           metadata: MetricMetadata  // Phase 2: Added for view transformations
       ) void {
           // Get or create aggregation for this instrument + attribute combination
           // Phase 1b: Switch to attribute-based aggregation
           const attr_hash = computeAttributeHash(attributes);
           const combined_hash = metadata.metadata_hash ^ attr_hash;  // Combine pre-computed metadata hash

           const agg = self.aggregations.getOrCreateAggregation(
               combined_hash,
               metadata
           );

           // Still mutex-protected in this phase
           agg.record(value);
       }
   };
   ```

2. **Pre-allocate Aggregation Pool**
   - Allocate all 2000 aggregations at reader creation
   - No dynamic allocation during measurement recording

#### Success Criteria
- All Phase 1 tests still pass
- Reduced lock contention points
- Ready for lock-free conversion

### Phase 1c: Lock-Free Implementation

#### Goals
- Replace mutex-based aggregation with lock-free operations
- Remove all mutexes from aggregation types
- Maintain all functionality from Phase 1b
- Improve performance for high-concurrency scenarios
- Support all aggregation types (sum, histogram, last-value)

#### Implementation Steps

1. **Convert Aggregation Types to Lock-Free**
   ```zig
   // Remove mutex, use atomic operations
   pub const SumAggregation = struct {
       value: std.atomic.Value(i64),

       // Metadata remains (includes transformed name from view)
       instrument_name: []const u8,  // May be transformed by view
       instrument_type: InstrumentType,
       instrument_unit: []const u8,

       pub fn record(self: *@This(), value: i64) void {
           _ = self.value.fetchAdd(value, .monotonic);
       }
   };

   pub const HistogramAggregation = struct {
       sum: std.atomic.Value(f64),
       count: std.atomic.Value(u64),
       min: std.atomic.Value(f64),
       max: std.atomic.Value(f64),
       bucket_counts: [MAX_BUCKETS]std.atomic.Value(u64),

       pub fn record(self: *@This(), value: f64) void {
           // Atomic operations for sum/count
           _ = self.sum.fetchAdd(value, .monotonic);
           _ = self.count.fetchAdd(1, .monotonic);

           // CAS loops for min/max
           var current = self.min.load(.monotonic);
           while (value < current) {
               if (self.min.cmpxchgWeak(current, value, .monotonic, .monotonic)) |actual| {
                   current = actual;
               } else break;
           }

           // Atomic bucket increment
           const bucket = computeBucket(value);
           _ = self.bucket_counts[bucket].fetchAdd(1, .monotonic);
       }
   };
   ```

2. **Update ReaderAggregationState**
   - Remove mutexes from aggregation access
   - Atomic operations only for aggregation updates

3. **Performance Validation**
   - Benchmark against Phase 1b mutex implementation
   - Verify improvement with high thread counts

#### Success Criteria
- All Phase 1b tests still pass
- Measurable performance improvement (expectation is 2x for high contention)
- No race conditions or data loss
- All aggregation types working lock-free

### Phase 2: View Support (Foundation)

Multiple reader support is was completed in Phase 1. Phase 2 focuses on Views.

#### Goals
- Support views that can generate multiple data points
- Enable attribute filtering/transformation (DropAll, rename, allow/deny attributes initially)
- Maintain performance with pre-computed projections
- Views immutable after meter creation (no dynamic reconfiguration initially)
- Handle incompatible aggregation types with warning + ignore strategy

#### Implementation Steps

1. **View Configuration API**
   ```zig
   pub const View = struct {
       // Instrument selector (all criteria are additive/AND-ed)
       instrument_selector: InstrumentSelector,

       // Stream configuration (per OTel spec)
       name: ?[]const u8,                        // Override instrument name
       description: ?[]const u8,                 // Override instrument description
       attribute_allowed_keys: ?[]const []const u8,  // Allow list: null = keep all, empty = drop all
       aggregation_override: ?AggregationType,   // Override instrument's default aggregation (null = use default)
       // Note: Unit is NOT transformable per spec

       // Views are immutable after creation, validation happens at registration
   };

   pub const InstrumentSelector = struct {
       // All fields are optional (null means match any)
       name: ?[]const u8,           // "*" = all, supports wildcards (? and *)
       type: ?InstrumentType,        // Counter, Histogram, etc.
       unit: ?[]const u8,           // Exact match
       meter_name: ?[]const u8,     // Exact match
       meter_version: ?[]const u8,  // Exact match
       meter_schema_url: ?[]const u8, // Exact match

       pub fn matches(self: *const @This(), instrument: *const Instrument) bool {
           // Check name (minimal wildcard support per spec requirement)
           if (self.name) |pattern| {
               // Minimal: support exact match and "*" for all
               if (!std.mem.eql(u8, pattern, "*") and
                   !std.mem.eql(u8, pattern, instrument.name)) {
                   return false;
               }
           }

           // Check type
           if (self.type) |t| {
               if (t != instrument.type) return false;
           }

           // Check unit
           if (self.unit) |u| {
               if (!std.mem.eql(u8, u, instrument.unit)) return false;
           }

           // Check meter properties
           if (self.meter_name) |mn| {
               if (!std.mem.eql(u8, mn, instrument.meter.name)) return false;
           }

           // All specified criteria matched
           return true;
       }
   };
   ```

2. **View Matching and Application**
   ```zig
   // Method on MeterProvider, not separate ViewRegistry
   pub fn applyViews(
       self: *MeterProvider,
       instrument: *Instrument,
       allocator: std.mem.Allocator
   ) ![]ViewApplication {
       var applications = ArrayList(ViewApplication).init(allocator);

       for (self.views.items) |view| {
           if (view.instrument_selector.matches(instrument)) {
               // Validate aggregation compatibility
               if (!isAggregationCompatible(instrument.type, view.aggregation_override)) {
                   api.common.handleError(.{
                       .component = .meter,
                       .error_type = .validation,
                       .message = "Incompatible aggregation type for instrument",
                   });
                   continue; // Skip this view
               }
               const app = ViewApplication{
                   .view = view,
                   .projected_attributes = try computeProjection(view.attribute_keys),
                   .aggregation = try createAggregation(view.aggregation_override),
               };
               try applications.append(app);
           }
       }

       // If no views matched, add default view
       if (applications.items.len == 0) {
           try applications.append(.{ .view = View.default });
       }

       return applications.toOwnedSlice();
   }
   ```

3. **Multi-Stream Generation**
   - Each view creates a separate metric stream
   - Measurements are duplicated to all matching views
   - Each stream maintains independent aggregation

3. **View Matching and Application**
   4. **Example: View with Attribute Filtering**
      ```zig
      test "view with attribute filtering" {
          const provider = try MeterProvider.init(allocator);

          // Add view that only allows "method" and "status" attributes
          try provider.addView(.{
              .instrument_selector = .{ .name = "requests" },
              .attribute_allowed_keys = &[_][]const u8{ "method", "status" },
          });

          const meter = provider.getMeter("test", "1.0.0");
          const counter = try meter.createCounter("requests", .{});

          // Record with multiple attributes
          counter.add(1, .{
              .{ "method", "GET" },
              .{ "status", "200" },
              .{ "user_id", "12345" }, // This will be dropped
          });

          const metrics = try provider.collect(allocator);

          // Verify user_id was filtered out
          const attrs = metrics[0].data_points[0].attributes;
          try testing.expect(attrs.len == 2);
      }
      ```

   5. **Multiple Matching Views**
      ```zig
      test "multiple views match same instrument" {
          const provider = try MeterProvider.init(allocator);

          // Add multiple views that match the same instrument
          try provider.addView(.{
              .instrument_selector = .{ .name = "requests" },
              .aggregation_override = .drop,  // Drop view
          });
          try provider.addView(.{
              .instrument_selector = .{ .name = "requests" },
              .attribute_allowed_keys = &[_][]const u8{ "method" },  // Normal view
          });

          const meter = provider.getMeter("test", "1.0.0");
          const counter = try meter.createCounter("requests", .{});

          // This will create two streams:
          // 1. Drop stream (no data collected)
          // 2. Normal stream (only "method" attribute)
          counter.add(1, .{ .{ "method", "GET" }, .{ "status", "200" } });

          const metrics = try provider.collect(allocator);

          // Only the non-drop view produces output
          try testing.expect(metrics.len == 1);
          try testing.expect(metrics[0].data_points[0].attributes.len == 1);
      }
      ```

#### Success Criteria
- Views can filter attributes (re-filter on every measurement initially)
- Views can rename instruments
- Multiple views can match same instrument
- Performance impact acceptable for initial implementation
- New view example works correctly
- Integration with error handler for validation errors
- View configuration helpers added to `setupGlobalProvider`

### Performance Optimizations

#### 1. Lock-Free Measurement Recording (Phase 1c)

```zig
pub fn recordMeasurement(self: *LockFreeAccumulator, value: i64) void {
    // Atomic operations for sum and count (preferred)
    _ = self.sum_i64.fetchAdd(value, .monotonic);
    _ = self.count.fetchAdd(1, .monotonic);

    // CAS loop for min/max (required for correctness)
    var current_min = self.min.load(.monotonic);
    while (value < current_min) {
        if (self.min.cmpxchgWeak(
            current_min,
            value,
            .monotonic,
            .monotonic
        )) |actual| {
            current_min = actual;
        } else {
            break;
        }
    }

    // For histogram: atomic increment of bucket counts
    const bucket_index = computeBucketIndex(value);
    _ = self.bucket_counts[bucket_index].fetchAdd(1, .monotonic);
}
```

Note: All aggregation types (sum, histogram, last-value) must be supported with lock-free operations from the start.

#### 2. Thread-Safe Collection (Phase 1c considerations)

When Phase 1c removes mutexes, we'll need:
- Lock-free hashmap or sharded maps
- Read-copy-update (RCU) pattern for readers
- Atomic pointers for aggregation swapping
- Careful ordering of operations to avoid races

Note: The specific lock-free strategy will be determined during Phase 1c implementation based on performance testing.

### Testing Strategy

#### Phase 1 Tests
1. **Compatibility Tests**: Ensure all existing tests pass
2. **MVS Unit Tests**: Test ring buffer, epoch tracking
3. **Single Reader Collection**: Verify correct aggregation

#### Phase 2 Tests
1. **Multi-Reader Registration**: Test reader ID assignment
2. **Independent Collection**: Verify readers don't interfere
3. **Temporality Conversion**: Test delta/cumulative conversion
4. **Reader Lifecycle**: Test late registration, removal

#### Phase 3 Tests
1. **View Matching**: Test selector logic
2. **Attribute Filtering**: Verify correct projection
3. **Multi-Stream**: Test multiple views on same instrument
4. **View Performance**: Benchmark overhead

#### Performance Tests
```zig
test "performance: measurement throughput benchmark" {
    const iterations = 1_000_000;
    const threads = 8;

    // Create benchmark example that measures throughput
    // Goal: Establish baseline, not meet specific target yet
    const throughput = try benchmarkThroughput(iterations, threads);

    // Log results for future comparison
    std.log.info("Throughput: {} measurements/sec", .{throughput});

    // No specific performance target initially
    // This establishes our baseline for future optimization
}
```

Note: Focus on creating measurement infrastructure rather than meeting specific performance targets initially.

### Benchmark Infrastructure

#### Directory Structure
```
benchmarks/
├── README.md                    # Benchmark documentation
└── metrics/                     # Metrics-specific benchmarks
    ├── throughput.zig          # Measurement recording throughput
    ├── cardinality.zig         # High-cardinality attribute handling
    ├── multi_reader.zig        # Multi-reader collection performance
    └── lock_free.zig           # Lock-free vs mutex comparison
```

Note: Benchmark targets are added to the root build.zig, not a separate build file.

#### Benchmark Scenarios

1. **Throughput Benchmark**
   - Raw measurement recording speed
   - Variable thread counts (1, 2, 4, 8, 16, 32)
   - Variable attribute set sizes (0, 5, 10, 20 attributes)
   - Different instrument types (Counter, Histogram, Gauge)
   - Output: operations/second, per-thread throughput

2. **Cardinality Benchmark**
   - Behavior at 2000 cardinality limit
   - Overflow handling performance
   - Memory usage tracking
   - Attribute hash distribution

3. **Multi-Reader Benchmark**
   - 1, 2, 4, 8 concurrent readers
   - Mixed temporalities (delta/cumulative)
   - Collection during active recording
   - Reader isolation verification

4. **Lock-Free Comparison**
   - Phase 1 (mutex) vs Phase 1b (lock-free)
   - High contention scenarios
   - CAS retry counts for histograms
   - Memory ordering impact

#### Benchmark Output Format
```
Benchmark: counter-throughput
Configuration:
  Threads: 8
  Iterations: 1000000
  Attributes: 5
Results:
  Total time: 1.234s
  Throughput: 810,372 ops/sec
  Per-thread: 101,296 ops/sec
  Memory peak: 45.2 MB
  P95 latency: 125ns (if applicable)
```

#### Build Integration
```bash
# Benchmark targets in root build.zig
# Run all benchmarks
zig build benchmark

# Run specific benchmark
zig build benchmark-throughput
zig build benchmark-cardinality

# With parameters
zig build benchmark-throughput -Dthreads=16 -Diterations=10000000
```

#### Deadlock Prevention Tests
```zig
test "deadlock: concurrent collection and recording" {
    // Start multiple threads recording measurements
    // Start multiple threads collecting metrics
    // Verify no deadlock after timeout
    // Verify all data is eventually collected
}
```

### Migration Guide

#### For SDK Users
No changes required for basic usage. Multi-reader support is automatic.

#### For Custom Processors/Exporters
```zig
// Old: Processor directly accesses instrument aggregations
const value = instrument.aggregation.getValue();

// New: Processor receives aggregated data from reader
const metric_data = try reader.collect(allocator);
```

### Configuration Helpers

Extension to existing `setupGlobalProvider` in `setup.zig`:

```zig
// Extended setupGlobalProvider signature
pub fn setupGlobalProvider(
    allocator: std.mem.Allocator,
    links: anytype,
    views: anytype  // Compile-time variadic like links
) !*DefaultProvider {
    // ... existing implementation ...

    // After provider creation, before pipeline setup:
    inline for (views) |view| {
        try provider_ptr.addView(view);
    }

    // ... continue with pipeline setup ...
}

// Note: No backwards compatibility variant needed
```

### Risk Analysis

#### Performance Risks
- **Mitigation**: Extensive benchmarking, lock-free design
- **Fallback**: Keep mutex-based path for debugging

#### Memory Risks
- **Mitigation**: Bounded ring buffers, memory pools
- **Cardinality Control**: Hard limit of 2000 (matches C++ implementation)
- **Overflow Handling**: Create overflow attribute {"otel.metrics.overflow": true}
- **Error Reporting**: Use ErrorType.resource_exhausted for cardinality overflow

#### Compatibility Risks
- **Mitigation**: Phased approach, maintain API compatibility
- **Fallback**: Feature flag for new implementation

### Timeline Estimate

- **Phase 1**: 3-4 days (move aggregations to readers, multi-reader support included, invert control flow)
- **Phase 1b**: 2 days (eliminate instrument map, direct attribute-based aggregation)
- **Phase 1c**: 2-3 days (lock-free conversion, remove mutex_protected union tags)
- **Phase 2**: 4-5 days (view foundation with selectors)
- **Testing**: 2-3 days (comprehensive test suite)
- **Documentation**: 1-2 days
- **Benchmarks**: 1-2 days (separate benchmarks/ directory)

**Total**: 16-20 days

Implementation Order:
1. Move aggregators to readers with multi-reader support (Phase 1)
2. Eliminate instrument map for direct aggregation (Phase 1b)
3. Convert to lock-free mechanics (Phase 1c)
4. Add view support (Phase 2)
5. Create benchmark infrastructure (parallel with phases)

### Design Decisions

1. **Cardinality Limit**: 2000 (matches C++ implementation), compile-time constant
2. **Overflow Strategy**: Create `{"otel.metrics.overflow": true}` attribute when limit exceeded
3. **Error Handling**: Use existing `ErrorType.validation` and `ErrorType.resource_exhausted`
4. **Memory Pooling**: Pre-allocated pool of 2000 aggregations, no compaction
5. **Lock-Free Coverage**: All aggregation types from the start (sum, histogram, last-value)
6. **View Configuration**: Compile-time variadic parameter like links
7. **Benchmark Infrastructure**: Separate `benchmarks/` directory
8. **Reader Management**: ArrayList of readers, no removal, added before global registration
9. **Phase Ordering**: Complete each phase fully before proceeding to next
10. **Benchmarking**: Separate infrastructure to establish baselines, not meet targets
11. **No MVS/Ring Buffer**: Each reader owns its aggregation state directly
12. **View Selectors**: Minimal implementation - exact match and "*" for all
13. **Expected Reader Count**: 2-3 typical, ~10 maximum (ArrayList is fine)
14. **Hash Algorithm**: XOR-based commutative hash for attributes
15. **Histogram Buckets**: Use existing DEFAULT_HISTOGRAM_BOUNDARIES from aggregations.zig
16. **Aggregation Type**: Default based on instrument type (Counter→Sum, Histogram→Histogram)
17. **Attribute Filtering**: Re-filter on every measurement (performance optimization later)

### Implementation Notes

#### Reader Terminology
The current SDK incorrectly uses "processor" in method names. This design uses "reader" consistently as that's the correct OpenTelemetry term. The implementation will need to update method names accordingly.

#### Attribute Overflow Handling
When cardinality limit (2000) is reached:
1. New attribute combinations are rejected
2. Measurements are accumulated under overflow attribute `{"otel.metrics.overflow": true}`
3. Error handler notified with `ErrorType.resource_exhausted`
4. No tracking of which specific attributes were dropped (memory optimization)

#### Lock-Free Implementation Details
- **Sum/Counter**: Pure atomic operations (`fetchAdd`)
- **Histogram**: Atomic bucket increments + CAS loops for min/max
- **LastValue**: Atomic swap for value + timestamp
- **Attributes**: Hash computed once, stored atomically
- **Memory Ordering**: `.monotonic` for most operations, `.acquire`/`.release` for synchronization points

#### View Registration Flow
1. Views registered at provider creation time (immutable after)
2. When instrument created, all views evaluated for matches
3. Matching views stored with instrument (or DEFAULT_VIEW if no matches)
4. Each matching view creates independent metric stream (per spec)
5. On measurement, instrument applies ALL its views before forwarding to readers
6. Drop aggregation views cause measurements to be ignored for that stream only
7. Invalid view/instrument combinations logged and skipped
8. Views can transform: name, description, attributes (via allow list), aggregation type
9. Views CANNOT transform: unit (per spec)
10. Transformed metadata passed to readers for storage in aggregations

Note: Multiple views can match the same instrument, creating multiple independent streams. If an instrument matches both a Drop view and a normal view, the Drop creates one stream that drops data while the normal view creates another stream that collects data.

#### Histogram Bucket Configuration
- Use DEFAULT_HISTOGRAM_BOUNDARIES from aggregations.zig (15 boundaries, 16 buckets)
- Boundaries: [0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]
- Views can specify custom bucket boundaries in Phase 2
- Configuration supported per-instrument at creation time

#### Attribute Hash Algorithm
```zig
fn computeAttributeHash(attributes: []const AttributeKeyValue) u64 {
    // XOR-based commutative hash (order-independent)
    var hash: u64 = 0;

    for (attributes) |attr| {
        // Hash each key-value pair independently
        var pair_hash: u64 = 0xcbf29ce484222325; // FNV offset basis

        // Hash the key
        for (attr.key) |byte| {
            pair_hash ^= byte;
            pair_hash *%= 0x00000100000001B3; // FNV prime
        }

        // Hash the value (type-specific)
        switch (attr.value) {
            .string => |s| for (s) |byte| {
                pair_hash ^= byte;
                pair_hash *%= 0x00000100000001B3;
            },
            .int => |i| {
                const bytes = std.mem.asBytes(&i);
                for (bytes) |byte| {
                    pair_hash ^= byte;
                    pair_hash *%= 0x00000100000001B3;
                }
            },
            // ... other types
        }

        // XOR for commutativity (order-independent)
        hash ^= pair_hash;
    }
    return hash;
}
```

#### Why No Ring Buffer / MVS
The original design included a Multi-Version Storage (MVS) system with ring buffers. This was removed because:
1. **Unnecessary complexity**: Each reader having its own aggregation state is simpler and cleaner
2. **No batching needed**: Measurements go directly to reader aggregations
3. **Memory efficiency**: No need to store multiple versions of data
4. **Lock-free still works**: Atomic operations on aggregations achieve the performance goal
5. **Reader independence**: Each reader naturally has independent state without complex coordination

### Conclusion

This design provides a scalable, performant solution for multi-aggregator support in the metrics SDK. The phased approach ensures stability while progressively adding features. The lock-free design minimizes contention, and the multi-version storage pattern elegantly handles multiple readers with different requirements.

The architecture is designed to support future enhancements like views, exemplars, and advanced aggregations without major restructuring. The testing strategy ensures correctness and performance at each phase.
