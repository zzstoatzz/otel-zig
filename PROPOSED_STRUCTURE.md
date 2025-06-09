# Proposed OpenTelemetry Zig Module Structure

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
│   │   │   ├── attributes.zig       # AttributeValue, AttributeKeyValue
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
