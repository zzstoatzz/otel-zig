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
- `zig build example-dns-query-std-log-console` - Run DNS query std.log bridge console example
- `zig build example-dns-query-std-log-otlp` - Run DNS query std.log bridge OTLP example
- `zig build example-metrics` - Run metrics demo
- `zig build example-metrics-histogram` - Run metrics histogram example.
- `zig build example-metrics-otlp` - Run metrics OTLP example
- `zig build example-simple-trace-otlp` - Run simple trace OTLP example

## Running individual files

The commands `zig run` or `zig test` don't use the build system. To use these commands, you must be explicit with the dependencies for what you are trying to do. And you must run them from the project root directory.

The commands work like this `zig (run|test) ((--dep "other-module-name")* -Mthis-module-name)*`. The first module provided is always expected to be the `main` module -- the one you are actually trying to run. Every module you add after that is a dependent module. Each `-Mthis-module-name` needs the `--dep` flags for it's dependencies before it.

For example, to run the debug hang file, you would use this command:

```bash
# For a file that only needs the API:
zig test -Mroot=some_api_test.zig -Motel-api=src/api/root.zig

# For a file that needs API + SDK:
zig test --dep "otel-api" -Mroot=some_sdk_test.zig -Motel-api=src/api/root.zig -Motel-sdk=src/sdk/root.zig

# Complex example
timeout 60s zig run --dep "otel-api" --dep "otel-sdk" --dep "otel-exporters" -Mroot=debug_hang.zig -Motel-api=src/api/root.zig --dep "otel-api" -Motel-sdk=src/sdk/root.zig --dep "otel-api" --dep "otel-sdk" --dep "protobuf" -Motel-exporters=src/exporters/root.zig -Mprotobuf=/Users/jwatson/.cache/zig/p/protobuf-2.0.0-0e82akObGwBZQtrB7Qb6CTWSrwYKRPJ0M4L0CuTJmJ9G/src/protobuf.zig
```

Helpful hints:
- otel-api: doesn't have any dependencies.
- otel-sdk: `--dep "otel-api"`
- otel-exporters: `--dep "otel-api" --dep "otel-sdk"` and protobuf

You can normally find the path to protobuf under the `.cache` directory.

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
- **SDK Layer**: Provides concrete implementations (`BasicLogger`, `BasicLoggerProvider`, `BasicTracerProvider`, etc.)

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

```zig
// AttributeValue variants - note the field names:
const attr_value = AttributeValue{
    .bool = true,           // Boolean values
    .int = 42,              // NOT .int_value - common mistake
    .float = 3.14,          // IEEE 754 double
    .string = "hello",      // Non-owning slice
    .bool_array = &[_]bool{true, false},
    .int_array = &[_]i64{1, 2, 3},
    .float_array = &[_]f64{1.1, 2.2},
    .string_array = &[_][]const u8{"a", "b"},
};

// Creating attributes for spans/logs/metrics:
const attributes = &[_]AttributeKeyValue{
    .{ .key = "service.name", .value = .{ .string = "my-service" } },
    .{ .key = "http.status_code", .value = .{ .int = 200 } },
    .{ .key = "request.timeout", .value = .{ .float = 30.0 } },
    .{ .key = "feature.enabled", .value = .{ .bool = true } },
};
```

**Memory Management**: AttributeValue is non-owning by default. Use `initOwned()` methods when you need to clone string data.

**AttributeBuilder Usage**: For building owned `[]AttributeKeyValue` collections, use `AttributeBuilder`:

```zig
// AttributeBuilder creates owned attribute collections
const owned_attrs = try otel_api.common.AttributeBuilder.init(allocator_for_temp_objects)
    .add("service.name", .{ .string = "my-service" })
    .addInt("http.status_code", 200)
    .addFloat("request.timeout", 30.0)
    .addBool("feature.enabled", true)
    .finish(allocator_for_owned_slice_attribute_key_value);
defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator_for_owned_slice_attribute_key_value, owned_attrs);
```

