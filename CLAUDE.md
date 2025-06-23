# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Versions

The code targets zig version 0.14.1. Because zig prefers structs instead of individual arguments, you need to pass `.{}` as the second argument to `std.debug.print`, event when you aren't formatting any output. You can also often skip the full type name if the destination value is already known; for example, if the method signature was `fn method(v: AttributeValue) void`, you can call it like `method(.{.string = "foo"});`, which allows you to avoid repeating an easily inferred type. The same is true of return statements.

## Build Commands

- `zig build` - Build all libraries and examples
- `zig build test` - Run all unit tests
- `zig build test-api` - Run API-only tests
- `zig build test-sdk` - Run SDK-only tests
- `zig build test-exporters` - Run exporter tests
- `zig build examples` - Build and run all examples
- `zig build example-dns-query` - Run DNS query logging example
- `zig build example-dns-query-otlp` - Run DNS query OTLP example
- `zig build example-metrics` - Run metrics demo
- `zig build example-metrics-histogram` - Run metrics histogram example.
- `zig build example-metrics-otlp` - Run metrics OTLP example
- `zig build example-simple-trace-otlp` - Run simple trace OTLP example

## Architecture Overview

This is a Zig implementation of the OpenTelemetry API and SDK following the official OpenTelemetry specification. The codebase is structured with clear separation between API interfaces and SDK implementations. The API

### Module Structure

The library is organized into four main modules:

1. **`otel-api`** - Stable API interfaces and no-op implementations (`src/api/`)
2. **`otel-sdk`** - Concrete SDK implementations (`src/sdk/`)
3. **`otel-exporters`** - Telemetry data exporters (`src/exporters/`)
4. **`otel-semconv`** - Semantic conventions (`src/semconv/`)

A convenience `otel` module re-exports everything for simple use cases.

### Provider→Processor→Exporter Flow

The SDK follows the classic OpenTelemetry pattern:

```
Provider (creates loggers/meters/tracers)
    ↓
Processor (processes telemetry records)
    ↓
Exporter (sends data to backends)
```

This pattern is consistent across logs, metrics, and traces (when implemented).

### Bridge Pattern Architecture

The codebase uses a bridge pattern to separate API from SDK:

- **API Layer**: Defines interfaces using tagged unions (`Logger`, `LoggerProvider`, etc.)
- **Bridge Types**: Enable SDK implementations to plug into API interfaces. These are provided in the API layer and use template meta progamming (`LoggerProviderBridge`)
- **SDK Layer**: Provides concrete implementations (`StandardLogger`, `StandardLoggerProvider`, etc.)

### Memory Management

All API types are **non-owning** - they hold references, not owned data. Callers are responsible for data lifetime management. The SDK tries to avoid creating new variants unless required. Usually a cloning method added to the API is sufficient (e.g. `AttributeKeyValue` has `initOwned()`, `initOwnedSlice`, `deinitOwned`, and `deinitOwnedSlice`). Types and collections are usually immutable. A builder should be used when cases of mutability are required (e.g. `AttributeBuilder`).

SDK types have more flexibilty in terms of owning the memory and mutability.

Exporters should copy and own memory when they are buffering or otherwise asyncronously using data.

## Key Patterns

### Resource
Every provider requires a `Resource` when it is created. Always use a `ResourceBuilder` for creating resources instead of manual or stack based constructions.

```zig
// example use builder.
const resource = try ResourceBuilder.init(allocator)
    .withDefaults()
    .finish(allocator);
```

### Instrumentation Scope
Every logger/meter/tracer has an associated `InstrumentationScope` that identifies the instrumentation library (name, version, schema_url, attributes).

### Attribute System
- `AttributeValue`: Type-safe union supporting primitives and arrays
- `AttributeKeyValue`: Key-value pairs for metadata
- `AttributeBuilder`: Functional-style builder for attribute collections

Prefer to use `[]AttributeKeyValue` rather than using an ArrayList.

### Global Provider Registry
Thread-safe global provider management through `provider_registry.zig` with mutex-protected storage.

#### Provider Setup
Providers are configured using a builder pattern with method chaining. The setup typically involves configuring an exporter, processor, resource, and provider implementation:

```zig
// Setup logging provider with console exporter
const exporter_config = otel_exporters.console.ConsoleExporterConfig{};
try otel_sdk.logs.buildProvider(allocator)
    .withExporterClosure(exporter_config, otel_exporters.console.createLogExporterWithConfig)
    .withBasicProcessor()
    .withDefaultResource()
    .withBasicProvider()
    .finish();
defer otel_sdk.logs.destroyProvider();

// Get logger from global registry (now backed by SDK)
const scope = try otel_api.InstrumentationScope.initSimple("my.app", "1.0.0");
var logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);
```

This pattern registers the provider globally, making it available through the API's global registry functions.

### Span Lifecycle
Two-phase pattern where `.end()` marks span completion and `.deinit()` handles memory cleanup, following Zig RAII patterns. Spans remain queryable after ending but become non-recording.

## Current State

The logs and metrics implementations exist but may need refinement. Tracing implementation exists but may need refinement. TODO.md lists some of the ongoing tracing work.

### Tracing Implementation Status
- **API Layer**: Complete with bridge pattern and spec-compliant interfaces
- **SDK Layer**: Core implementation complete (StandardTracer, StandardTracerProvider, RecordingSpan)
- **Memory Management**: Two-phase span lifecycle (.end()/.deinit()) with zero-leak examples
- **Exporters**: OTLP and console exporters functional with JSON serialization
- **Sampling**: Basic samplers implemented (TraceIdRatioBasedSampler, ParentBasedSampler)
- **Context Integration**: Proper context propagation with explicit span injection
- **Remaining Work**: BatchSpanProcessor, advanced features, performance optimization (see TODO.md)

Semantic conventions has not been started.

Exporters have been started for OTLP and console, but are currently in an MVP state, and don't support batching of output.

The examples are useful for integration tests, but still need refinement to be more comprehensive.

## Local Resources
The OTel specification is in the `spec` directory. A C++ reference implementation is in the `reference/cpp-sdk` directory. The protobuf definitions are in the `opentelemetry-proto` directory.
