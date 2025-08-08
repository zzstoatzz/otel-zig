# Multi-Aggregator Support Implementation TODO

This document outlines the step-by-step implementation plan for adding multi-aggregator support to the OpenTelemetry Zig metrics SDK.

## Overview

**Implementation Order:**
1. Phase 1: Move Aggregations to Readers
2. Phase 1b: Eliminate Instrument-to-Aggregation Map  
3. Phase 1c: Lock-Free Implementation
4. Phase 2: View Support (Foundation)

**Timeline Estimate:** 16-20 days total

---

## Phase 1: Move Aggregations to Readers (3-4 days)

### Goals
- Move aggregations from instruments to readers (each reader owns instrument → aggregation map)
- Support multiple readers with independent aggregation states
- Invert control flow from pull-based to push-based model
- Maintain current functionality with new architecture
- Ensure all existing tests pass without modification

### Implementation Tasks

#### 1. Add `recordMeasurement()` to Reader Interface
**Files:** `src/sdk/metrics/reader.zig`
- [ ] Add `recordMeasurement()` method to `Reader` union
- [ ] Add `recordMeasurementFn` to `BridgeReader` vtable
- [ ] Update vtable init function to include new method
- [ ] Method signature:
  ```zig
  pub fn recordMeasurement(
      self: *Reader,
      instrument: *anyopaque,
      value: anytype,
      attributes: []const api.AttributeKeyValue,
      metadata: MetricMetadata
  ) void
  ```

#### 2. Create MetricMetadata Structure
**Files:** `src/sdk/metrics/data.zig` or new file `src/sdk/metrics/metadata.zig`
- [ ] Create `MetricMetadata` struct with fields:
  - `name: []const u8`
  - `description: []const u8` 
  - `unit: []const u8`
  - `instrument_type: InstrumentType`
  - `meter_name: []const u8`
  - `meter_version: []const u8`
  - `meter_schema_url: []const u8`
  - `metadata_hash: u64`
- [ ] Add `computeHash()` method for pre-computing hash of static metadata

#### 3. Create ReaderAggregationState
**Files:** `src/sdk/metrics/reader_aggregation_state.zig` (new file)
- [ ] Create `ReaderAggregationState` struct with:
  - `aggregations: std.AutoHashMap(*anyopaque, *Aggregation)`
  - `allocator: std.mem.Allocator`
  - `mutex: std.Thread.Mutex`
  - `temporality: AggregationTemporality`
  - `aggregation_selector: AggregationSelector`
  - `last_collection_time_ns: u64`
- [ ] Implement `recordMeasurement()` method with thread-safe map access
- [ ] Implement `deinit()` to clean up dynamically allocated aggregations
- [ ] Implement `collect()` stub (returns empty for now, real implementation in Phase 1b)

#### 4. Update Concrete Reader Implementations
**Files:** `src/sdk/metrics/manual_reader.zig`, `src/sdk/metrics/periodic_reader.zig`
- [ ] Add `reader_state: ReaderAggregationState` field to concrete readers
- [ ] Initialize reader state in `init()` methods
- [ ] Implement `recordMeasurement()` method that forwards to reader state
- [ ] Update `collect()` methods to collect from reader state instead of iterating meters
- [ ] Update `deinit()` to clean up reader state

#### 5. Refactor Instrument Types  
**Files:** `src/sdk/metrics/instruments.zig`
- [ ] Remove aggregation fields from all instrument types:
  - `StandardCounter(T)`
  - `StandardUpDownCounter(T)`
  - `StandardGauge(T)`
  - `StandardHistogram(T)`
- [ ] Add `meter: *Meter` reference to all instruments
- [ ] Add `descriptor: InstrumentDescriptor` and `metadata_hash: u64` fields
- [ ] Update instrument `init()` methods to compute `metadata_hash` at creation time
- [ ] Refactor measurement methods (`addI64`, `addF64`, `recordI64`, `recordF64`) to:
  1. Create `MetricMetadata` from instrument fields
  2. Forward to all readers via `self.meter.provider.readers.items`
  3. Call `reader.recordMeasurement(self, value, attributes, metadata)`
