# Zig Otel

This is a zig implementation of the OTel API and SDK.

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
