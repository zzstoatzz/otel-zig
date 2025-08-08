# Design Document: Multi-Aggregator and View Support for Metrics SDK

## 1. Introduction

This document outlines the design for introducing multi-aggregator support and Views to the Zig OpenTelemetry metrics SDK. The primary goal is to transition from a per-instrument aggregation model to a per-reader/per-view aggregation model. This change will enable users to customize metric streams, including changing aggregation types, filtering attributes, and renaming instruments, all without altering the core API. The design prioritizes performance, aiming for lock-free operations where feasible.

## 2. Current Architecture

The current metrics SDK has the following characteristics:

*   **`MeterProvider`**: Manages `Meter` instances and a list of `Reader`s.
*   **`Meter`**: Creates and owns all metric instruments (`Counter`, `Histogram`, etc.). It holds a list of instruments of each type.
*   **Instruments (`StandardCounter`, etc.)**: Each instrument contains a single `Aggregation` instance (e.g., `SumAggregation`) and a mutex to protect access to it.
*   **`Aggregation`**: Structs like `SumAggregation` and `HistogramAggregation` store the actual metric values.
*   **`Reader`**: Periodically calls `collectMetrics` on each registered `Meter`.
*   **`collectMetrics`**: Iterates through all instruments in a `Meter`, reads their aggregated values, and creates `MetricData` objects for export.

This architecture has a fundamental limitation: **aggregation is tied directly to the instrument**. This means a single instrument can only have one aggregation state, shared across all potential readers or views. This makes it impossible to have different readers with different aggregation configurations (e.g., one reader with a cumulative sum and another with a delta sum for the same counter).

## 3. Proposed Architecture

The new architecture will decouple aggregation from the instrument and move it to a new layer managed by the `Meter`. This new layer will be responsible for managing aggregations for each view that applies to an instrument.

### 3.1. Core Concepts

*   **`View`**: A new struct that defines selection criteria (e.g., instrument name, type) and stream configuration (e.g., aggregation type, attribute filter).
*   **`MetricStream`**: A new concept representing a unique combination of an instrument and a view. Each `MetricStream` will have its own set of aggregations, one for each `Reader`.
*   **`Aggregator`**: The new name for the storage of aggregated values. We will introduce an `Aggregator` trait/interface that all aggregations will implement. This will allow for dynamic dispatch of aggregation operations.
*   **`Storage`**: A new component within the `Meter` that maps an instrument to its `MetricStream`s.

### 3.2. Data Flow

1.  When an instrument is created, the `Meter` will consult the registered `View`s on the `MeterProvider`.
2.  For each `View` that matches the instrument, a `MetricStream` is created.
3.  Each `MetricStream` will contain a collection of `Aggregator`s, one for each registered `Reader`.
4.  When an instrument's `add` or `record` method is called, it will not perform any aggregation itself. Instead, it will pass the measurement to the `Meter`'s `Storage`.
5.  The `Storage` will look up the `MetricStream`s for the instrument and forward the measurement to the appropriate `Aggregator` for each `Reader`.
6.  When a `Reader` collects metrics, it will ask the `Meter` for the data from its associated `Aggregator`s.

### 3.3. Performance Considerations

The current implementation uses a mutex for every `add` or `record` operation on an instrument. This is a significant performance bottleneck. The new design will aim to reduce lock contention:

*   **Lock-free data structures**: Where possible, we will use lock-free data structures to pass measurements from application threads to `Reader` collection threads. This could involve using single-producer, single-consumer (SPSC) queues or similar constructs. This would make the `add` and `record` methods on the instruments completely non-blocking.
*   **Atomic operations**: For simple aggregations like `SumAggregation`, we can use atomic operations (`@atomicRmw`) instead of mutexes to update values.
*   **Thread-local storage**: We could explore using thread-local storage to buffer measurements and process them in batches, reducing the frequency of locking or cross-thread communication.

## 4. Implementation Plan

The implementation will be divided into several phases to ensure a smooth transition and allow for testing at each stage.

### Phase 1: Refactor Aggregation (Single Reader)

The first phase will focus on refactoring the aggregation mechanism to support the new architecture, but will initially only support a single reader to simplify the transition.

1.  **Introduce `Aggregator` interface**: Define a common interface for all aggregations (e.g., using a tagged union of function pointers or a `vtable`).
2.  **Create `MetricStream`**: Implement the `MetricStream` struct to hold a single `Aggregator` instance.
3.  **Refactor `Meter`**:
    *   Add a `Storage` component to the `Meter` (e.g., a `HashMap` mapping instrument identifiers to `MetricStream`s).
    *   Modify instrument creation to create `MetricStream`s.
    *   Update `collectMetrics` to read from the new `Storage`.
4.  **Update Instruments**: Remove the `Aggregation` and `mutex` from the instrument structs. Modify `add`/`record` to forward measurements to the `Meter`.
5.  **Ensure existing tests and examples pass**: Run `zig build test` and `zig build examples` to verify that the refactoring has not introduced any regressions.

### Phase 2: Multi-Reader Support

This phase will extend the implementation to support multiple readers with independent aggregation states.

1.  **Update `MetricStream`**: Modify the `MetricStream` to hold a map from `Reader` to `Aggregator`.
2.  **Refactor `MeterProvider`**: Update the `MeterProvider` to manage multiple `Reader`s and their configurations.
3.  **Update `Reader`**: Modify the `Reader` to collect data only from its associated `Aggregator`s.
4.  **Add multi-reader test**: Create a new test case in `src/sdk/metrics/test.zig` with two readers that have different aggregation configurations for the same instrument.
5.  **Add multi-reader example**: Create a new example demonstrating how to configure and use multiple readers.

### Phase 3: View Support

This phase will introduce the `View` functionality, allowing users to customize metric streams.

1.  **Implement `View` struct**: Create the `View` struct with instrument selection criteria and stream configuration parameters as defined in the OpenTelemetry specification.
2.  **Update `MeterProvider`**: Add functionality to register `View`s.
3.  **Update `Meter`**: Modify instrument creation logic to apply registered `View`s when creating `MetricStream`s.
4.  **Add view support test**: Create a test case in `src/sdk/metrics/test.zig` that uses a `View` to:
    *   Drop an instrument.
    *   Change the aggregation of an instrument.
    *   Filter attributes.
    *   Rename an instrument.
5.  **Add view support example**: Create an example demonstrating the use of `View`s.

### Phase 4: Performance and Deadlock Testing

The final phase will focus on ensuring the new implementation is performant and free of deadlocks.

1.  **Performance Test**: Create a benchmark test that measures the throughput of the `add` and `record` methods under high concurrent load. Compare the results with the old implementation to demonstrate improvement.
2.  **Deadlock Test**: Create a stress test that spawns multiple threads to create instruments and record metrics concurrently to ensure no deadlocks or race conditions occur.

## 5. Conclusion

This design provides a clear path to implementing multi-aggregator support and Views in the Zig OpenTelemetry metrics SDK. By decoupling aggregation from instruments and introducing a flexible `MetricStream` concept, we can provide a powerful and customizable metrics experience for users, in line with the OpenTelemetry specification. The phased implementation plan will allow for a controlled rollout with continuous testing, ensuring the stability and correctness of the SDK. The focus on performance and lock-free operations will ensure that the new features do not come at the cost of high overhead.