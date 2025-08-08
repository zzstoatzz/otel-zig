# Multi-Aggregator Support Design Document

## Table of Contents
1. [Overview](#overview)
2. [Design Goals](#design-goals)
3. [Architecture](#architecture)
4. [Component Details](#component-details)
5. [Implementation Plan](#implementation-plan)
6. [Testing Strategy](#testing-strategy)

## Overview

This document outlines the design for adding multi-aggregator support to the metrics SDK, enabling per-reader aggregation and paving the way for view support.

## Design Goals

1. Support multiple independent aggregators per instrument
2. Enable per-reader aggregation
3. Minimize lock contention for high performance
4. Maintain compatibility with OTel specifications
5. Ensure thread safety for concurrent recording and collection
6. Support high-cardinality attribute sets efficiently

## Architecture

The system will use a centralized AggregatorRegistry that efficiently manages aggregators based on:
- Reader ID
- Aggregation type
- Configuration hash
- Attribute set hash

### High-Level Components

1. **AggregatorRegistry**: Central coordinator managing all aggregators
2. **AttributeAwareAggregator**: Specialized aggregator handling attribute-based grouping
3. **SnapshotCollector**: Ensures consistent snapshots without blocking recording

## Component Details

### AggregatorRegistry

```zig
const AggregatorRegistry = struct {
    outer_map: std.StringHashMap(ReaderRegistry),  // reader_id → ReaderRegistry
    outer_lock: std.thread.Mutex,

    // Inner map structure (per reader)
    const ReaderRegistry = struct {
        agg_type_map: std.StringHashMap(ConfigRegistry),  // aggregation_type → ConfigRegistry
    };

    // Config registry level
    const ConfigRegistry = struct {
        attr_hash_map: std.StringHashMap(Aggregator),
        lock: std.thread.Mutex,

        // For high-cardinality cases
        shards: [8]Shard,  // 8 shards for parallel access
    };

    pub fn getOrCreateAggregator(...) ?*Aggregator {
        // Two-level locking implementation
        // with sharding for high-cardinality attribute sets
    }
};
```

### Attribute Handling

1. **Attribute Hashing**:
```zig
fn calculateAttributeHash(attributes: []AttributeKeyValue) u64 {
    // Sort attributes for consistent hashing
    const sorted = sortAttributes(attributes);

    // Use a fast, non-cryptographic hash function
    // with proper handling of different attribute types
    return std.mem.hash(u64, sorted);
}
```

2. **Attribute Processing**:
- Attributes are sorted and normalized before hashing
- Special handling for different attribute value types
- String attributes are normalized (case, whitespace)

### Thread Safety Mechanisms

1. **Lock-Free Counters**:
   - For simple counters using atomic operations
   - Fallback to fine-grained locks for complex aggregations

2. **Snapshot Collection**:
```zig
const SnapshotAggregator = struct {
    current: std.atomic.Int = .{ .value = 0 },
    snapshot: std.atomic.Int = .{ .value = 0 },
    snapshot_lock: std.thread.Mutex,
    shard_index: u8,  // For sharding

    pub fn prepareSnapshot(self: *SnapshotAggregator) void {
        // Lock and swap current → snapshot
        // Using double-buffering technique
    }

    pub fn getSnapshot(self: *SnapshotAggregator) i64 {
        // Return the snapshot without blocking recording
    }
};
```

3. **Sharding Strategy**:
   - Attribute hash space divided among 8 shards
   - Each shard has independent locks
   - Shard selection based on attribute hash

### Memory Management

1. **LRU Caching**:
   - For rarely used attribute combinations
   - Configurable maximum size
   - Background cleanup thread

2. **Resource Tracking**:
   - Per-reader resource tracking
   - Automatic cleanup when readers unregister

## Implementation Plan

### Phase 1: Core Infrastructure (2 weeks)

1. **AggregatorRegistry Implementation**
   - Basic registry structure
   - Two-level locking scheme
   - Sharding support

2. **Attribute Handling**
   - Attribute sorting and hashing
   - Normalization of attribute values

3. **Basic Aggregator Types**
   - Sum aggregator with attribute support
   - LastValue aggregator adaptation
   - Histogram aggregator modifications

4. **Initial Tests**
   - Basic functionality verification
   - Thread safety smoke tests

### Phase 2: Reader Support (1 week)

1. **Reader Management**
   - Reader ID generation
   - Registration/unregistration handling

2. **Collection Integration**
   - Snapshot collection implementation
   - Reader-specific aggregation

3. **Reader Tests**
   - Multiple reader scenarios
   - Dynamic registration tests

### Phase 3: Performance Optimization (1 week)

1. **Benchmarking**
   - Baseline performance measurements
   - Contention scenario testing

2. **Optimizations**
   - Lock-free path implementation
   - Sharding effectiveness testing
   - Memory usage profiling

3. **Tuning**
   - Shard count optimization
   - LRU cache sizing
   - Lock contention analysis

### Phase 4: View Support (2 weeks)

1. **View Configuration**
   - View specification parsing
   - Attribute filtering implementation

2. **Multi-Datapoint Aggregation**
   - Datapoint generation from views
   - Aggregator modifications

3. **View Tests**
   - Attribute filtering verification
   - Type conversion tests
   - Complex view scenarios

## Testing Strategy

### Unit Tests

1. **AggregatorRegistry**
   - Basic CRUD operations
   - Concurrent access tests
   - Memory management verification

2. **Attribute Handling**
   - Hash consistency verification
   - Normalization edge cases
   - Collision resistance testing

3. **Thread Safety**
   - Concurrent recording tests
   - Snapshot collection during recording
   - Stress tests with high thread counts

### Integration Tests

1. **Reader Scenarios**
   - Single reader baseline
   - Multiple reader independence
   - Dynamic registration/unregistration

2. **Performance Tests**
   - High-volume recording
   - High-cardinality attribute sets
   - Mixed workload scenarios

3. **Correctness Tests**
   - Aggregation accuracy
   - Attribute-based grouping
   - View transformation correctness

### Stress Tests

1. **Memory Usage**
   - Long-running with steady load
   - High-cardinality attribute explosion
   - Reader churn scenarios

2. **Concurrency Limits**
   - Max thread contention
   - Sustained high load
   - Bursty workload patterns

## Open Questions

1. Should we implement a background compaction process for the registry?
2. What's the optimal initial shard count for most workloads?
3. Should we expose registry statistics for monitoring?

## Appendix: Example Usage

```zig
// Instrument setup
const counter = try meter.createCounterI64("request.count");

// Recording with attributes
const attributes = &[_]AttributeKeyValue{
    .{ .key = "http.route", .value = .{ .string = "/api/users" } },
    .{ .key = "http.method", .value = .{ .string = "GET" } },
};
counter.add(1, attributes);

// Reader collection
const snapshot = reader.prepareSnapshot();
defer snapshot.release();
for (snapshot) |datapoint| {
    // Process collected metrics
}
```

This design provides a comprehensive approach to implementing multi-aggregator support with proper handling of attribute-based grouping, thread safety, and performance considerations. The phased implementation plan ensures incremental progress with validation at each stage.