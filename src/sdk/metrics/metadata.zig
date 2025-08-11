//! Metric Metadata for OpenTelemetry Metrics SDK
//!
//! This module provides metadata structures for passing instrument information
//! between components in the metrics pipeline.

const std = @import("std");
const api = @import("otel-api");

/// Instrument type enumeration
pub const InstrumentType = enum {
    Counter,
    UpDownCounter,
    Histogram,
    Gauge,
    ObservableCounter,
    ObservableUpDownCounter,
    ObservableGauge,
};

/// Metadata passed from instrument to reader for aggregation creation
pub const MetricMetadata = struct {
    name: []const u8, // May be transformed by view
    description: []const u8, // May be transformed by view
    unit: []const u8, // From original instrument (not transformable)
    instrument_type: InstrumentType,
    instrumentation_scope: api.InstrumentationScope,

    /// Pre-compute hash of static metadata for efficient lookups
    pub fn computeHash(
        name: []const u8,
        unit: []const u8,
        instrument_type: InstrumentType,
        scope: *const api.InstrumentationScope,
    ) u64 {
        // Use Wyhash for consistent hashing and better collision resistance
        var hasher = std.hash.Wyhash.init(0);

        // Hash name
        hasher.update(name);

        // Hash unit
        hasher.update(unit);

        // Hash instrument type
        const instrument_type_bytes = std.mem.asBytes(&@intFromEnum(instrument_type));
        hasher.update(instrument_type_bytes);

        // Hash scope name
        hasher.update(scope.name);

        // Hash scope version if present
        if (scope.version) |version| {
            hasher.update(version);
        }

        // Hash scope schema URL if present
        if (scope.schema_url) |schema_url| {
            hasher.update(schema_url);
        }

        return hasher.final();
    }

    /// Create MetricMetadata with instrumentation scope
    pub fn init(
        name: []const u8,
        description: []const u8,
        unit: []const u8,
        instrument_type: InstrumentType,
        instrumentation_scope: *const api.InstrumentationScope,
    ) MetricMetadata {
        return .{
            .name = name,
            .description = description,
            .unit = unit,
            .instrument_type = instrument_type,
            .instrumentation_scope = instrumentation_scope,
        };
    }
};

/// Compute a hash for a collection of attributes using the provided seed
///
/// Uses Wyhash for excellent collision resistance and performance.
/// The seed should typically be the instrument's metadata hash to ensure
/// namespace separation between different instruments.
pub fn computeAttributeHash(attributes: []const api.AttributeKeyValue, seed: u64) u64 {
    var hasher = std.hash.Wyhash.init(seed);

    for (attributes) |attr| {
        // Use existing hash methods from API for consistency
        attr.hash(&hasher);
    }

    return hasher.final();
}

test "attribute hash with different seeds" {
    const testing = std.testing;

    const attrs = [_]api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "GET" } },
        .{ .key = "status", .value = .{ .int = 200 } },
    };

    const hash1 = computeAttributeHash(&attrs, 0);
    const hash2 = computeAttributeHash(&attrs, 1);
    const hash3 = computeAttributeHash(&attrs, 12345);

    // Same attributes with different seeds should produce different hashes
    try testing.expect(hash1 != hash2);
    try testing.expect(hash2 != hash3);
    try testing.expect(hash1 != hash3);
}

test "empty attributes hash with seed" {
    const empty_attrs = [_]api.AttributeKeyValue{};

    const hash1 = computeAttributeHash(&empty_attrs, 0);
    const hash2 = computeAttributeHash(&empty_attrs, 42);

    // Empty attributes with different seeds should produce different hashes
    try std.testing.expect(hash1 != hash2);
}

test "single attribute hash with seed" {
    const testing = std.testing;

    const attr = api.AttributeKeyValue{ .key = "test", .value = .{ .string = "value" } };
    const single_attr = [_]api.AttributeKeyValue{attr};

    const hash = computeAttributeHash(&single_attr, 0);

    // Hash should be non-zero for non-empty attributes
    try testing.expect(hash != 0);
}

test "different attributes produce different hashes with same seed" {
    const testing = std.testing;

    const attr1 = [_]api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "GET" } },
    };
    const attr2 = [_]api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "POST" } },
    };
    const attr3 = [_]api.AttributeKeyValue{
        .{ .key = "status", .value = .{ .int = 200 } },
    };

    const seed: u64 = 42;
    const hash1 = computeAttributeHash(&attr1, seed);
    const hash2 = computeAttributeHash(&attr2, seed);
    const hash3 = computeAttributeHash(&attr3, seed);

    // Different attributes should produce different hashes even with same seed
    try testing.expect(hash1 != hash2);
    try testing.expect(hash2 != hash3);
    try testing.expect(hash1 != hash3);
}

