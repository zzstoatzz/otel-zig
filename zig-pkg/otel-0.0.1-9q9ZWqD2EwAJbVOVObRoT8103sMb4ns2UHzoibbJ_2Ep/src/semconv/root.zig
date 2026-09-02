//! OpenTelemetry Semantic Conventions
//!
//! This module provides standardized attribute names and values according to
//! the OpenTelemetry semantic conventions. These conventions ensure consistent
//! naming across different implementations and languages.
//!
//! ## Overview
//! Semantic conventions define standard names for:
//! - Resource attributes (service, host, process, etc.)
//! - Trace attributes (HTTP, database, messaging, etc.)
//! - Metric instruments and attributes
//! - Log attributes and event names
//!
//! ## Usage
//! ```zig
//! const semconv = @import("otel-semconv");
//! 
//! // Use standard attribute names
//! resource.addAttribute(semconv.resource.SERVICE_NAME, "my-service");
//! resource.addAttribute(semconv.resource.SERVICE_VERSION, "1.0.0");
//! 
//! // Use standard HTTP attributes
//! span.setAttribute(semconv.trace.HTTP_METHOD, "GET");
//! span.setAttribute(semconv.trace.HTTP_STATUS_CODE, 200);
//! ```
//!
//! ## Stability
//! Semantic conventions may be:
//! - **Stable**: Guaranteed not to change
//! - **Experimental**: May change in future versions
//! 
//! This module follows the OpenTelemetry semantic conventions specification:
//! https://github.com/open-telemetry/opentelemetry-specification/tree/main/specification/semantic-conventions

const std = @import("std");

// Resource semantic conventions
pub const resource = @import("resource.zig");

// Trace semantic conventions
pub const trace = @import("trace.zig");

// Metrics semantic conventions
pub const metrics = @import("metrics.zig");

// Logs semantic conventions
pub const logs = @import("logs.zig");

// HTTP semantic conventions (common across signals)
pub const http = @import("http.zig");

// Database semantic conventions
pub const db = @import("database.zig");

// Messaging semantic conventions
pub const messaging = @import("messaging.zig");

// RPC semantic conventions
pub const rpc = @import("rpc.zig");

// Exception semantic conventions
pub const exception = @import("exception.zig");

// Network semantic conventions
pub const net = @import("network.zig");

// Common attribute value constants
pub const AttributeValue = struct {
    // Common values for various attributes
    pub const HTTP_FLAVOR_1_0 = "1.0";
    pub const HTTP_FLAVOR_1_1 = "1.1";
    pub const HTTP_FLAVOR_2_0 = "2.0";
    pub const HTTP_FLAVOR_3_0 = "3.0";
    
    pub const NET_TRANSPORT_TCP = "ip_tcp";
    pub const NET_TRANSPORT_UDP = "ip_udp";
    pub const NET_TRANSPORT_PIPE = "pipe";
    pub const NET_TRANSPORT_UNIX = "unix";
    
    pub const DB_SYSTEM_MYSQL = "mysql";
    pub const DB_SYSTEM_POSTGRESQL = "postgresql";
    pub const DB_SYSTEM_MONGODB = "mongodb";
    pub const DB_SYSTEM_REDIS = "redis";
    pub const DB_SYSTEM_SQLITE = "sqlite";
    
    pub const MESSAGING_SYSTEM_KAFKA = "kafka";
    pub const MESSAGING_SYSTEM_RABBITMQ = "rabbitmq";
    pub const MESSAGING_SYSTEM_AWS_SQS = "aws_sqs";
    pub const MESSAGING_SYSTEM_GCP_PUBSUB = "gcp_pubsub";
    
    pub const RPC_SYSTEM_GRPC = "grpc";
    pub const RPC_SYSTEM_JAVA_RMI = "java_rmi";
    pub const RPC_SYSTEM_DOTNET_WCF = "dotnet_wcf";
    pub const RPC_SYSTEM_APACHE_DUBBO = "apache_dubbo";
};

// Re-export commonly used conventions at the root level
pub const SERVICE_NAME = resource.SERVICE_NAME;
pub const SERVICE_VERSION = resource.SERVICE_VERSION;
pub const HTTP_METHOD = trace.HTTP_METHOD;
pub const HTTP_STATUS_CODE = trace.HTTP_STATUS_CODE;

// Version information
pub const SEMCONV_VERSION = "1.24.0";
pub const SCHEMA_URL = "https://opentelemetry.io/schemas/1.24.0";

test "semconv module compilation" {
    _ = std.testing;
    _ = resource;
    _ = trace;
    _ = metrics;
    _ = logs;
    _ = http;
    _ = db;
    _ = messaging;
    _ = rpc;
    _ = exception;
    _ = net;
    _ = AttributeValue;
}