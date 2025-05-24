# Zig Otel

This is a zig implementation of the OTel API.

## Next Steps

### **🥇 EASIEST: Baggage**

**Why it's the simplest:**

```otel/spec/specification/baggage/api.md#L25-50
- Just key-value string pairs (name -> value)
- Immutable container concept
- Only 4 operations: Get, GetAll, Set, Remove
- Leverages existing Context system
- No complex lifecycle management
- No relationships between entries
```

**What needs implementing:**
- `Baggage` struct with string key-value pairs
- Integration with existing `Context` system
- Simple operations (get/set/remove)

### **✅ SECOND: Logs** (COMPLETE)

**Implementation Complete:**
- ✅ `Severity` - Log severity levels with OpenTelemetry standard values
- ✅ `LogRecord` - Non-owning log record structure with all spec fields
- ✅ `LogRecordBuilder` - Builder pattern for constructing log records
- ✅ `Logger` - Logger interface with polymorphic implementations using tagged unions
- ✅ `LoggerProvider` - Factory for creating and managing loggers with caching

**Features:**
- Full OpenTelemetry Logs API implementation
- Idiomatic Zig design with tagged unions instead of vtables
- Efficient memory management with arena allocators
- Type-safe severity levels
- Context integration for trace correlation
- Logger caching by instrumentation scope
- Convenience methods for common logging patterns

**Example Usage:**
```zig
// Create a logger provider
var provider = otel.logs.createStandardProvider(allocator, myHandler);
defer provider.deinit();

// Get a logger
const logger = try provider.getLoggerWithName("my.service");

// Log messages
logger.info(ctx, "User logged in: {s}", .{username});
logger.@"error"(ctx, "Failed to process request: {}", .{err});
```

See `examples/logs/basic_logging.zig` for a complete example.

### **🥉 THIRD: Metrics**

**Why it's moderately complex:**

```otel/spec/specification/metrics/api.md#L45-85
- Multiple instrument types (Counter, Histogram, Gauge, UpDownCounter)
- Synchronous vs Asynchronous patterns
- MeterProvider -> Meter -> Instrument hierarchy
- Different value types (int64, float64)
- But still relatively clean API
```

**What needs implementing:**
- `MeterProvider`, `Meter`
- All instrument types and their specific behaviors
- Synchronous/asynchronous callback patterns

**Estimated effort:** 5-7 days

### **🔴 HARDEST: Tracing**

**Why it's the most complex:**

```otel/spec/specification/trace/api.md#L85-150
- Complex parent-child span relationships
- SpanContext with TraceId/SpanId/TraceFlags/TraceState
- Span lifecycle management (start -> operations -> end)
- Links between spans across traces
- Most stateful signal
- Context propagation is critical
```

**What needs implementing:**
- TraceId, SpanId, TraceFlags, TraceState
- SpanContext propagation
- Span lifecycle and relationships
- TracerProvider -> Tracer -> Span hierarchy

**Estimated effort:** 8-12 days

Implementation Order I Recommend:**
1. **Baggage** (1-2 days) - Immediate foundation
2. **Logs** (3-4 days) - Simple, useful signal
3. **Metrics** (5-7 days) - More complex but well-defined
4. **Tracing** (8-12 days) - Most complex, but others provide learning
