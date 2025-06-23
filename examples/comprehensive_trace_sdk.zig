//! Comprehensive Trace SDK Example
//!
//! This example demonstrates advanced usage of the OpenTelemetry Trace SDK
//! implementation in Zig, including multiple span kinds, error handling,
//! concurrent operations, and realistic microservice scenarios.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

const print = std.debug.print;

// Simulate different service components
const ServiceComponent = enum {
    api_gateway,
    user_service,
    order_service,
    database,
    message_queue,
    payment_service,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("🚀 Starting Comprehensive Trace SDK Example\n", .{});
    print("=" ** 50 ++ "\n", .{});

    // Create resource with comprehensive service information
    const resource = try otel_sdk.resource.ResourceBuilder.init(allocator)
        .withDefaults()
        .addKeyValue(.{ .key = "service.name", .value = .{ .string = "comprehensive-trace-demo" } })
        .addKeyValue(.{ .key = "service.version", .value = .{ .string = "2.0.0" } })
        .addKeyValue(.{ .key = "service.namespace", .value = .{ .string = "otel-zig-examples" } })
        .addKeyValue(.{ .key = "deployment.environment", .value = .{ .string = "development" } })
        .addKeyValue(.{ .key = "telemetry.sdk.name", .value = .{ .string = "otel-zig" } })
        .addSchemaUrl("https://opentelemetry.io/schemas/1.21.0")
        .finish(allocator);
    errdefer resource.deinitOwned(allocator);

    // Set up trace provider using the new builder pattern with custom resource
    try otel_sdk.trace.buildProvider(allocator)
        .withExporterClosure(otel_exporters.console.ConsoleExporterConfig{}, otel_exporters.console.createTraceExporterWithConfig)
        .withBasicProcessor()
        .withResource(resource)
        .withBasicProvider()
        .finish();
    defer otel_sdk.trace.destroyProvider();

    var trace_setup = TraceSetup{
        .allocator = allocator,
        .tracer_provider = otel_api.getGlobalTracerProvider(),
    };

    // Run different test scenarios
    try runHttpRequestScenario(&trace_setup);
    try runErrorHandlingScenario(&trace_setup);
    try runMessageQueueScenario(&trace_setup);
    try runConcurrentOperationsScenario(allocator, &trace_setup);
    try runPerformanceTestScenario(&trace_setup);

    print("\n✅ All trace scenarios completed successfully!\n", .{});
    print("Check the console output above for OTLP JSON traces.\n", .{});
}

const TraceSetup = struct {
    allocator: std.mem.Allocator,
    tracer_provider: *otel_api.trace.TracerProvider,
};

fn getTracer(setup: *TraceSetup, component: ServiceComponent) !otel_api.trace.Tracer {
    const component_name = switch (component) {
        .api_gateway => "api-gateway",
        .user_service => "user-service",
        .order_service => "order-service",
        .database => "database-client",
        .message_queue => "message-queue-client",
        .payment_service => "payment-service",
    };

    const scope = try otel_api.InstrumentationScope.initSimple(component_name, "1.0.0");
    return try setup.tracer_provider.getTracerWithScope(scope);
}

