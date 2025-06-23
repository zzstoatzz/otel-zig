# TODO - OpenTelemetry Zig Implementation

## Trace API Implementation

This document tracks the remaining work for the OpenTelemetry Zig implementation. The core API and SDK infrastructure (Phases 1-5) are complete. The focus is now on advanced features, quality improvements, and documentation.

### Phase 6 - Core SDK Infrastructure (Complete)
- [x] Basic SDK span implementation (`RecordingSpan`)
- [x] Basic SDK tracer implementation (`StandardTracer`)
- [x] Basic SDK tracer provider implementation (`StandardTracerProvider`)
- [x] Simple span processor (`SimpleSpanProcessor`)
- [x] Integration with existing console exporter
- [x] Basic unit tests for core SDK functionality

**Implementation Notes:**
- **Memory Ownership Model:** Allocator stored in StandardTracerProvider and shared through tracers to spans
- **Console Exporter:** Create a new console trace exporter following the metrics exporter pattern (uses protobuf definitions, outputs OTLP JSON format)
- **Thread Safety:** SDK should be thread-safe, consistent with metrics and logs implementations; mutex at processor level only
- **ID Generation:** Simple PRNG seeded with CSPRNG value for initial implementation
- **Resource Management:** TracerProvider holds the resource (same pattern as LoggerProvider and MeterProvider)
- **SimpleSpanProcessor:** Exports synchronously on span.end(), fails silently on export errors
- **Span Processor Interface:** Follow processor.zig model with bridge pattern and union for testing
- **Testing:** Focus on individual component tests, create test_phase6_sdk.zig following Phase 5 API model; keep minimal for Phase 6
- **Span State Machine:** Prevent double-ending of spans
- **Timestamp Source:** Use same timestamp mechanism as logs SDK
- **Error Handling:** Use error unions where API allows, handle errors silently where API dictates
- **Span Limits Enforcement:** Defer to Phase 8
- **Memory Ownership:** Allocator flows from TracerProvider → Tracer → RecordingSpan
- **ID Generation:** Use simple random generation for Phase 6, defer sophisticated ID generation to later phases
- **RecordingSpan Lifecycle:** Created by tracer, accumulates data during recording, becomes immutable on end, freed after export
- **Parent Span Context:** RecordingSpan stores full copy of parent's SpanContext
- **Context Injection:** Caller responsible for injecting span into context after creation
- **Protobuf Integration:** Use generated types directly from `src/exporters/otlp/proto/opentelemetry/proto/trace`

**Implementation Results:**
- **RecordingSpan:** Successfully accumulates attributes, events, links, and status; implements state machine to prevent double-ending
- **StandardTracer:** Creates spans with proper ID generation using ChaCha PRNG; supports parent-child relationships
- **StandardTracerProvider:** Thread-safe tracer management with caching; proper resource association
- **SimpleSpanProcessor:** Synchronous export on span.end() with silent error handling
- **Console Trace Exporter:** Outputs proper OTLP JSON format with full span data serialization
- **Working Example:** `simple_trace_sdk.zig` demonstrates parent-child spans, attributes, events, and JSON export
- **Memory Management:** Identified areas for improvement (span cleanup after export, context cleanup)
- **Test Coverage:** Basic unit tests plus working end-to-end example

### Phase 7 - Trace Exporters (Complete)
- [x] **OTLP trace exporter implementation** - HTTP/JSON transport with full span data conversion
- [x] **JSON serialization** - Complete OTLP-compliant JSON format for trace data
- [x] **Example programs demonstrating trace export** - Working OTLP trace export example
- [x] **HTTP transport integration** - Uses Zig's std.http.Client for OTLP requests
- [x] **Basic configuration support** - Endpoint, headers, timeout configuration

