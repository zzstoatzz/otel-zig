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
    ObservableHistogram,
    ObservableGauge,
};

/// Metadata passed from instrument to reader for aggregation creation
pub const MetricMetadata = struct {
    name: []const u8, // May be transformed by view
    description: []const u8, // May be transformed by view
    unit: []const u8, // From original instrument (not transformable)
    instrument_type: InstrumentType,
    meter_name: []const u8,
    meter_version: []const u8,
    meter_schema_url: []const u8,
    metadata_hash: u64, // Pre-computed hash of static metadata

    /// Pre-compute hash of static metadata for efficient lookups
    pub fn computeHash(
        name: []const u8,
        unit: []const u8,
        instrument_type: InstrumentType,
        meter_name: []const u8,
        meter_version: []const u8,
        meter_schema_url: []const u8,
    ) u64 {
        // Use FNV-1a hash algorithm for consistent hashing
        var hash: u64 = 0xcbf29ce484222325; // FNV offset basis
        const prime: u64 = 0x00000100000001B3; // FNV prime

        // Hash name
        for (name) |byte| {
            hash ^= byte;
            hash *%= prime;
        }

        // Hash unit
        for (unit) |byte| {
            hash ^= byte;
            hash *%= prime;
        }

        // Hash instrument type
        hash ^= @intFromEnum(instrument_type);
        hash *%= prime;

        // Hash meter name
        for (meter_name) |byte| {
            hash ^= byte;
            hash *%= prime;
        }

        // Hash meter version
        for (meter_version) |byte| {
            hash ^= byte;
            hash *%= prime;
        }

        // Hash meter schema URL
        for (meter_schema_url) |byte| {
            hash ^= byte;
            hash *%= prime;
        }

        return hash;
    }

    /// Create MetricMetadata with pre-computed hash
    pub fn init(
        name: []const u8,
        description: []const u8,
        unit: []const u8,
        instrument_type: InstrumentType,
        meter_name: []const u8,
        meter_version: []const u8,
        meter_schema_url: []const u8,
    ) MetricMetadata {
        return .{
            .name = name,
            .description = description,
            .unit = unit,
            .instrument_type = instrument_type,
            .meter_name = meter_name,
            .meter_version = meter_version,
            .meter_schema_url = meter_schema_url,
            .metadata_hash = computeHash(name, unit, instrument_type, meter_name, meter_version, meter_schema_url),
        };
    }
};
