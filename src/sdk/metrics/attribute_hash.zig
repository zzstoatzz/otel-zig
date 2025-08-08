//! Attribute Hash Function for OpenTelemetry Metrics SDK
//!
//! This module provides a commutative (order-independent) hash function for
//! attribute key-value pairs, enabling efficient aggregation indexing.

const std = @import("std");
const api = @import("otel-api");

/// Compute a commutative hash for a collection of attributes
///
/// This hash is order-independent, meaning the same attributes in different
/// orders will produce the same hash value. This is achieved by hashing each
/// key-value pair independently and XORing the results.
pub fn computeAttributeHash(attributes: []const api.AttributeKeyValue) u64 {
    // XOR-based commutative hash (order-independent)
    var hash: u64 = 0;

    for (attributes) |attr| {
        // Hash each key-value pair independently
        const pair_hash = hashKeyValuePair(attr);

        // XOR for commutativity (order-independent)
        hash ^= pair_hash;
    }

    return hash;
}

/// Hash a single key-value pair using FNV-1a algorithm
fn hashKeyValuePair(attr: api.AttributeKeyValue) u64 {
    var pair_hash: u64 = 0xcbf29ce484222325; // FNV offset basis
    const prime: u64 = 0x00000100000001B3; // FNV prime

    // Hash the key
    for (attr.key) |byte| {
        pair_hash ^= byte;
        pair_hash *%= prime;
    }

    // Hash the value based on its type
    pair_hash = hashAttributeValue(pair_hash, prime, attr.value);

    return pair_hash;
}

/// Hash an AttributeValue, handling all possible types
fn hashAttributeValue(hash: u64, prime: u64, value: api.AttributeValue) u64 {
    var result_hash = hash;

    switch (value) {
        .string => |s| {
            // Hash string bytes
            for (s) |byte| {
                result_hash ^= byte;
                result_hash *%= prime;
            }
        },
        .bool => |b| {
            // Hash boolean as single byte
            result_hash ^= if (b) @as(u8, 1) else @as(u8, 0);
            result_hash *%= prime;
        },
        .int => |i| {
            // Hash integer bytes
            const bytes = std.mem.asBytes(&i);
            for (bytes) |byte| {
                result_hash ^= byte;
                result_hash *%= prime;
            }
        },
        .float => |f| {
            // Hash float bytes
            const bytes = std.mem.asBytes(&f);
            for (bytes) |byte| {
                result_hash ^= byte;
                result_hash *%= prime;
            }
        },
        .bool_array => |arr| {
            // Hash each boolean in array
            for (arr) |b| {
                result_hash ^= if (b) @as(u8, 1) else @as(u8, 0);
                result_hash *%= prime;
            }
        },
        .int_array => |arr| {
            // Hash each integer in array
            for (arr) |i| {
                const bytes = std.mem.asBytes(&i);
                for (bytes) |byte| {
                    result_hash ^= byte;
                    result_hash *%= prime;
                }
            }
        },
        .float_array => |arr| {
            // Hash each float in array
            for (arr) |f| {
                const bytes = std.mem.asBytes(&f);
                for (bytes) |byte| {
                    result_hash ^= byte;
                    result_hash *%= prime;
                }
            }
        },
        .string_array => |arr| {
            // Hash each string in array
            for (arr) |s| {
                for (s) |byte| {
                    result_hash ^= byte;
                    result_hash *%= prime;
                }
            }
        },
    }

    return result_hash;
}

test "attribute hash is commutative" {
    const testing = std.testing;

    const attr1 = api.AttributeKeyValue{ .key = "method", .value = .{ .string = "GET" } };
    const attr2 = api.AttributeKeyValue{ .key = "status", .value = .{ .int = 200 } };
    const attr3 = api.AttributeKeyValue{ .key = "cached", .value = .{ .bool = true } };

    // Test different orderings produce the same hash
    const order1 = [_]api.AttributeKeyValue{ attr1, attr2, attr3 };
    const order2 = [_]api.AttributeKeyValue{ attr3, attr1, attr2 };
    const order3 = [_]api.AttributeKeyValue{ attr2, attr3, attr1 };

    const hash1 = computeAttributeHash(&order1);
    const hash2 = computeAttributeHash(&order2);
    const hash3 = computeAttributeHash(&order3);

    try testing.expectEqual(hash1, hash2);
    try testing.expectEqual(hash2, hash3);
}

test "empty attributes hash" {
    const empty_attrs = [_]api.AttributeKeyValue{};
    const hash = computeAttributeHash(&empty_attrs);
    try std.testing.expectEqual(@as(u64, 0), hash); // XOR of nothing is 0
}

test "single attribute hash" {
    const testing = std.testing;

    const attr = api.AttributeKeyValue{ .key = "test", .value = .{ .string = "value" } };
    const single_attr = [_]api.AttributeKeyValue{attr};

    const hash = computeAttributeHash(&single_attr);

    // Hash should be non-zero for non-empty attributes
    try testing.expect(hash != 0);
}

test "different attributes produce different hashes" {
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

    const hash1 = computeAttributeHash(&attr1);
    const hash2 = computeAttributeHash(&attr2);
    const hash3 = computeAttributeHash(&attr3);

    // Different attributes should produce different hashes
    try testing.expect(hash1 != hash2);
    try testing.expect(hash2 != hash3);
    try testing.expect(hash1 != hash3);
}