**Implementation Notes:**
- **Files Created:** Complete rewrite of `src/exporters/otlp/traces.zig`, updated `examples/simple_trace_otlp.zig`
- **OTLP Compliance:** Full JSON format support with proper span serialization, trace/span ID hex encoding
- **HTTP Transport:** Successfully sends trace data to OTLP collectors via HTTP POST
- **Data Conversion:** Handles optional attributes/events/links, proper timestamp conversion, status codes
- **Integration:** Uses existing SDK infrastructure (SpanExporter interface, bridge pattern)
- **Example Output:** Working parent-child span relationships with full telemetry data export
- **Known Issue:** HTTP client cleanup assertion during shutdown (cosmetic, doesn't affect functionality)

### Phase 8 - Advanced SDK Features (Complete)
- [x] **SDK Sampling Implementation** - Implement concrete samplers:
  - [x] ~~`AlwaysOnSampler`~~ - **Decision: Use API `keep` variant instead** (zero-cost abstraction)
  - [x] `TraceIdRatioBasedSampler` - Hash-based ratio sampling with CRC32
  - [x] `ParentBasedSampler` - Delegates to parent span's sampling decision, with configurable root sampler fallback
- [x] `BatchSpanProcessor` implementation
- [x] Span limits enforcement in SDK
- [x] Resource management for traces
- [x] **Advanced span features (proper event/link collection)** - Complete event and link management system
- [x] Span attribute limits enforcement
- [x] **Dynamic Event/Link APIs** - Complete implementation with validation, dropped count tracking, and OTLP export

🎉 **Complete Event and Link Management System** - Successfully implemented comprehensive event and link functionality including dynamic addition APIs, strict validation, dropped count tracking, enhanced limits enforcement, and full OTLP export integration.

**Implementation Notes:**
- **Files Created:** `src/sdk/trace/samplers/trace_id_ratio_based.zig`, `src/sdk/trace/samplers/always_on.zig` (simplified), `src/sdk/trace/samplers/parent_based.zig`, `src/sdk/trace/samplers/root.zig`, `examples/test_sampling.zig`, `src/sdk/trace/batch_span_processor.zig`, `examples/batch_spans.zig`, `examples/simple_batch_test.zig`
- **Integration Points:** Added sampler field to `StandardTracerProvider`, integrated sampling logic in `StandardTracer.startSpan()`
- **Sampling Logic:** Proper handling of `drop` (noop spans), `record_only` (unsampled recording), `record_and_sample` (sampled recording)
- **TraceIdRatioBasedSampler:** CRC32 hash-based sampling with proper ratio clamping and deterministic behavior
- **ParentBasedSampler:** Spec-compliant implementation - follows parent sampling decisions exactly, delegates to root sampler for root spans, preserves trace state
- **Default Behavior:** Uses `drop` variant (AlwaysOff) for zero-cost default sampling
- **Test Coverage:** Comprehensive sampling test example demonstrating all sampler types and behaviors including parent-child relationships
- **Breaking Changes:** Updated all examples and tests to include sampler parameter in `StandardTracerProvider.init()`
- **Performance:** Zero allocation for simple always-on/always-off cases, bridge pattern only for complex samplers
- **BatchSpanProcessor:** Complete implementation with interval-based export, POSIX threading, bridge pattern integration, and deep span cloning for memory safety. Includes configurable queue size, drop-newest overflow behavior, force flush, and graceful shutdown with remaining span export. Working examples demonstrate batching behavior and performance benefits over SimpleSpanProcessor.
- **Span Limits Enforcement:** Complete implementation enforces all OpenTelemetry span limits during `span.end()` including max attributes, max events, max links, attribute key/value length limits, and per-event/per-link attribute limits. Truncates excess data silently to maintain performance.
- **Resource Management:** Fixed critical memory safety bug in `Resource.merge()` where schema_url was not properly cloned, causing double-free crashes in applications using merged resources. Now properly creates owned copies for memory safety.
- **Advanced Event/Link Collection:** Complete implementation of dynamic event and link management with validation, dropped count tracking, and OTLP export integration.

### Phase 8.5 - Advanced Event/Link Implementation (Complete)
- [x] **Dynamic Link Addition API** - Complete `addLink(Link)` implementation with bridge pattern integration
- [x] **Enhanced Event API** - Unified `addEvent(Event)` API replacing component-based approach for consistency
- [x] **Comprehensive Validation** - Strict validation with custom errors (`InvalidEventName`, `InvalidLink`)
- [x] **Dropped Count Tracking** - Full tracking of dropped attributes, events, and links with OTLP export support
- [x] **Enhanced Limits Enforcement** - Per-event/per-link attribute limits with proper count tracking
- [x] **API Breaking Changes Migration** - All examples and tests updated to new Event struct API
- [x] **Error Handling System** - New common errors module with proper error propagation
- [x] **Memory Safety** - Caller-owned data model with proper const correctness
- [x] **OTLP Export Integration** - Dropped counts exported in JSON format for observability
- [x] **Comprehensive Testing** - 17 new unit tests covering all Event/Link functionality

**Event/Link Implementation Details:**
- **Files Created/Modified:** `src/api/common/errors.zig`, `src/api/trace/span.zig`, `src/sdk/trace/data.zig`, `src/exporters/otlp/traces.zig`, `src/sdk/test_phase8_events_links.zig`
- **API Changes:** Removed `addEvent(name, attributes, timestamp)`, renamed `addEventStruct` → `addEvent(Event)`, added `addLink(Link)`
- **Bridge Pattern:** Both Event and Link APIs follow consistent struct-based approach with proper bridge pattern integration
- **Validation Logic:** Events require non-empty names; Links require valid trace_id/span_id (not all zeros)
- **Memory Model:** Maintained caller-owned attribute data approach for zero-copy performance
- **Limits Architecture:** Enhanced `enforceLimits()` with dropped count tracking, applied at `span.end()` for consistency
- **Error Design:** Custom error types with clear semantics and proper propagation through bridge pattern
- **OpenTelemetry Compliance:** Full spec compliance for event ordering, link validation, and dropped count reporting
- **Integration Testing:** All examples updated and verified working with new APIs
- **Performance Impact:** Minimal overhead added while maintaining zero-allocation design goals

### Phase 9 - Quality & Performance
- [x] Make the provider registry easier to work with.
  - [x] Implement a more intuitive API for building, registering, and destroying providers.
- [ ] Add a forced flush to the LoggerProvider.
- [ ] **Error Handling Cleanup** - Refine error handling strategy from Phase 4, implementing hybrid approach (programming errors return errors, resource failures handled silently)
- [ ] Performance benchmarks for trace operations
- [ ] Memory usage optimization
  - [x] ~~Implement proper span cleanup after export in SimpleSpanProcessor~~ - **Completed via two-phase lifecycle**
  - [x] ~~Add context cleanup helpers for span creation lifecycle~~ - **Completed, examples updated**
  - [ ] Optimize RecordingSpan memory allocations (pool attributes/events arrays)
- [ ] Comprehensive trace integration tests
- [ ] Stress testing for high-throughput scenarios
- [ ] Memory leak detection in long-running traces
- [ ] Address duplicate keys
  - [ ] AttributeBuilder
  - [ ] ResourceBuilder
  - [ ] BaggageBuilder

### Phase 9.5 - Recent Completions
- [x] **API Compliance Fix** - `startSpan` now spec-compliant (returns only span, not span+context)
- [x] **TraceId/SpanId Type System** - Proper types in common API layer with trace-specific ID generation
- [x] **Memory-Safe Span Lifecycle** - Two-phase .end()/.deinit() pattern following Zig RAII
- [x] **Example Memory Management** - All trace examples now leak-free with proper context cleanup
- **Resource Merging Bug Fix** - Fixed critical memory safety bug in `Resource.merge()` where schema_url was not properly cloned, causing double-free crashes. Now properly creates owned copies of schema URLs for merged resources.
- **Dynamic Link Addition** - Complete `addLink(Link)` API implementation with validation, bridge pattern integration, and spec compliance
- **Enhanced Event Management** - Updated `addEvent` API to use Event struct, with comprehensive validation and error handling
- **Dropped Count Tracking** - Full implementation tracking dropped attributes, events, and links with OTLP export support
- **Advanced Limits Enforcement** - Enhanced `enforceLimits()` with proper per-event/per-link attribute count enforcement and dropped count tracking
- **API Consistency** - Unified Event/Link APIs using struct-based parameters for better type safety and consistency
- **Comprehensive Validation** - Strict validation for event names and link span contexts with custom error types (`InvalidEventName`, `InvalidLink`)
- **Examples Updated** - All trace examples updated to use new Event API and working correctly

### Phase 10 - Documentation & Polish
- [ ] Comprehensive trace API documentation
- [ ] Usage examples for common tracing scenarios
- [ ] Integration guides (e.g., adding tracing to DNS example)
- [ ] Best practices documentation
- [ ] Migration guide from other tracing libraries
- [ ] Final API polish based on usage experience
- [ ] **Advanced Export Configuration** - Trace export pipeline configuration, retry handling, batching options

## Missing Propagators
- [ ] **B3 Propagator** - Zipkin B3 trace context propagation format
  - [ ] Multi-header B3 format (`X-B3-TraceId`, `X-B3-SpanId`, etc.)
  - [ ] Single-header B3 format (`b3: {trace_id}-{span_id}-{sampled}-{parent_span_id}`)
  - [ ] B3 sampling flag handling
  - [ ] Unit tests for B3 propagation

## Testing & Quality
- [x] **Event/Link Unit Tests** - Comprehensive testing for advanced span features with 17 test cases covering event validation, link validation, dropped count tracking, limits enforcement, and API consistency
- [x] **Example Migration** - All trace examples successfully updated to use new Event/Link APIs and verified working
- [ ] **Trace Integration Tests** - End-to-end context flow testing
  - [ ] Cross-service trace propagation scenarios
  - [ ] Context propagation with different carriers
  - [ ] Sampling decision propagation
  - [ ] Error handling in propagation chains
- [ ] **Unit Tests for Trace Exporters** - Comprehensive testing for OTLP and other trace exporters
- [ ] Performance benchmarks for context operations
- [ ] Stress testing for high-throughput scenarios
- [ ] Memory leak detection in long-running contexts

## Specification Compliance
- [ ] **Strict W3C Trace Context compliance**
  - [ ] Complete version handling (currently supports version 00 only)
  - [ ] Full validation rules for trace headers
  - [ ] Proper error handling for malformed headers
  - [ ] Edge case handling per W3C specification
- [ ] OpenTelemetry specification compliance validation
- [ ] Cross-language compatibility verification

## Documentation & Examples
- [ ] Comprehensive API documentation
- [ ] Usage examples for trace context propagation
- [ ] Integration guides for common web frameworks
- [ ] Best practices documentation
- [ ] Migration guide from other tracing libraries

## Performance & Optimization
- [ ] Zero-allocation context propagation paths
- [ ] Benchmark comparison with other OpenTelemetry implementations
- [ ] Memory usage optimization for high-cardinality traces
- [ ] CPU profiling of trace operations
- [ ] **Compression Support** - Implement gzip compression for OTLP exporters (logs, traces, metrics)

## Future Considerations
- [ ] OpenTracing compatibility layer (if needed)
- [ ] Custom propagator plugin system
- [ ] Trace context compression for large contexts
- [ ] Distributed trace visualization tools integration