- [ ] Remove aggregation-specific methods like `getValue()`, `reset()`, `getStartTimestamp()`

#### 6. Update Meter to Hold Provider Reference
**Files:** `src/sdk/metrics/meter.zig`
- [ ] Add `provider: *MeterProvider` field to `Meter` struct
- [ ] Update `Meter.init()` to accept provider parameter
- [ ] Update instrument creation methods to pass `self` (meter) to instruments
- [ ] Remove `collectMetrics()` method (collection now happens at reader level)

#### 7. Update MeterProvider
**Files:** `src/sdk/metrics/meter_provider.zig`
- [ ] Update `Meter.init()` calls to pass `self` (provider) parameter
- [ ] Update collection flow to let readers handle their own collection
- [ ] Ensure readers list is populated before any meter creation

#### 8. Update Aggregation Types (Prepare for Phase 1b)
**Files:** `src/sdk/metrics/aggregations.zig`
- [ ] Keep existing aggregation types but ensure they're compatible with dynamic allocation
- [ ] Add metadata fields to aggregation types:
  - `instrument_name: []const u8`
  - `instrument_type: InstrumentType` 
  - `instrument_unit: []const u8`

### Success Criteria
- [ ] `zig build test-sdk` passes
- [ ] All existing examples work unchanged
- [ ] Multiple readers work independently 
- [ ] Measurements flow: Instrument → Provider's Readers → Reader's Aggregations
- [ ] No more iteration over instruments during collection
- [ ] Architecture ready for Phase 1b

### Deferred Items
- Lock-free operations (Phase 1c)
- View support (Phase 2)
- Attribute-based aggregation indexing (Phase 1b)
- Optimized cardinality management (Phase 1b)

---

## Phase 1b: Eliminate Instrument-to-Aggregation Map (2 days)

### Goals  
- Remove the instrument → aggregation map
- Reader directly owns aggregations indexed by attribute combinations
- Prepare for lock-free by reducing lock points
- Maintain all Phase 1 functionality

### Implementation Tasks

#### 1. Create AttributeAggregationMap
**Files:** `src/sdk/metrics/attribute_aggregation_map.zig` (new file)
- [ ] Create `AttributeAggregationMap` struct with:
  - `aggregations: std.AutoHashMap(u128, *Aggregation)`
  - `aggregation_pool: [MAX_CARDINALITY]Aggregation`
  - `next_free: usize = 0`
  - `cardinality: usize = 0`
  - `MAX_CARDINALITY: usize = 2000`
  - `overflow_aggregation: ?*Aggregation = null`
- [ ] Implement `getOrCreateAggregation()` method with cardinality enforcement
- [ ] Implement `createAggregationForType()` helper
- [ ] Add overflow handling with `{"otel.metric.overflow": true}` attribute
- [ ] Integrate with error handler for `ErrorType.resource_exhausted`

#### 2. Implement Attribute Hash Function
**Files:** `src/sdk/metrics/attribute_hash.zig` (new file)
- [ ] Implement `computeAttributeHash()` function
- [ ] Ensure hash is commutative (order-independent)
- [ ] Handle all AttributeValue types (string, int, float, bool, arrays)
- [ ] Use any reasonable hash algorithm (FNV, xxhash, etc.)

#### 3. Update ReaderAggregationState
**Files:** `src/sdk/metrics/reader_aggregation_state.zig`
- [ ] Replace `std.AutoHashMap(*anyopaque, *Aggregation)` with `AttributeAggregationMap`
- [ ] Update `recordMeasurement()` to:
  1. Compute attribute hash
  2. Combine with metadata hash: `combined_hash = metadata.metadata_hash ^ attr_hash`
  3. Get or create aggregation from AttributeAggregationMap
  4. Record measurement on aggregation
- [ ] Pre-allocate aggregation pool at reader creation
- [ ] Remove dynamic allocation during measurement recording

