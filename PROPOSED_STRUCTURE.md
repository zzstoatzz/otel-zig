# Proposed OpenTelemetry Zig Module Structure

## Current Structure

```
otel/
├── src/
│   ├── root.zig                  # Main entry point
│   ├── logs.zig                  # Logs API + SDK mixed together
│   ├── logs/
│   │   ├── severity.zig
│   │   ├── log_record.zig
│   │   ├── logger.zig            # Contains both API interface and SDK implementations
│   │   ├── logger_provider.zig   # Contains both API interface and SDK implementations
│   │   └── provider_registry.zig # Global state management
│   ├── trace.zig
│   ├── metrics.zig
│   ├── baggage.zig
│   ├── context.zig
│   ├── resource.zig
│   ├── common.zig
│   └── semconv.zig
├── examples/
└── build.zig
```

## Proposed Structure with API/SDK Separation

```
otel/
├── src/
│   ├── root.zig                     # Re-exports all modules for convenience
│   │
│   ├── api/                         # 🔹 STABLE API MODULE
│   │   ├── root.zig                 # API entry point
│   │   ├── logs/
│   │   │   ├── root.zig             # Re-exports logs API
│   │   │   ├── severity.zig         # Severity enum and utilities
│   │   │   ├── log_record.zig       # LogRecord interface/struct
│   │   │   ├── logger.zig           # Logger interface (tagged union with noop)
│   │   │   ├── logger_provider.zig  # LoggerProvider interface
│   │   │   └── noop.zig             # Noop implementations
│   │   ├── trace/
│   │   │   ├── root.zig
│   │   │   ├── span.zig             # Span interface
│   │   │   ├── tracer.zig           # Tracer interface
│   │   │   ├── tracer_provider.zig  # TracerProvider interface
│   │   │   └── noop.zig
│   │   ├── metrics/
│   │   │   ├── root.zig
│   │   │   ├── meter.zig            # Meter interface
│   │   │   ├── meter_provider.zig   # MeterProvider interface
│   │   │   ├── instruments.zig      # Counter, Gauge, Histogram interfaces
│   │   │   └── noop.zig
│   │   ├── baggage/
│   │   │   ├── root.zig
│   │   │   ├── baggage.zig          # Baggage API
│   │   │   └── entry.zig            # BaggageEntry
│   │   ├── context/
│   │   │   ├── root.zig
│   │   │   ├── context.zig          # Context API
│   │   │   └── propagation.zig      # Propagation interfaces
│   │   ├── common/
│   │   │   ├── root.zig
│   │   │   ├── attributes.zig       # AttributeValue, KeyValue
│   │   │   ├── instrumentation_scope.zig
│   │   │   └── resource.zig         # Resource interface
│   │   └── provider_registry.zig    # Global provider management
│   │
│   ├── sdk/                         # 🔧 SDK IMPLEMENTATIONS
│   │   ├── root.zig                 # SDK entry point
│   │   ├── logs/
│   │   │   ├── root.zig             # Re-exports logs SDK
│   │   │   ├── logger.zig           # Concrete Logger implementations
│   │   │   ├── logger_provider.zig  # Concrete LoggerProvider
│   │   │   ├── processor.zig        # LogProcessor interface
│   │   │   ├── batch_processor.zig  # Batch log processor
│   │   │   ├── simple_processor.zig # Simple log processor
│   │   │   └── exporter.zig         # LogExporter interface
│   │   ├── trace/
│   │   │   ├── root.zig
│   │   │   ├── span.zig             # Concrete Span implementation
│   │   │   ├── tracer.zig           # Concrete Tracer implementation
│   │   │   ├── tracer_provider.zig  # Concrete TracerProvider
│   │   │   ├── span_processor.zig   # SpanProcessor implementations
│   │   │   ├── sampler.zig          # Sampling implementations
│   │   │   └── exporter.zig         # SpanExporter interface
│   │   ├── metrics/
│   │   │   ├── root.zig
│   │   │   ├── meter.zig            # Concrete Meter implementation
│   │   │   ├── meter_provider.zig   # Concrete MeterProvider
│   │   │   ├── instruments.zig      # Concrete instrument implementations
│   │   │   ├── aggregation.zig      # Aggregation logic
│   │   │   ├── reader.zig           # MetricReader implementations
│   │   │   └── exporter.zig         # MetricExporter interface
│   │   ├── resource/
│   │   │   ├── root.zig
│   │   │   ├── resource.zig         # Concrete Resource implementation
│   │   │   └── detector.zig         # Resource detectors
│   │   └── common/
│   │       ├── root.zig
│   │       ├── clock.zig            # Time utilities
│   │       ├── id_generator.zig     # ID generation
│   │       └── config.zig           # SDK configuration
│   │
│   ├── exporters/                   # 🚀 EXPORTERS MODULE
│   │   ├── root.zig                 # Exporters entry point
│   │   ├── console/
│   │   │   ├── root.zig
│   │   │   ├── logs.zig             # Console log exporter
│   │   │   ├── traces.zig           # Console trace exporter
│   │   │   └── metrics.zig          # Console metrics exporter
│   │   ├── otlp/
│   │   │   ├── root.zig
│   │   │   ├── logs.zig             # OTLP log exporter
│   │   │   ├── traces.zig           # OTLP trace exporter
│   │   │   ├── metrics.zig          # OTLP metrics exporter
│   │   │   ├── grpc.zig             # GRPC transport
│   │   │   └── http.zig             # HTTP transport
│   │
│   └── semconv/                     # 📋 SEMANTIC CONVENTIONS (INDEPENDENT)
│       ├── root.zig
│       ├── resource.zig             # Resource semantic conventions
│       ├── trace.zig                # Trace semantic conventions
│       ├── metrics.zig              # Metrics semantic conventions
│       ├── logs.zig                 # Logs semantic conventions
│       └── http.zig                 # HTTP semantic conventions
│
├── examples/
│   ├── api_only.zig                 # Using only the API (noop implementations)
│   ├── sdk_full.zig                 # Full SDK with exporters
│   ├── custom_exporter.zig          # Building custom exporters
│   ├── logging_simple.zig           # Simple logging example
│   └── logging_advanced.zig         # Advanced logging with processors
│
└── build.zig                        # Defines all modules
```