test "attribute order affects hash (no longer commutative)" {
    const testing = std.testing;

    const attr1 = api.AttributeKeyValue{ .key = "method", .value = .{ .string = "GET" } };
    const attr2 = api.AttributeKeyValue{ .key = "status", .value = .{ .int = 200 } };
    const attr3 = api.AttributeKeyValue{ .key = "cached", .value = .{ .bool = true } };

    // Test different orderings produce different hashes (order-dependent)
    const order1 = [_]api.AttributeKeyValue{ attr1, attr2, attr3 };
    const order2 = [_]api.AttributeKeyValue{ attr3, attr1, attr2 };
    const order3 = [_]api.AttributeKeyValue{ attr2, attr3, attr1 };

    const seed: u64 = 12345;
    const hash1 = computeAttributeHash(&order1, seed);
    const hash2 = computeAttributeHash(&order2, seed);
    const hash3 = computeAttributeHash(&order3, seed);

    // Different orders should produce different hashes (order-dependent behavior)
    try testing.expect(hash1 != hash2);
    try testing.expect(hash2 != hash3);
    try testing.expect(hash1 != hash3);
}

test "consistent hashing with same attributes and seed" {
    const testing = std.testing;

    const attrs = [_]api.AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "my-service" } },
        .{ .key = "http.status_code", .value = .{ .int = 200 } },
        .{ .key = "request.timeout", .value = .{ .float = 30.0 } },
        .{ .key = "feature.enabled", .value = .{ .bool = true } },
    };

    const seed: u64 = 9876543210;

    // Multiple calls with same input should produce same hash
    const hash1 = computeAttributeHash(&attrs, seed);
    const hash2 = computeAttributeHash(&attrs, seed);
    const hash3 = computeAttributeHash(&attrs, seed);

    try testing.expectEqual(hash1, hash2);
    try testing.expectEqual(hash2, hash3);
}

test "MetricMetadata hash consistency" {
    const testing = std.testing;

    const scope = api.InstrumentationScope{
        .name = "test.scope",
        .version = "1.0.0",
        .schema_url = "https://example.com/schema",
        .attributes = &[_]api.AttributeKeyValue{},
    };

    // Same inputs should produce same hash
    const hash1 = MetricMetadata.computeHash(
        "test.counter",
        "requests",
        InstrumentType.Counter,
        &scope,
    );
    const hash2 = MetricMetadata.computeHash(
        "test.counter",
        "requests",
        InstrumentType.Counter,
        &scope,
    );
    const hash3 = MetricMetadata.computeHash(
        "test.counter",
        "requests",
        InstrumentType.Counter,
        &scope,
    );

    try testing.expectEqual(hash1, hash2);
    try testing.expectEqual(hash2, hash3);
}

test "MetricMetadata hash uniqueness" {
    const testing = std.testing;

    const scope = api.InstrumentationScope{
        .name = "test.scope",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &[_]api.AttributeKeyValue{},
    };

    // Different names
    const hash_name1 = MetricMetadata.computeHash("counter1", "requests", InstrumentType.Counter, &scope);
    const hash_name2 = MetricMetadata.computeHash("counter2", "requests", InstrumentType.Counter, &scope);

    // Different units
    const hash_unit1 = MetricMetadata.computeHash("counter", "requests", InstrumentType.Counter, &scope);
    const hash_unit2 = MetricMetadata.computeHash("counter", "bytes", InstrumentType.Counter, &scope);

    // Different instrument types
    const hash_type1 = MetricMetadata.computeHash("metric", "unit", InstrumentType.Counter, &scope);
    const hash_type2 = MetricMetadata.computeHash("metric", "unit", InstrumentType.Histogram, &scope);

    // All should be different
    try testing.expect(hash_name1 != hash_name2);
    try testing.expect(hash_unit1 != hash_unit2);
    try testing.expect(hash_type1 != hash_type2);
}

test "MetricMetadata hash field sensitivity" {
    const testing = std.testing;

    const base_scope = api.InstrumentationScope{
        .name = "base.scope",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &[_]api.AttributeKeyValue{},
    };

    const base_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.Counter, &base_scope);

    // Test name sensitivity
    const name_hash = MetricMetadata.computeHash("different", "unit", InstrumentType.Counter, &base_scope);
    try testing.expect(base_hash != name_hash);

    // Test unit sensitivity
    const unit_hash = MetricMetadata.computeHash("metric", "different", InstrumentType.Counter, &base_scope);
    try testing.expect(base_hash != unit_hash);

    // Test instrument type sensitivity
    const type_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.Gauge, &base_scope);
    try testing.expect(base_hash != type_hash);

    // Test scope name sensitivity
    const different_scope = api.InstrumentationScope{
        .name = "different.scope",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &[_]api.AttributeKeyValue{},
    };
    const scope_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.Counter, &different_scope);
    try testing.expect(base_hash != scope_hash);
}