### Success Criteria
- [ ] All Phase 1 tests still pass
- [ ] Reduced lock contention points (single lock per reader instead of per instrument)
- [ ] Cardinality limit enforced at 2000 per reader
- [ ] Overflow handling working with error reporting
- [ ] Ready for lock-free conversion

---

## Phase 1c: Lock-Free Implementation (2-3 days)

### Goals
- Replace mutex-based aggregation with lock-free operations
- Remove all mutexes from aggregation types  
- Maintain all functionality from Phase 1b
- Improve performance for high-concurrency scenarios
- Support all aggregation types (sum, histogram, last-value)

### Implementation Tasks

#### 1. Convert Aggregation Types to Lock-Free
**Files:** `src/sdk/metrics/aggregations.zig`
- [ ] Update `SumAggregation(T)`:
  - Replace `value: T` with `value: std.atomic.Value(T)`
  - Replace `add()` with atomic `fetchAdd()`
  - Remove mutex field
- [ ] Update `LastValueAggregation(T)`:
  - Replace `value: ?T` with `value: std.atomic.Value(?T)`
  - Replace `record()` with atomic swap
  - Remove mutex field
- [ ] Update `HistogramAggregation(T)`:
  - Replace fields with atomic versions:
    - `sum: std.atomic.Value(f64)`
    - `count: std.atomic.Value(u64)`
    - `min: std.atomic.Value(f64)`
    - `max: std.atomic.Value(f64)`
    - `bucket_counts: [MAX_BUCKETS]std.atomic.Value(u64)`
  - Implement CAS loops for min/max updates
  - Use atomic operations for sum/count/bucket updates
  - Remove mutex field

#### 2. Update ReaderAggregationState for Lock-Free Access
**Files:** `src/sdk/metrics/reader_aggregation_state.zig`
- [ ] Remove mutex from aggregation access (keep for map modifications if needed)
- [ ] Ensure `recordMeasurement()` uses only atomic operations for aggregation updates
- [ ] Consider lock-free map or accept brief locking for map access

#### 3. Performance Validation
- [ ] Create benchmark comparing Phase 1b (mutex) vs Phase 1c (lock-free)
- [ ] Verify no race conditions or data loss
- [ ] Test high concurrency scenarios

### Success Criteria
- [ ] All Phase 1b tests still pass
- [ ] Measurable performance improvement (target: 2x for high contention)
- [ ] No race conditions or data loss
- [ ] All aggregation types working lock-free

### Deferred Items
- Lock-free hashmap implementation (accept brief locking for map access)

---

## Phase 2: View Support (Foundation) (4-5 days)

### Goals
- Support views that can generate multiple data points
- Enable attribute filtering/transformation  
- Views immutable after meter creation
- Handle incompatible aggregation types with warnings

### Implementation Tasks

#### 1. Create View System Types
**Files:** `src/sdk/metrics/view.zig` (new file)
- [ ] Create `View` struct with:
  - `instrument_selector: InstrumentSelector`
  - `name: ?[]const u8`
  - `description: ?[]const u8`
  - `attribute_allowed_keys: ?[]const []const u8`
  - `aggregation_override: ?AggregationType`
- [ ] Create `InstrumentSelector` struct with matching logic
- [ ] Create `ViewApplication` struct for applying views
- [ ] Add `View.default` constant for instruments with no matching views

#### 2. Add AggregationType Enum
**Files:** `src/sdk/metrics/aggregations.zig`
- [ ] Create `AggregationType` enum: `sum, histogram, last_value, drop`
- [ ] Create `Aggregation` union with all aggregation types
- [ ] Add `drop` aggregation type that ignores measurements

#### 3. Integrate Views with MeterProvider
**Files:** `src/sdk/metrics/meter_provider.zig`
- [ ] Add `views: std.ArrayListUnmanaged(View)` field
- [ ] Add `addView()` method for view registration
- [ ] Implement `applyViews()` method for view matching and application
- [ ] Add validation for view/instrument compatibility

