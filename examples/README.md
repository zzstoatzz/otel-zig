# OpenTelemetry Zig Examples

This directory contains example programs demonstrating the OpenTelemetry Zig implementation across different telemetry signals (logs, metrics, traces).

## Examples Overview

### Logging Examples
- `dns_query_logging.zig` - Basic DNS query with structured logging
- `dns_query_logging_otlp.zig` - DNS query logging with OTLP export

### Metrics Examples
- `metrics_demo.zig` - Basic metrics demonstration with console export
- `metrics-histogram.zig` - Histogram metrics with console export
- `metrics_histogram_otlp.zig` - Histogram metrics with OTLP export
- `metrics_periodic.zig` - Periodic metrics collection demonstration

### Tracing Examples
- `simple_trace_sdk.zig` - Basic trace SDK demonstration
- `comprehensive_trace_sdk.zig` - **Advanced trace SDK showcase** (detailed below)

## Comprehensive Trace SDK Example

The `comprehensive_trace_sdk.zig` example is a comprehensive demonstration of the OpenTelemetry Trace SDK capabilities, simulating realistic microservice scenarios.

### Features Demonstrated

#### 1. HTTP Request Scenario 📡
Simulates a complete web service request flow:
- **API Gateway** (SERVER span) - receives POST /api/orders request
- **User Service** (INTERNAL span) - validates user credentials  
- **Database Query** (CLIENT span) - PostgreSQL user lookup
- **Order Service** (INTERNAL span) - processes order creation

**Key Features:**
- Parent-child span relationships with proper trace/span ID propagation
- HTTP semantic conventions (method, URL, status codes, user agent)
- Database semantic conventions (system, statement, operation)
- Span events (request validation, inventory checks)
- Success status with custom messages

#### 2. Error Handling Scenario ❌
Demonstrates proper error handling and status reporting:
- **Payment Service** (SERVER span) - processes payment request
- **Card Validation** (INTERNAL span) - validates credit card (fails)

**Key Features:**
- Error status codes (Status.err) with descriptive messages
- Error events with structured error information
- Proper error attribute propagation from child to parent spans
- Realistic payment processing failure scenarios

#### 3. Message Queue Scenario 📨
Shows asynchronous messaging patterns:
- **Producer** (PRODUCER span) - publishes order.created event to RabbitMQ
- **Consumer** (CONSUMER span) - receives and processes the message
- **Event Processing** (INTERNAL span) - handles the order event

**Key Features:**
- Messaging semantic conventions (system, destination, operation)
- Message metadata (message ID, payload size, envelope size)
- Producer/Consumer span kinds for proper distributed tracing
- Event processing with inventory updates

#### 4. Concurrent Operations Scenario 🔄
Demonstrates batch processing and concurrent operations:
- **Batch Operation** (SERVER span) - coordinates multiple user lookups
- **Multiple Database Queries** (CLIENT spans) - concurrent user queries

**Key Features:**
- Sequential processing simulation with variable timing
- Batch operation metadata (size, type, status)
- Individual operation tracking within batch context
- Performance metrics for each query

#### 5. Performance Test Scenario ⚡
Tests trace SDK performance characteristics:
- **Performance Test** (INTERNAL span) - measures span creation overhead
- **Fast Operations** (INTERNAL spans) - rapid span creation/completion

**Key Features:**
- High-frequency span creation (10 operations)
- Performance measurement and reporting
- Nanosecond precision timing
- Average span creation time calculation

### Running the Example

```bash
# Build and run the comprehensive trace example
zig build example-comprehensive-trace-sdk

# Build and run all examples
zig build examples
```

### Output Format

The example exports traces in **OTLP JSON format** to the console. Each trace contains:

- **Resource attributes** - Service identification and metadata
- **Instrumentation scope** - Component that created the spans  
- **Span data** - Timing, attributes, events, status, and relationships

Example trace output:
```json
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "comprehensive-trace-demo"}},
        {"key": "service.version", "value": {"stringValue": "2.0.0"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "api-gateway"},
      "spans": [{
        "traceId": "75caf3f8fdf922c34fbbab35aec8f13f",
        "spanId": "e5b6473f7b154271",
        "name": "POST /api/orders",
        "kind": 2,
        "startTimeUnixNano": "1750411730698338000",
        "endTimeUnixNano": "1750411730705341000",
        "attributes": [
          {"key": "http.method", "value": {"stringValue": "POST"}},
          {"key": "http.status_code", "value": {"intValue": "201"}}
        ],
        "events": [{
          "name": "request.validation.started",
          "attributes": [{"key": "validation.schema_version", "value": {"stringValue": "v1.2"}}]
        }],
        "status": {"code": 1, "message": "Order created successfully"}
      }]
    }]
  }]
}
```

### Technical Highlights

#### OpenTelemetry Compliance
- Full **OpenTelemetry specification** compliance
- Proper **semantic conventions** for HTTP, database, and messaging
- **W3C Trace Context** propagation (trace ID, span ID, parent relationships)

#### Span Relationships
- **Parent-child relationships** - Child spans reference parent span IDs
- **Trace correlation** - All related spans share the same trace ID
- **Context propagation** - Proper context passing between service boundaries

#### Performance Characteristics
- **Zero-allocation** design for span operations (where possible)
- **Efficient OTLP JSON export** using protobuf-generated types
- **Nanosecond precision** timing for accurate performance measurement

#### Memory Management
- **Caller-owned memory model** - Application manages attribute/event memory
- **Automatic resource cleanup** - Proper deinitialization of SDK components
- **Allocator-based design** - Consistent memory management patterns

### Integration Testing

This example serves as an integration test for the trace SDK, validating:

- ✅ **Span creation and lifecycle management**
- ✅ **Attribute and event addition** 
- ✅ **Status setting (OK and Error states)**
- ✅ **Parent-child span relationships**
- ✅ **Context propagation between spans**
- ✅ **Multiple span kinds** (SERVER, CLIENT, INTERNAL, PRODUCER, CONSUMER)
- ✅ **OTLP JSON export format**
- ✅ **Resource and instrumentation scope metadata**
- ✅ **High-frequency span creation** (performance testing)
- ✅ **Error handling and status reporting**

### Next Steps

This comprehensive example demonstrates that the OpenTelemetry Zig trace SDK Phase 6 implementation is **fully functional** and ready for:

1. **Real-world application integration**
2. **Additional exporter development** (OTLP gRPC, Jaeger, Zipkin)
3. **Advanced sampling strategies**
4. **Batch span processing**
5. **Performance optimization**

The trace SDK successfully provides all the core functionality needed for distributed tracing in Zig applications! 🎉