fn runHttpRequestScenario(setup: *TraceSetup) !void {
    print("\n📡 HTTP Request Scenario\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const ctx = otel_api.Context.empty(setup.allocator);
    defer ctx.deinit();

    // API Gateway receives request
    var api_tracer = try getTracer(setup, .api_gateway);
    const gateway_result = try api_tracer.startSpan("POST /api/orders", .{
        .kind = .server,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "http.method", .value = .{ .string = "POST" } },
            .{ .key = "http.url", .value = .{ .string = "/api/orders" } },
            .{ .key = "http.scheme", .value = .{ .string = "https" } },
            .{ .key = "http.host", .value = .{ .string = "api.example.com" } },
            .{ .key = "user.id", .value = .{ .string = "user123" } },
            .{ .key = "http.user_agent", .value = .{ .string = "curl/7.68.0" } },
        },
    }, ctx);
    var gateway_span = gateway_result;
    defer gateway_span.deinit();

    try gateway_span.addEvent(otel_api.trace.Event{
        .name = "request.validation.started",
        .timestamp_ns = 0,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "validation.schema_version", .value = .{ .string = "v1.2" } },
        },
    });

    // User service validates user
    var user_tracer = try getTracer(setup, .user_service);
    const user_ctx = try otel_api.trace.trace_context.withActiveSpanContext(ctx, gateway_span.getSpanContext());
    defer user_ctx.deinit();
    const user_result = try user_tracer.startSpan("validate_user", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "user.id", .value = .{ .string = "user123" } },
            .{ .key = "operation.type", .value = .{ .string = "validation" } },
        },
    }, user_ctx);
    var user_span = user_result;
    defer user_span.deinit();

    // Database query in user service
    var db_tracer = try getTracer(setup, .database);
    const db_ctx = try otel_api.trace.trace_context.withActiveSpanContext(ctx, user_span.getSpanContext());
    defer db_ctx.deinit();
    const db_result = try db_tracer.startSpan("SELECT users", .{
        .kind = .client,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "db.system", .value = .{ .string = "postgresql" } },
            .{ .key = "db.name", .value = .{ .string = "users_db" } },
            .{ .key = "db.statement", .value = .{ .string = "SELECT id, email, status FROM users WHERE id = $1" } },
            .{ .key = "db.operation", .value = .{ .string = "SELECT" } },
            .{ .key = "server.address", .value = .{ .string = "db.internal.com" } },
            .{ .key = "server.port", .value = .{ .int = 5432 } },
        },
    }, db_ctx);
    var db_span = db_result;
    defer db_span.deinit();

    // Simulate database work
    std.time.sleep(5 * std.time.ns_per_ms);
    try db_span.setAttribute("db.rows_affected", .{ .int = 1 });
    db_span.end(null);

    try user_span.setAttribute("user.status", .{ .string = "active" });
    user_span.end(null);

    // Order service processes the order
    var order_tracer = try getTracer(setup, .order_service);
    const order_ctx = try otel_api.trace.trace_context.withActiveSpanContext(ctx, gateway_span.getSpanContext());
    defer order_ctx.deinit();
    const order_result = try order_tracer.startSpan("create_order", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "order.type", .value = .{ .string = "standard" } },
            .{ .key = "order.item_count", .value = .{ .int = 3 } },
            .{ .key = "order.total_amount", .value = .{ .float = 99.99 } },
        },
    }, order_ctx);
    var order_span = order_result;
    defer order_span.deinit();

    try order_span.addEvent(otel_api.trace.Event{
        .name = "inventory.check",
        .timestamp_ns = 0,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "inventory.available", .value = .{ .bool = true } },
        },
    });

    try order_span.setAttribute("order.id", .{ .string = "order_789" });
    order_span.end(null);

    // Complete gateway span
    try gateway_span.setAttribute("http.status_code", .{ .int = 201 });
    try gateway_span.setAttribute("http.response.size", .{ .int = 156 });
    try gateway_span.setStatus(otel_api.trace.Status.ok("Order created successfully"));
    gateway_span.end(null);

    print("✅ HTTP request scenario completed\n", .{});
}