## Module Dependencies

```
┌─────────────┐
│    App      │
└─────┬───────┘
      │
┌─────▼───────┐    ┌───────────────┐
│  otel-api   │    │ otel-semconv  │
│  (stable)   │    │ (independent) │
└─────┬───────┘    └───────────────┘
      │
┌─────▼───────┐
│  otel-sdk   │
│ (implements │
│     API)    │
└─────┬───────┘
      │
┌─────▼───────┐
│otel-exporters│
│(uses SDK)   │
└─────────────┘
```

## Benefits of This Structure

### 1. **Clear Separation of Concerns**
- **API**: Stable interfaces applications depend on
- **SDK**: Concrete implementations that can evolve
- **Exporters**: Pluggable backends for different systems
- **SemConv**: Reusable conventions independent of implementation

### 2. **Flexible Dependency Management**
```zig
// Minimal app - only uses API with noop implementations
const otel_api = @import("otel-api");

// Full observability app
const otel = @import("otel"); // Re-exports everything

// Custom implementation
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
// Implement your own exporters
```

### 3. **Testing Benefits**
- Test API contracts independently
- Test SDK implementations against API interfaces
- Test exporters in isolation
- Easy mocking with noop implementations

### 4. **Performance Benefits**
- Applications can choose minimal dependencies
- Dead code elimination works better with separate modules
- Compile times improve with targeted dependencies

### 5. **Distribution Flexibility**
- Ship API-only packages for libraries
- Ship full SDK for applications
- Third-party exporters can depend only on SDK

## Usage Examples

### Library Author (API Only)
```zig
// In your library's build.zig
const otel_api = b.dependency("otel", .{}).module("otel-api");
lib.root_module.addImport("otel", otel_api);

// In your library code
const otel = @import("otel");
const logger = otel.logs.getGlobalLogger("my.library");
logger.info(ctx, "Library operation completed");
```

### Application Developer (Full SDK)
```zig
// In your app's build.zig  
const otel = b.dependency("otel", .{}).module("otel");
exe.root_module.addImport("otel", otel);

// In your app code
const otel = @import("otel");

// Set up real logging with console exporter
var provider = otel.sdk.logs.createProvider(allocator, .{
    .processor = otel.sdk.logs.createSimpleProcessor(.{}),
    .exporter = otel.exporters.console.createLogExporter(.{}),
});
otel.logs.setGlobalLoggerProvider(provider);
```

### Custom Exporter Developer
```zig
// In build.zig
const otel_api = b.dependency("otel", .{}).module("otel-api");
const otel_sdk = b.dependency("otel", .{}).module("otel-sdk");
lib.root_module.addImport("otel-api", otel_api);
lib.root_module.addImport("otel-sdk", otel_sdk);

// In exporter code
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

pub const MyCustomExporter = struct {
    // Implements otel_sdk.logs.LogExporter interface
    // Can use otel_api types for interop
};
```

## Migration Path

1. **Phase 1**: Reorganize existing code into new directory structure
2. **Phase 2**: Update build.zig to create separate modules  
3. **Phase 3**: Update examples and documentation
4. **Phase 4**: Add new exporters in separate module
5. **Phase 5**: Optimize dependencies and remove circular imports

## Logging-Specific Benefits

For logging specifically, this separation enables:

- **Libraries** can log using just the API (lightweight)
- **Applications** choose their logging backend (console, OTLP, files, etc.)
- **Custom log processors** can be developed independently
- **Log filtering and sampling** can be implemented in the SDK layer
- **Multiple exporters** can be composed together
- **Configuration** is centralized in the SDK layer

This matches the OpenTelemetry specification's intent: stable APIs for instrumentation, flexible SDKs for implementation.