test "MetricMetadata hash optional fields" {
    const testing = std.testing;

    // Scope with no optional fields
    const minimal_scope = api.InstrumentationScope{
        .name = "test.scope",
        .version = null,
        .schema_url = null,
        .attributes = &[_]api.AttributeKeyValue{},
    };

    // Scope with version
    const version_scope = api.InstrumentationScope{
        .name = "test.scope",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &[_]api.AttributeKeyValue{},
    };

    // Scope with schema URL
    const schema_scope = api.InstrumentationScope{
        .name = "test.scope",
        .version = null,
        .schema_url = "https://example.com/schema",
        .attributes = &[_]api.AttributeKeyValue{},
    };

    // Scope with both optional fields
    const full_scope = api.InstrumentationScope{
        .name = "test.scope",
        .version = "1.0.0",
        .schema_url = "https://example.com/schema",
        .attributes = &[_]api.AttributeKeyValue{},
    };

    const hash_minimal = MetricMetadata.computeHash("metric", "unit", InstrumentType.Counter, &minimal_scope);
    const hash_version = MetricMetadata.computeHash("metric", "unit", InstrumentType.Counter, &version_scope);
    const hash_schema = MetricMetadata.computeHash("metric", "unit", InstrumentType.Counter, &schema_scope);
    const hash_full = MetricMetadata.computeHash("metric", "unit", InstrumentType.Counter, &full_scope);

    // All should be different
    try testing.expect(hash_minimal != hash_version);
    try testing.expect(hash_minimal != hash_schema);
    try testing.expect(hash_minimal != hash_full);
    try testing.expect(hash_version != hash_schema);
    try testing.expect(hash_version != hash_full);
    try testing.expect(hash_schema != hash_full);
}

test "MetricMetadata hash edge cases" {
    const testing = std.testing;

    const scope = api.InstrumentationScope{
        .name = "test",
        .version = null,
        .schema_url = null,
        .attributes = &[_]api.AttributeKeyValue{},
    };

    // Empty strings
    const empty_name_hash = MetricMetadata.computeHash("", "unit", InstrumentType.Counter, &scope);
    const empty_unit_hash = MetricMetadata.computeHash("metric", "", InstrumentType.Counter, &scope);
    const normal_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.Counter, &scope);

    // Should be different from normal case
    try testing.expect(empty_name_hash != normal_hash);
    try testing.expect(empty_unit_hash != normal_hash);

    // Special characters
    const special_name_hash = MetricMetadata.computeHash("metric!@#$%", "unit", InstrumentType.Counter, &scope);
    const special_unit_hash = MetricMetadata.computeHash("metric", "unit/sec", InstrumentType.Counter, &scope);

    try testing.expect(special_name_hash != normal_hash);
    try testing.expect(special_unit_hash != normal_hash);

    // Very long strings
    const long_name = "very_long_metric_name_that_exceeds_normal_length_expectations_and_tests_hash_behavior";
    const long_unit = "very_long_unit_specification_that_might_cause_issues_with_hash_distribution";
    const long_hash = MetricMetadata.computeHash(long_name, long_unit, InstrumentType.Counter, &scope);

    try testing.expect(long_hash != normal_hash);
}

test "MetricMetadata hash all instrument types" {
    const testing = std.testing;

    const scope = api.InstrumentationScope{
        .name = "test.scope",
        .version = "1.0.0",
        .schema_url = null,
        .attributes = &[_]api.AttributeKeyValue{},
    };

    // Generate hash for each instrument type
    const counter_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.Counter, &scope);
    const updown_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.UpDownCounter, &scope);
    const histogram_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.Histogram, &scope);
    const gauge_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.Gauge, &scope);
    const obs_counter_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.ObservableCounter, &scope);
    const obs_updown_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.ObservableUpDownCounter, &scope);
    const obs_gauge_hash = MetricMetadata.computeHash("metric", "unit", InstrumentType.ObservableGauge, &scope);

    // All should be different
    const hashes = [_]u64{
        counter_hash,
        updown_hash,
        histogram_hash,
        gauge_hash,
        obs_counter_hash,
        obs_updown_hash,
        obs_gauge_hash,
    };

    // Check all pairs are different
    for (hashes, 0..) |hash1, i| {
        for (hashes, 0..) |hash2, j| {
            if (i != j) {
                try testing.expect(hash1 != hash2);
            }
        }
    }
}