fn runErrorHandlingScenario(setup: *TraceSetup) !void {
    print("\n❌ Error Handling Scenario\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const ctx = otel_api.Context.empty(setup.allocator);
    defer ctx.deinit();

    // Start a payment processing operation that will fail
    var payment_tracer = try getTracer(setup, .payment_service);
    const payment_result = try payment_tracer.startSpan("process_payment", .{
        .kind = .server,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "payment.method", .value = .{ .string = "credit_card" } },
            .{ .key = "payment.amount", .value = .{ .float = 299.99 } },
            .{ .key = "payment.currency", .value = .{ .string = "USD" } },
            .{ .key = "customer.id", .value = .{ .string = "cust456" } },
        },
    }, ctx);
    var payment_span = payment_result;
    defer payment_span.deinit();

    // Card validation sub-operation
    const validation_ctx = try otel_api.trace.trace_context.withActiveSpanContext(ctx, payment_span.getSpanContext());
    defer validation_ctx.deinit();
    const validation_result = try payment_tracer.startSpan("validate_card", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "card.type", .value = .{ .string = "visa" } },
            .{ .key = "card.last_four", .value = .{ .string = "1234" } },
        },
    }, validation_ctx);
    var validation_span = validation_result;
    defer validation_span.deinit();

    // Simulate validation failure
    try validation_span.addEvent(otel_api.trace.Event{
        .name = "validation.failed",
        .timestamp_ns = 0,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "error.type", .value = .{ .string = "invalid_card" } },
            .{ .key = "error.message", .value = .{ .string = "Card has expired" } },
        },
    });

    try validation_span.setStatus(otel_api.trace.Status.err("Card validation failed: expired"));
    try validation_span.setAttribute("validation.result", .{ .string = "failed" });
    validation_span.end(null);

    // Parent span also fails
    try payment_span.addEvent(otel_api.trace.Event{
        .name = "payment.declined",
        .timestamp_ns = 0,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "decline.reason", .value = .{ .string = "expired_card" } },
            .{ .key = "retry.allowed", .value = .{ .bool = true } },
        },
    });

    try payment_span.setAttribute("payment.status", .{ .string = "declined" });
    try payment_span.setStatus(otel_api.trace.Status.err("Payment declined due to expired card"));
    payment_span.end(null);

    print("✅ Error handling scenario completed\n", .{});
}

fn runMessageQueueScenario(setup: *TraceSetup) !void {
    print("\n📨 Message Queue Scenario\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const ctx = otel_api.Context.empty(setup.allocator);
    defer ctx.deinit();

    var mq_tracer = try getTracer(setup, .message_queue);

    // Producer: Send message to queue
    const producer_result = try mq_tracer.startSpan("order.created", .{
        .kind = .producer,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "messaging.system", .value = .{ .string = "rabbitmq" } },
            .{ .key = "messaging.destination.name", .value = .{ .string = "order.events" } },
            .{ .key = "messaging.destination.kind", .value = .{ .string = "queue" } },
            .{ .key = "messaging.operation", .value = .{ .string = "publish" } },
            .{ .key = "messaging.message.id", .value = .{ .string = "msg_12345" } },
            .{ .key = "messaging.message.payload_size_bytes", .value = .{ .int = 512 } },
        },
    }, ctx);
    var producer_span = producer_result;
    defer producer_span.deinit();

    try producer_span.addEvent(otel_api.trace.Event{
        .name = "message.queued",
        .timestamp_ns = 0,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "serialization.format", .value = .{ .string = "json" } },
        },
    });

    try producer_span.setAttribute("messaging.message.envelope.size", .{ .int = 587 });
    producer_span.end(null);

    // Simulate message transmission delay
    std.time.sleep(2 * std.time.ns_per_ms);

    // Consumer: Process message from queue
    const consumer_result = try mq_tracer.startSpan("order.created", .{
        .kind = .consumer,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "messaging.system", .value = .{ .string = "rabbitmq" } },
            .{ .key = "messaging.destination.name", .value = .{ .string = "order.events" } },
            .{ .key = "messaging.destination.kind", .value = .{ .string = "queue" } },
            .{ .key = "messaging.operation", .value = .{ .string = "receive" } },
            .{ .key = "messaging.message.id", .value = .{ .string = "msg_12345" } },
        },
    }, ctx);
    var consumer_span = consumer_result;
    defer consumer_span.deinit();

    // Message processing
    const processing_ctx = try otel_api.trace.trace_context.withActiveSpanContext(ctx, consumer_span.getSpanContext());
    defer processing_ctx.deinit();
    const processing_result = try mq_tracer.startSpan("process_order_event", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "event.type", .value = .{ .string = "order.created" } },
            .{ .key = "processing.handler", .value = .{ .string = "OrderEventHandler" } },
        },
    }, processing_ctx);
    var processing_span = processing_result;
    defer processing_span.deinit();

    try processing_span.addEvent(otel_api.trace.Event{
        .name = "order.processing.started",
        .timestamp_ns = 0,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "inventory.change", .value = .{ .int = -3 } },
        },
    });

    processing_span.end(null);
    try consumer_span.setAttribute("processing.result", .{ .string = "success" });
    consumer_span.end(null);

    print("✅ Message queue scenario completed\n", .{});
}