#### 4. Update Instruments for View Processing
**Files:** `src/sdk/metrics/instruments.zig`
- [ ] Update measurement methods to:
  1. Apply all matching views to transform attributes/metadata
  2. Forward transformed measurements to readers
  3. Handle drop aggregation by skipping forwarding
- [ ] Cache view applications at instrument creation time

#### 5. Add View Configuration to Setup
**Files:** `src/sdk/metrics/setup.zig`
- [ ] Extend `setupGlobalProvider()` to accept views parameter
- [ ] Follow existing variadic pattern like links parameter

### Success Criteria
- [ ] Views can filter attributes (allow list)
- [ ] Views can rename instruments
- [ ] Multiple views can match same instrument creating multiple streams
- [ ] Drop aggregation works (measurements ignored)
- [ ] Integration with error handler for validation errors
- [ ] View configuration helpers added to setupGlobalProvider

### Deferred Items
- Advanced view features (wildcards beyond "*", complex selectors)
- Dynamic view reconfiguration
- View performance optimizations (pre-computed projections)
- Exemplars
- Complex aggregation configurations

---

## Testing Strategy

### Phase 1 Tests
- [ ] All existing SDK tests pass (`zig build test-sdk`)
- [ ] Multi-reader independence tests
- [ ] Control flow inversion verification
- [ ] Memory management tests (no leaks)

### Phase 1b Tests  
- [ ] Cardinality limit enforcement
- [ ] Overflow attribute generation
- [ ] Attribute hash collision handling
- [ ] Error handler integration

### Phase 1c Tests
- [ ] Lock-free operation correctness
- [ ] High concurrency stress tests
- [ ] Performance benchmarks vs Phase 1b
- [ ] Race condition detection

### Phase 2 Tests
- [ ] View matching logic
- [ ] Attribute filtering
- [ ] Multi-stream generation  
- [ ] Drop aggregation
- [ ] View configuration

## Benchmark Infrastructure (1-2 days, parallel with phases)

### Directory Structure Setup
- [ ] Create `benchmarks/metrics/` directory
- [ ] Add benchmark targets to root `build.zig`
- [ ] Create benchmark documentation in `benchmarks/README.md`

### Benchmark Scenarios
- [ ] Throughput benchmark (ops/second at various thread counts)
- [ ] Cardinality benchmark (behavior at 2000 limit)
- [ ] Multi-reader benchmark (performance with multiple readers)
- [ ] Lock-free comparison (Phase 1b vs 1c)

---

## Implementation Notes

### Memory Management
- Instruments remain owned by meters (no ownership change)
- Only aggregation ownership moves from instruments to readers
- Each reader owns its aggregation state completely
- Use pre-allocated pools where possible to avoid runtime allocation

### Error Handling
- Use `api.common.handleError()` throughout
- `ErrorType.resource_exhausted` for cardinality limits
- `ErrorType.validation` for view/instrument compatibility errors

### Thread Safety
- Phase 1: Mutex per reader aggregation map
- Phase 1c: Lock-free aggregations, minimal locking for map access
- Always ensure measurements are not lost or double-counted

### Performance Targets
- Phase 1: Maintain current performance
- Phase 1c: 2x improvement for high contention scenarios
- All phases: No performance regression for single-reader case

---

## Risk Mitigation

### Performance Risks
- Extensive benchmarking after each phase
- Keep mutex-based fallback for debugging
- Monitor memory usage throughout

### Compatibility Risks  
- Run full test suite after each phase
- Verify all examples still work
- Test with multiple readers from start

### Implementation Risks
- Complete each phase fully before proceeding
- Validate success criteria before moving to next phase
- Keep detailed change log for debugging

---

## Definition of Done

Each phase is complete when:
1. All success criteria are met
2. All existing tests pass
3. New functionality is tested
4. Performance is acceptable or improved
5. Documentation is updated
6. Code review is completed

The overall project is complete when Phase 2 is finished and the full test suite passes with the new multi-aggregator architecture supporting independent readers and basic view functionality.