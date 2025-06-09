# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- `zig build example-metrics-otlp` - Run metrics OTLP demo

## Architecture Overview

This is a Zig implementation of the OpenTelemetry API and SDK following the official OpenTelemetry specification. The codebase is structured with clear separation between API interfaces and SDK implementations.

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
- **Bridge Types**: Enable SDK implementations to plug into API interfaces
- **SDK Layer**: Provides concrete implementations (`StandardLogger`, `StandardLoggerProvider`, etc.)

### Memory Management

All API types are **non-owning** - they hold references, not owned data. Callers are responsible for data lifetime management. The SDK provides owned variants when needed.

## Key Patterns

### Instrumentation Scope
Every logger/meter/tracer has an associated `InstrumentationScope` that identifies the instrumentation library (name, version, schema_url, attributes).

### Attribute System
- `AttributeValue`: Type-safe union supporting primitives and arrays
- `AttributeKeyValue`: Key-value pairs for metadata
- `AttributeBuilder`: Functional-style builder for attribute collections

### Global Provider Registry
Thread-safe global provider management through `provider_registry.zig` with mutex-protected storage.

## Current State

The logs implementation is fully functional with working examples. The metrics implementation exists but may need refinement. Tracing is planned but not yet implemented.

Key areas mentioned in TODO.md that may need attention:
- Inconsistent KeyValue interfaces across different components
- Memory cleanup in simple setup functions
- API/SDK division clarity in some areas
- Missing unit tests (removed during refactoring)

## Example Usage Pattern

```zig
const otel = @import("otel");

// Create exporter
const exporter = otel.exporters.console.createLogExporter(.{});

// Set up logging with simple synchronous configuration
const logger_provider = try otel.sdk.logs.createSimpleSyncLogging(
    allocator,
    "my-service",
    exporter,
);

// Set as global provider
otel.api.provider_registry.setLoggerProvider(logger_provider);

// Get logger and use it
const logger = otel.api.provider_registry.getLoggerProvider().getLogger(.{
    .name = "example",
});
logger.info("Hello, OpenTelemetry!");
```