**Key Benefits**:
- **Functional style**: Method chaining for clean code
- **Type-safe helpers**: `addString()`, `addInt()`, `addFloat()`, `addBool()` methods
- **Deduplication**: Last-wins strategy for duplicate keys
- **Owned memory**: Creates deep copies of all keys and string values
- **Error recovery**: Invalid builders return empty arrays in release mode

Prefer to use `[]AttributeKeyValue` rather than using an ArrayList. Use `AttributeBuilder` when you need owned attribute collections. Prefer the stack based array for un-owned or temporary collections.

### Pipeline System
The SDK uses a pipeline architecture for connecting processors and exporters with proper memory ownership.

```zig
// Pipeline Template Structure:
pub const PipelineStep = PipelineStepInstructions(
    ConcreteType,         // Your implementation (e.g., MyExporter, can often be `@This()`)
    InterfaceType,        // Union interface (e.g., SpanExporter)
    ConfigType,           // Configuration struct (use void if none)
    convertFunction,      // Converts concrete to interface
    initFunction,         // Initializes the concrete type
    connectFunction,      // Handles connection/cleanup
);
```

**Memory Ownership Chain**: Provider → Processor → Exporter
- Provider owns processors, **must** call `processor.deinit()` and `processor.destroy()` in its `deinit()`
- Processor owns exporter, **must** call `exporter.deinit()` and `exporter.destroy()` in its `deinit()`
- Each component cleans up what it was connected to via `.flowTo()`

**Custom Exporter Pattern**:
```zig
const MyExporter = struct {
    pub const PipelineStep = PipelineStepInstructions(
        MyExporter, SpanExporter, MyConfig,
        spanExporter, _init, PipelineDeinitConnection
    );

    pub fn _init(self: *MyExporter, config: MyConfig, allocator: Allocator) !void {
        self.* = init(allocator, config);
    }

    pub fn spanExporter(self: *MyExporter) SpanExporter {
        return SpanExporter{ .bridge = BridgeSpanExporter.init(self) };
    }

    // Standard exporter methods required:
    pub fn exportSpans(...) ExportResult { ... }
    pub fn forceFlush(...) ExportResult { ... }
    pub fn shutdown(...) ExportResult { ... }
    pub fn deinit(self: *MyExporter) void { ... }
    pub fn destroy(self: *MyExporter) void { self.allocator.destroy(self); }
};

// Usage:
.{ProcessorStep.init(config).flowTo(MyExporter.PipelineStep.init(my_config))}
```

### Global Provider Registry
Thread-safe global provider management through `provider_registry.zig` with mutex-protected storage.

#### Provider Setup
Providers are configured using the `setupGlobalProvider` pattern with pipeline configuration. The setup is consistent across all three signals (logs, metrics, traces) and involves configuring an exporter, processor, resource, and provider implementation:

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Logs setup
const log_provider = try otel_sdk.logs.setupGlobalProvider(
    allocator,
    .{otel_sdk.logs.SimpleLogRecordProcessor.PipelineStep.init({})
        .flowTo(otel_exporters.console.ConsoleLogExporter.PipelineStep.init(.{}))},
);
defer {
    log_provider.deinit();
    log_provider.destroy();
}

// Metrics setup
const metric_provider = try otel_sdk.metrics.setupGlobalProvider(
    allocator,
    .{otel_sdk.metrics.BasicMetricProcessor.PipelineStep.init({})
        .flowTo(otel_exporters.otlp.OtlpMetricExporter.PipelineStep.init(.{}))},
);
defer {
    metric_provider.deinit();
    metric_provider.destroy();
}

// Traces setup
const trace_provider = try otel_sdk.trace.setupGlobalProvider(
    allocator,
    .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
        .flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(.{}))},
);
defer {
    trace_provider.deinit();
    trace_provider.destroy();
}