fn runConcurrentOperationsScenario(allocator: std.mem.Allocator, setup: *TraceSetup) !void {
    print("\n🔄 Concurrent Operations Scenario\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const ctx = otel_api.Context.empty(setup.allocator);
    defer ctx.deinit();

    // Simulate concurrent database operations
    var api_tracer = try getTracer(setup, .api_gateway);
    const batch_result = try api_tracer.startSpan("batch_user_lookup", .{
        .kind = .server,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "batch.size", .value = .{ .int = 3 } },
            .{ .key = "batch.type", .value = .{ .string = "user_lookup" } },
        },
    }, ctx);
    var batch_span = batch_result;
    defer batch_span.deinit();

    // Create multiple concurrent database operations
    const user_ids = [_][]const u8{ "user001", "user002", "user003" };
    var db_tracer = try getTracer(setup, .database);

    for (user_ids, 0..) |user_id, i| {
        const query_name = try std.fmt.allocPrint(allocator, "SELECT user {s}", .{user_id});
        defer allocator.free(query_name);

        const query_ctx = try otel_api.trace.trace_context.withActiveSpanContext(ctx, batch_span.getSpanContext());
        defer query_ctx.deinit();
        const db_result = try db_tracer.startSpan(query_name, .{
            .kind = .client,
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "db.system", .value = .{ .string = "postgresql" } },
                .{ .key = "db.statement", .value = .{ .string = "SELECT * FROM users WHERE id = $1" } },
                .{ .key = "user.id", .value = .{ .string = user_id } },
                .{ .key = "query.index", .value = .{ .int = @intCast(i) } },
            },
        }, query_ctx);
        var db_span = db_result;
        defer db_span.deinit();

        // Simulate varying query times
        const sleep_time = (i + 1) * 2 * std.time.ns_per_ms;
        std.time.sleep(sleep_time);

        try db_span.setAttribute("db.rows_affected", .{ .int = 1 });
        try db_span.setAttribute("query.duration_ms", .{ .int = @intCast((i + 1) * 2) });
        db_span.end(null);
    }

    try batch_span.setAttribute("batch.processed", .{ .int = user_ids.len });
    try batch_span.setAttribute("batch.status", .{ .string = "completed" });
    batch_span.end(null);

    print("✅ Concurrent operations scenario completed\n", .{});
}

fn runPerformanceTestScenario(setup: *TraceSetup) !void {
    print("\n⚡ Performance Test Scenario\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const ctx = otel_api.Context.empty(setup.allocator);
    defer ctx.deinit();

    var api_tracer = try getTracer(setup, .api_gateway);
    const perf_result = try api_tracer.startSpan("performance_test", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "test.type", .value = .{ .string = "span_creation_overhead" } },
            .{ .key = "test.iterations", .value = .{ .int = 100 } },
        },
    }, ctx);
    var perf_span = perf_result;
    defer perf_span.deinit();

    const start_time = std.time.milliTimestamp();

    // Create many short-lived spans to test overhead
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        const span_name = "fast_operation";
        const fast_ctx = try otel_api.trace.trace_context.withActiveSpanContext(ctx, perf_span.getSpanContext());
        defer fast_ctx.deinit();
        const fast_result = try api_tracer.startSpan(span_name, .{
            .kind = .internal,
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "iteration", .value = .{ .int = i } },
                .{ .key = "operation.type", .value = .{ .string = "fast" } },
            },
        }, fast_ctx);
        var fast_span = fast_result;
        defer fast_span.deinit();

        // Minimal work
        try fast_span.setAttribute("work.completed", .{ .bool = true });
        fast_span.end(null);
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = end_time - start_time;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    try perf_span.setAttribute("test.duration_ms", .{ .float = duration_ms });
    try perf_span.setAttribute("test.avg_span_creation_ns", .{ .int = @intCast(@divTrunc(duration_ns, 10)) });
    try perf_span.addEvent(otel_api.trace.Event{
        .name = "performance.measurement.completed",
        .timestamp_ns = 0,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "measurement.accuracy", .value = .{ .string = "nanosecond" } },
        },
    });

    perf_span.end(null);

    print("✅ Performance test scenario completed ({}ms for 10 spans)\n", .{duration_ms});
}
