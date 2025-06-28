# OpenTelemetry Zig Error Handling Guide

A comprehensive guide to error handling, validation, and debugging in the OpenTelemetry Zig implementation.

## Table of Contents

- [Quick Start](#quick-start)
- [Understanding Validation Modes](#understanding-validation-modes)
- [Configuring Error Handlers](#configuring-error-handlers)
- [Performance Considerations](#performance-considerations)
- [Common Patterns](#common-patterns)
- [Troubleshooting](#troubleshooting)
- [API Reference](#api-reference)
- [Advanced Topics](#advanced-topics)

---

## Quick Start

### Basic Setup

```zig
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up custom error handler (optional)
    otel_api.common.setGlobalErrorHandler(myErrorHandler);

    // Set up OpenTelemetry with error handling
    const provider = try otel_sdk.trace.setupGlobalProvider(allocator, pipeline);
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Use OpenTelemetry APIs - validation happens automatically in debug builds
    const scope = try otel_api.InstrumentationScope.initSimple("my-app", "1.0.0");
    var tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);
    
    const ctx = otel_api.Context.init(allocator);
    defer ctx.deinit();
    
    var span = try tracer.startSpan("my-operation", .{}, ctx);
    defer span.deinit();
    
    // These operations are validated in debug mode:
    span.setAttribute("valid.key", .{ .string = "value" }) catch {};
    span.setAttribute("", .{ .string = "invalid key!" }) catch {}; // Reported in debug
    span.end(null);
}

fn myErrorHandler(info: otel_api.common.ErrorInfo, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    // Handle validation errors and other issues
    std.log.warn("OpenTelemetry {s}: {s} - {s}", .{
        @tagName(info.component), info.operation, info.message
    });
}
```

### What You Get

- **Debug builds**: Comprehensive input validation with helpful error messages
- **Release builds**: Zero validation overhead for maximum performance
- **Graceful degradation**: Invalid input never crashes your application
- **Flexible error handling**: Customize how validation errors are handled

---

## Understanding Validation Modes

### Debug Mode (Development)

When compiling with `-ODebug` (default for `zig build`):

```zig
// These are validated and errors reported:
span.setAttribute("", .{ .string = "empty key" });           // ❌ Reported
span.updateName("");                                         // ❌ Reported  
tracer.startSpan("", .{}, ctx);                             // ❌ Reported

// But operations still succeed with safe defaults:
var builder = AttributeBuilder.init(allocator);
builder = builder.add("", .{ .string = "bad" });           // ❌ Builder becomes invalid
const attrs = try builder.finish(allocator);                // ✅ Returns empty array
defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);
```

**Debug Mode Benefits:**
- Catches developer errors early
- Provides detailed error context
- Helps ensure OpenTelemetry spec compliance
- No application crashes - operations continue

### Release Mode (Production)

When compiling with `-OReleaseFast`, `-OReleaseSafe`, or `-OreleaseSmall`:

```zig
// No validation performed - maximum performance:
span.setAttribute("", .{ .string = "empty key" });     // ✅ Passes through
span.updateName("");                                   // ✅ Passes through
tracer.startSpan("", .{}, ctx);                       // ✅ Passes through
```

**Release Mode Benefits:**
- Zero validation overhead
- Maximum telemetry performance
- No error handler calls for validation
- Smaller binary size

### Checking Current Mode

```zig
if (otel_api.common.isValidatingMode()) {
    std.log.info("Validation is enabled - running in debug mode");
} else {
    std.log.info("Validation is disabled - running in release mode");
}
```

---

## Configuring Error Handlers

### Default Error Handler

By default, OpenTelemetry logs validation errors to stderr:

```
[OpenTelemetry Error] Component: tracer, Operation: setAttribute, Type: validation, Message: Invalid attribute key provided
```

### Custom Error Handler

```zig
const MyErrorHandler = struct {
    const Self = @This();
    
    fn handle(info: otel_api.common.ErrorInfo, allocator: ?std.mem.Allocator) void {
        switch (info.error_type) {
            .validation => handleValidationError(info),
            .network => handleNetworkError(info),
            .resource_exhausted => handleResourceError(info),
            else => handleGenericError(info),
        }
    }
    
    fn handleValidationError(info: otel_api.common.ErrorInfo) void {
        // Log validation errors with context
        std.log.warn("Validation error in {s}.{s}: {s}", .{
            @tagName(info.component), info.operation, info.message
        });
        
        if (info.context) |ctx| {
            std.log.warn("Context: {s}", .{ctx});
        }
    }
    
    fn handleNetworkError(info: otel_api.common.ErrorInfo) void {
        // Handle network failures from exporters
        std.log.err("Network error in {s}: {s}", .{
            info.operation, info.message
        });
        
        // Maybe implement retry logic, fallback storage, etc.
    }
    
    fn handleResourceError(info: otel_api.common.ErrorInfo) void {
        // Handle memory/resource exhaustion
        std.log.err("Resource exhaustion in {s}: {s}", .{
            @tagName(info.component), info.message
        });
        
        // Maybe trigger garbage collection, reduce telemetry volume, etc.
    }
    
    fn handleGenericError(info: otel_api.common.ErrorInfo) void {
        std.log.err("OpenTelemetry error: {s} - {s}", .{
            info.operation, info.message
        });
    }
};

// Set the custom handler
otel_api.common.setGlobalErrorHandler(MyErrorHandler.handle);
```

### Conditional Error Handling

```zig
fn smartErrorHandler(info: otel_api.common.ErrorInfo, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    
    // Different handling for different environments
    if (std.debug.mode == .Debug) {
        // Verbose logging in debug
        std.log.warn("[DEBUG] {s}.{s}: {s}", .{
            @tagName(info.component), info.operation, info.message
        });
        if (info.context) |ctx| {
            std.log.warn("Context: {s}", .{ctx});
        }
    } else {
        // Minimal logging in release (if any validation errors occur)
        switch (info.error_type) {
            .network, .timeout => {
                // Only log critical errors in production
                std.log.err("OpenTelemetry connectivity issue: {s}", .{info.message});
            },
            else => {
                // Silent handling of other errors
            },
        }
    }
}
```

### Error Handler Registration

```zig
// Set handler
otel_api.common.setGlobalErrorHandler(myHandler);

// Get current handler
const current = otel_api.common.getGlobalErrorHandler();

// Temporarily override handler
const original = otel_api.common.getGlobalErrorHandler();
otel_api.common.setGlobalErrorHandler(temporaryHandler);
defer otel_api.common.setGlobalErrorHandler(original);

// Remove handler (use default)
otel_api.common.setGlobalErrorHandler(null);
```

---

## Performance Considerations

### Debug Mode Impact

| Operation | Release Mode | Debug Mode | Overhead |
|-----------|-------------|------------|----------|
| `span.setAttribute()` | Direct call | +1 key length check | ~1-2 ns |
| `span.setAttributes()` | Direct call | +validate all keys | ~N ns |
| `tracer.startSpan()` | Direct call | +name & attrs check | ~5-10 ns |
| `AttributeBuilder.add()` | Direct call | +key validation | ~1-2 ns |

### Memory Impact

```zig
// ✅ Good: No extra allocations for validation
span.setAttribute("key", .{ .string = "value" });

// ✅ Good: Validation reports errors but doesn't allocate filtered arrays
const attrs = [_]AttributeKeyValue{
    .{ .key = "valid", .value = .{ .string = "ok" } },
    .{ .key = "", .value = .{ .string = "invalid" } },  // Reported but included
};
span.setAttributes(&attrs);

// ✅ Good: Failed builders return empty arrays, no partial allocations
var builder = AttributeBuilder.init(allocator);
builder = builder.add("", .{ .string = "invalid" });  // Builder becomes invalid
const result = try builder.finish(allocator);          // Returns []AttributeKeyValue{}
defer AttributeKeyValue.deinitOwnedSlice(allocator, result);
```

### Performance Best Practices

1. **Use release builds in production**:
   ```bash
   zig build -Doptimize=ReleaseFast
   ```

2. **Minimize validation overhead in debug**:
   ```zig
   // ✅ Efficient: Single validation call
   span.setAttributes(&many_attributes);
   
   // ❌ Inefficient: Multiple validation calls  
   for (many_attributes) |attr| {
       span.setAttribute(attr.key, attr.value);
   }
   ```

3. **Batch operations when possible**:
   ```zig
   // ✅ Better: Batch attribute setting
   const attrs = try AttributeBuilder.init(allocator)
       .add("service.name", .{ .string = "my-service" })
       .add("service.version", .{ .string = "1.0.0" })
       .finish(allocator);
   defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);
   span.setAttributes(attrs);
   
   // ❌ Less efficient: Individual calls
   span.setAttribute("service.name", .{ .string = "my-service" });
   span.setAttribute("service.version", .{ .string = "1.0.0" });
   ```

---

## Common Patterns

### Application Startup Error Handling

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up error handling first
    setupErrorHandling();

    // Initialize OpenTelemetry with error handling
    const provider = setupOpenTelemetry(allocator) catch |err| {
        std.log.err("Failed to initialize OpenTelemetry: {}", .{err});
        return; // Graceful degradation - continue without telemetry
    };
    defer cleanupOpenTelemetry(provider);

    // Run application
    try runApplication(allocator);
}

fn setupErrorHandling() void {
    if (std.debug.mode == .Debug) {
        // Verbose error handling in debug
        otel_api.common.setGlobalErrorHandler(debugErrorHandler);
    } else {
        // Minimal error handling in release
        otel_api.common.setGlobalErrorHandler(productionErrorHandler);
    }
}

fn setupOpenTelemetry(allocator: std.mem.Allocator) !*otel_sdk.trace.BasicTracerProvider {
    return otel_sdk.trace.setupGlobalProvider(
        allocator,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(.{
                .endpoint = "http://localhost:4318/v1/traces",
            }))},
    );
}
```

### Library Instrumentation Pattern

```zig
// In a library that adds OpenTelemetry instrumentation
const DatabaseClient = struct {
    tracer: otel_api.trace.Tracer,
    
    pub fn query(self: *Self, sql: []const u8, ctx: otel_api.Context) !QueryResult {
        // Create span with validation-safe defaults
        const span_name = if (sql.len > 0) "db.query" else "db.query.unknown";
        var span = try self.tracer.startSpan(span_name, .{
            .kind = .client,
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "db.system", .value = .{ .string = "postgresql" } },
                .{ .key = "db.statement", .value = .{ .string = sql } },
            },
        }, ctx);
        defer span.deinit();
        
        const result = self.executeQuery(sql) catch |err| {
            // Record error without failing if attribute setting fails
            span.setAttribute("error", .{ .bool = true }) catch {};
            span.setAttribute("error.type", .{ .string = @errorName(err) }) catch {};
            span.setStatus(otel_api.trace.Status.err("Query failed")) catch {};
            return err;
        };
        
        // Record success metrics
        span.setAttribute("db.rows_affected", .{ .int = @intCast(result.rows.len) }) catch {};
        span.setStatus(otel_api.trace.Status.ok()) catch {};
        
        return result;
    }
};
```

### Error Recovery Pattern

```zig
const TelemetryService = struct {
    provider: ?*otel_sdk.trace.BasicTracerProvider,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TelemetryService {
        const provider = otel_sdk.trace.setupGlobalProvider(allocator, pipeline) catch |err| {
            std.log.warn("Failed to setup telemetry provider: {}", .{err});
            return TelemetryService{ .provider = null, .allocator = allocator };
        };
        
        return TelemetryService{ .provider = provider, .allocator = allocator };
    }
    
    pub fn createSpan(self: *Self, name: []const u8, ctx: otel_api.Context) otel_api.trace.Span {
        if (self.provider == null) {
            // Return no-op span if telemetry setup failed
            return otel_api.trace.Span{ .noop = otel_api.trace.SpanContext.invalid };
        }
        
        const scope = otel_api.InstrumentationScope.initSimple("service", "1.0.0") catch {
            return otel_api.trace.Span{ .noop = otel_api.trace.SpanContext.invalid };
        };
        
        var tracer = otel_api.getGlobalTracerProvider().getTracerWithScope(scope) catch {
            return otel_api.trace.Span{ .noop = otel_api.trace.SpanContext.invalid };
        };
        
        return tracer.startSpan(name, .{}, ctx) catch {
            return otel_api.trace.Span{ .noop = otel_api.trace.SpanContext.invalid };
        };
    }
};
```

### Validation-Aware AttributeBuilder

```zig
fn buildUserAttributes(allocator: std.mem.Allocator, user: User) ![]otel_api.common.AttributeKeyValue {
    var builder = otel_api.common.AttributeBuilder.init(allocator);
    
    // Safe attribute building with validation
    if (user.id.len > 0) {
        builder = builder.add("user.id", .{ .string = user.id });
    }
    
    if (user.email.len > 0) {
        builder = builder.add("user.email", .{ .string = user.email });
    }
    
    // Role might be empty - let validation handle it
    builder = builder.add("user.role", .{ .string = user.role });
    
    // Check if builder is still valid
    const attrs = try builder.finish(allocator);
    
    // In debug mode, validation errors would have been reported
    // In release mode, all attributes pass through
    return attrs;
}
```

---

## Troubleshooting

### Common Validation Errors

#### Empty Attribute Keys

**Error**: `Invalid attribute key provided`

```zig
// ❌ Problem
span.setAttribute("", .{ .string = "value" });

// ✅ Solution
if (key.len > 0) {
    span.setAttribute(key, .{ .string = "value" });
}
```

#### Empty Span Names

**Error**: `Empty span name provided`

```zig
// ❌ Problem
var span = try tracer.startSpan("", .{}, ctx);

// ✅ Solution
const name = if (operation_name.len > 0) operation_name else "unknown_operation";
var span = try tracer.startSpan(name, .{}, ctx);
```

#### AttributeBuilder Invalid State

**Error**: Builder becomes invalid due to validation or allocation failure

```zig
// ❌ Problem - not checking builder state
var builder = AttributeBuilder.init(allocator);
builder = builder.add("", .{ .string = "invalid" });  // Builder becomes invalid
const attrs = try builder.finish(allocator);          // Returns empty array

// ✅ Solution - defensive building
fn safelyBuildAttributes(allocator: std.mem.Allocator, data: []const KeyValue) ![]AttributeKeyValue {
    var builder = AttributeBuilder.init(allocator);
    
    for (data) |kv| {
        if (kv.key.len > 0) {  // Pre-validate
            builder = builder.add(kv.key, kv.value);
        }
    }
    
    return try builder.finish(allocator);
}
```

### Debugging Validation Issues

#### Enable Verbose Error Logging

```zig
fn debugErrorHandler(info: otel_api.common.ErrorInfo, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    
    std.log.warn("=== OpenTelemetry Validation Error ===");
    std.log.warn("Component: {s}", .{@tagName(info.component)});
    std.log.warn("Operation: {s}", .{info.operation});
    std.log.warn("Error Type: {s}", .{@tagName(info.error_type)});
    std.log.warn("Message: {s}", .{info.message});
    
    if (info.context) |ctx| {
        std.log.warn("Context: {s}", .{ctx});
    }
    
    if (info.source_error) |err| {
        std.log.warn("Source Error: {}", .{err});
    }
    
    std.log.warn("=====================================");
}
```

#### Track Validation Frequency

```zig
const ValidationTracker = struct {
    var validation_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var error_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    
    fn trackingErrorHandler(info: otel_api.common.ErrorInfo, allocator: ?std.mem.Allocator) void {
        _ = allocator;
        
        _ = error_count.fetchAdd(1, .seq_cst);
        
        if (info.error_type == .validation) {
            _ = validation_count.fetchAdd(1, .seq_cst);
        }
        
        // Log periodically
        const total_errors = error_count.load(.seq_cst);
        if (total_errors % 100 == 0) {
            const validation_errors = validation_count.load(.seq_cst);
            std.log.info("OpenTelemetry errors: {} total, {} validation", .{total_errors, validation_errors});
        }
    }
};
```

#### Conditional Validation

```zig
fn conditionalValidation() void {
    if (otel_api.common.isValidatingMode()) {
        std.log.info("Validation is enabled - check error handler logs for issues");
    } else {
        std.log.info("Validation is disabled - running in release mode");
    }
}
```

### Performance Debugging

#### Measure Validation Impact

```zig
fn measureValidationImpact() !void {
    const iterations = 10000;
    
    // Measure with validation
    const start = std.time.nanoTimestamp();
    for (0..iterations) |i| {
        span.setAttribute("test.key", .{ .int = @intCast(i) });
    }
    const validation_time = std.time.nanoTimestamp() - start;
    
    std.log.info("Validation impact: {}ns per operation", .{validation_time / iterations});
}
```

---

## API Reference

### Error Handler Functions

```zig
// Set global error handler
otel_api.common.setGlobalErrorHandler(handler: ?ErrorHandler) void

// Get current global error handler  
otel_api.common.getGlobalErrorHandler() ?ErrorHandler

// Report errors manually
otel_api.common.reportError(info: ErrorInfo) void
otel_api.common.reportValidationError(component: Component, operation: []const u8, message: []const u8, context: ?[]const u8) void

// Check validation mode
otel_api.common.isValidatingMode() bool
```

### Error Types

```zig
const ErrorInfo = struct {
    component: Component,      // Which component reported the error
    operation: []const u8,     // What operation was being performed
    error_type: ErrorType,     // Category of error
    message: []const u8,       // Human-readable description
    context: ?[]const u8,      // Additional context (optional)
    source_error: ?anyerror,   // Original Zig error (optional)
};

const Component = enum {
    tracer, logger, meter, exporter, processor, provider, resource, context, baggage, general
};

const ErrorType = enum {
    validation, resource_exhausted, network, serialization, configuration, timeout, authentication, internal, unknown
};
```

---

## Advanced Topics

### Custom Validation Rules

```zig
// Extend validation beyond basic checks
fn validateBusinessRules(attributes: []const AttributeKeyValue) void {
    if (!otel_api.common.isValidatingMode()) return;
    
    for (attributes) |attr| {
        // Custom business logic validation
        if (std.mem.startsWith(u8, attr.key, "internal.")) {
            otel_api.common.reportValidationError(.tracer, "setAttribute", 
                "Internal attributes not allowed in user code", attr.key);
        }
        
        if (std.mem.eql(u8, attr.key, "user.password")) {
            otel_api.common.reportValidationError(.tracer, "setAttribute",
                "Sensitive data should not be in telemetry", null);
        }
    }
}
```

### Error Handler Chaining

```zig
const ErrorHandlerChain = struct {
    handlers: []const ErrorHandler,
    
    fn chainedHandler(info: ErrorInfo, allocator: ?std.mem.Allocator) void {
        const chain = getGlobalChain(); // Your implementation
        for (chain.handlers) |handler| {
            handler(info, allocator);
        }
    }
};
```

### Async Error Handling

```zig
const AsyncErrorHandler = struct {
    queue: std.ArrayList(ErrorInfo),
    mutex: std.Thread.Mutex,
    
    fn queueError(info: ErrorInfo, allocator: ?std.mem.Allocator) void {
        _ = allocator;
        const handler = getAsyncHandler(); // Your implementation
        handler.mutex.lock();
        defer handler.mutex.unlock();
        handler.queue.append(info) catch {}; // Handle queue full
    }
    
    fn processErrorsAsync(self: *AsyncErrorHandler) void {
        // Background thread processes queued errors
        while (true) {
            self.mutex.lock();
            const errors = self.queue.toOwnedSlice() catch continue;
            self.mutex.unlock();
            
            for (errors) |error_info| {
                // Process error asynchronously
                processError(error_info);
            }
            
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }
};
```

---

## Conclusion

The OpenTelemetry Zig error handling system provides:

- **Zero-cost validation** in production builds
- **Comprehensive validation** in debug builds  
- **Flexible error handling** via custom handlers
- **Graceful degradation** that never crashes applications
- **OpenTelemetry spec compliance** with developer-friendly validation

By following the patterns in this guide, you can build robust, observable applications that provide excellent debugging information during development while maintaining optimal performance in production.

For more information, see the [API documentation](../src/api/) and [examples](../examples/).