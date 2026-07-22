# Zig Otel

This is a Zig implementation of the OpenTelemetry API and SDK for Zig 0.16.

## Quickstart

### Provider Setup
Providers are configured using the `setupGlobalProvider` pattern with pipeline configuration. The setup is consistent across all three signals (logs, metrics, traces) and involves configuring an exporter, processor, resource, and provider implementation.

The logging system supports integration with the existing `std.log`, in additional to otel API calls. This example shows both, using the OTLP exporter.

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Clean up global providers at program exit
defer otel_api.provider_registry.unsetAllProviders();

// Setup global OTel logging provider with OTLP exporter
const provider = try otel_sdk.logs.setupGlobalProvider(
    allocator,
    .{otel_sdk.logs.SimpleLogRecordProcessor.PipelineStep.init({})
        .flowTo(otel_exporters.otlp.OtlpLogExporter.PipelineStep.init(.{}))},
);
defer {
    provider.deinit();
    provider.destroy();
}

// Only need this to Initialize the std.log bridge.
try otel_sdk.std_log_bridge.init(.{
    .enabled = true,
    .include_scope_attribute = true,
    .instrumentation_scope_name = "dns.query.std_log.example",
    .instrumentation_scope_version = "1.0.0",
});
defer otel_sdk.std_log_bridge.deinit();

// Now all std.log calls will automatically emit OpenTelemetry log records after the above.
std.log.info("This is really an OTel log.", .{});

// normal otel calls still work too.
const logger_scope = otel_api.InstrumentationScope{ .name = "multiply", .version = "1.0.0" };
var logger = try logger_provider.getLoggerWithScope(logger_scope);
logger.emitLog(
    &.{}, // context
    .info, // log level
    "HTTP server thread started", // log message
    &[_]otel_api.common.AttributeKeyValue{ // attributes.
        .{ .key = "address", .value = .{ .string = shared_state.server_address } },
        .{ .key = "port", .value = .{ .int = @intCast(shared_state.server_port) } },
    },
    null, // event_name
);
```

Metrics setup is very similar, although it doesn't currently support any other integrations.

```zig
// Metrics setup
const concrete_provider = try otel_sdk.metrics.setupGlobalProvider(
    allocator,
    .{otel_sdk.metrics.ManualReader.PipelineStep.init({})
        .flowTo(otel_exporters.otlp.OtlpMetricExporter.PipelineStep.init(.{}))},
);
defer {
    concrete_provider.deinit();
    concrete_provider.destroy();
}

// Get a meter
const scope = otel_api.InstrumentationScope{ .name = "example.metric.otlp", .version = "1.0.0" };
var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);
```

Traces is similar to metrics. This example uses the stream exporter to output to stderr.

```zig
    // Set up trace provider using the new setupGlobalProvider pattern
    var stderr_buffer = [_]u8{0} ** 1024;
    var stderr = otel_exporters.console.initStream(true, &stderr_buffer);
    const concrete_provider = try otel_sdk.trace.setupGlobalProvider(
        allocator,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.stream.SpanDataSink.PipelineStep.init(.{
            .writer = &stderr.interface,
            .flush_after_each = true,
        }))},
    );
    defer {
        concrete_provider.deinit();
        concrete_provider.destroy();
    }

    // Get the global tracer provider interface
    var tp = otel_api.getGlobalTracerProvider();

    // Get a tracer
    const scope = otel_api.InstrumentationScope{ .name = "example-component", .version = "1.0.0" };
    var tracer = try tp.getTracerWithScope(scope);

    // Create a root context
    const ctx = &[_]otel_api.ContextKeyValue{};

    // Start a parent span
    const parent_result = try tracer.startSpan("parent-operation", .{
        .kind = .server,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{
                .key = "http.method",
                .value = otel_api.common.AttributeValue{ .string = "GET" },
            },
            .{
                .key = "http.url",
                .value = otel_api.common.AttributeValue{ .string = "/api/example" },
            },
        },
    }, ctx);
    defer {
        parent_result.end(null);
        parent_result.deinit();
    }
    // do stuff before the span is ended.
```

These examples show the setup of the SDK, but most usages should focus on the APIs exposed from `otel_api.getGlobalTracerProvider()` and similar methods.

### OTLP traces

The trace exporter supports OTLP over HTTP with either protobuf or JSON payloads. Generic collector endpoints preserve any configured base path and append `/v1/traces`; traces-specific endpoints can disable that suffix with `append_signal_path = false`. Custom headers, gzip compression, request timeouts, retry policy, custom certificate authorities, and mutual TLS are applied to real HTTP requests.

Ordinary HTTPS and custom-CA connections use Zig's native TLS client. Zig 0.16's TLS client cannot present client certificates, so configuring both `TlsConfig.cert_file` and `TlsConfig.key_file` selects a dynamically loaded libcurl transport. Applications using mutual TLS therefore need a libcurl 4 runtime; applications that do not configure client credentials have no libcurl link-time or runtime dependency.

Run `scripts/test-mtls.sh` to generate an ephemeral CA and certificates and exercise both transports against real local HTTPS servers, including a server that rejects clients without the generated certificate.

`BatchSpanProcessor` exports bounded batches, wakes as soon as `max_export_batch_size` is reached, and otherwise follows `export_interval_ms`. `forceFlush` observes its timeout while waiting for another export or flush to finish.

OTLP/gRPC transport is not implemented.

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

The flow is: Provider → Processor/Reader → Exporter, with each component being responsible for a specific part of the telemetry pipeline.

## Limitations

- **`trace_state` isn't really handled** -- while the type has room for it, the memory implications of using the trace state have not been worked out; it will leak.
- **No real integration** -- While it is relatively trival to do some context propagation, no integration or simplication with the default zig sdk has been done yet. But an [example is available](examples/multithreaded_http_telemetry.zig) that shows what it would look like right now.
- **A couple of things diverge from the specification** --  That is taken from [a thread from nodejs about OTel](https://github.com/nodejs/node/issues/57992#issuecomment-2844248550). In summary, the spec is to make it easy to rationalize, but it is not the only way to implement the model.
- **Depends on protobuf** -- This SDK depends on [Arwalk's zig-protobuf](https://github.com/Arwalk/zig-protobuf/) for protobuf OTLP payloads.
