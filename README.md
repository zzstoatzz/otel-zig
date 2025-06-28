# Zig Otel

This is a zig implementation of the OTel API and SDK. It was build for zig 0.14.1.

## Quickstart

### Provider Setup
Providers are configured using the `setupGlobalProvider` pattern with pipeline configuration. The setup is consistent across all three signals (logs, metrics, traces) and involves configuring an exporter, processor, resource, and provider implementation:

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Logs setup
const log_provider = try otel_sdk.logs.setupGlobalProvider(
    allocator,
    .{otel_sdk.logs.BasicLogProcessor.PipelineStep.init({})
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

## The API

The API part provides methods for getting and setting Global Providers and the necessary interfaces for using them.

## The SDK

The SDK is structed with subdirectories for `logs`, `metrics`, and `traces`, but they all follow the same general architecture pattern:

```
                    ┌─────────────────┐
                    │   api.Provider  │ (interface)
                    └─────────────────┘
                             △
                             │ implements
                             │
                    ┌─────────────────┐
                    │sdk.StandardProvider│
                    └─────────────────┘
                             │
                             │ uses
                             │
                             ▼
                    ┌─────────────────┐
                    │  sdk.Processor  │ (interface)
                    └─────────────────┘
                             △
                             │ implements
                             │
                    ┌─────────────────┐
                    │sdk.SimpleProcessor│
                    └─────────────────┘
                             │
                             │ uses
                             │
                             ▼
                    ┌─────────────────┐
                    │  sdk.Exporter   │ (interface)
                    └─────────────────┘
                             △
                             │ implements
                             │
                    ┌─────────────────┐
                    │   exporters     │ (module)
                    │   - Console     │
                    │   - OTLP        │
                    │   - etc.        │
                    └─────────────────┘
```

The flow is: Provider → Processor → Exporter, with each component being responsible for a specific part of the telemetry pipeline.