// Get providers from global registry (now backed by SDK)
const scope = try otel_api.InstrumentationScope.initSimple("my.app", "1.0.0");
var logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);
var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);
var tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);
```

This pattern registers providers globally, making them available through the API's global registry functions. The same setupGlobalProvider pattern is used consistently across logs, metrics, and traces.

### Span Lifecycle
Two-phase pattern where `.end()` marks span completion and `.deinit()` handles memory cleanup, following Zig RAII patterns. Spans remain queryable after ending but become non-recording.

## Current State

The logs, metrics, and tracing implementations are complete and architecturally consistent. All three signals use identical patterns for provider setup, pipeline configuration, and memory management.

### Tracing Implementation Status ✅ COMPLETE
- **API Layer**: Complete with bridge pattern and spec-compliant interfaces
- **SDK Layer**: Full implementation complete (BasicTracer, BasicTracerProvider, RecordingSpan)
- **Pipeline Architecture**: Complete with PipelineStep implementations for all components
- **Provider Setup**: Complete with setupGlobalProvider function matching logs/metrics exactly
- **Memory Management**: Two-phase span lifecycle (.end()/.deinit()) with proper cleanup
- **Exporters**: OTLP and console exporters with PipelineStep integration
- **Sampling**: Basic samplers implemented (TraceIdRatioBasedSampler, ParentBasedSampler)
- **Context Integration**: Proper context propagation with explicit span injection
- **Batch Processing**: BatchSpanProcessor implemented with configurable options
- **Architectural Consistency**: All patterns now match logs/metrics exactly

Semantic conventions has not been started.

Exporters are complete for OTLP and console, with full PipelineStep integration and batch processing support.

The examples serve as comprehensive integration tests and demonstrate proper usage patterns for all three signals.

## Testing Utilities

The codebase provides mock implementations for clean, testable code without stderr output or external dependencies.

### MockSpanExporter

Located in `src/sdk/trace/exporter.zig`, provides a test-friendly span exporter that captures exported spans for verification:

```zig
// Initialize mock exporter
const mock_exporter = try allocator.create(MockSpanExporter);
mock_exporter.* = MockSpanExporter.init(allocator);
defer mock_exporter.destroy();

// Use in tests
const processor = try BatchSpanProcessor.init(
    allocator,
    mock_exporter.spanExporter(),
    resource,
    export_interval_ms,
    max_queue_size,
);

// Verify exported data
try testing.expectEqual(@as(usize, 1), mock_exporter.spanCount());
const exported_span = mock_exporter.getSpan(0).?;
```

**Key Methods:**
- `spanCount()` - Number of exported spans
- `getSpan(index)` - Get span by index
- `clearSpans()` - Reset collected spans
- `spanExporter()` - Get SpanExporter interface

### MockErrorHandler

Located in `src/api/common/error_handler.zig`, captures OpenTelemetry errors for verification instead of printing to stderr:

```zig
// Initialize mock error handler
var mock_error_handler = api.common.MockErrorHandler.init(allocator);
defer mock_error_handler.deinit();
api.common.setMockErrorHandler(&mock_error_handler);
defer api.common.clearMockErrorHandler();

// Test code that generates errors...

// Verify captured errors
try testing.expectEqual(@as(usize, 1), mock_error_handler.errorCount());
const error_info = mock_error_handler.getError(0).?;
try testing.expectEqual(api.common.Component.tracer, error_info.component);
try testing.expectEqual(api.common.ErrorType.validation, error_info.error_type);
try testing.expectEqualStrings("Expected error message", error_info.message);
```

**Key Methods:**
- `errorCount()` - Number of captured errors
- `getError(index)` - Get error info by index
- `clearErrors()` - Reset collected errors
- `hasErrorWithMessage(message)` - Check for specific error messages
- `hasErrorWithComponent(component)` - Check for errors from specific components
- `hasErrorWithType(error_type)` - Check for specific error types

**Best Practice:** Always use these mock handlers in tests to keep test output clean and enable verification of error conditions without relying on stderr inspection.

## Local Resources
The OTel specification is in the `spec` directory. A C++ reference implementation is in the `reference/cpp-sdk` directory. The protobuf definitions are in the `opentelemetry-proto` directory.
