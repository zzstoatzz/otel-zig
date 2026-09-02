//! OpenTelemetry RPC Semantic Conventions
//!
//! This module defines standard RPC attribute names according to
//! the OpenTelemetry semantic conventions specification.
//!
//! These conventions ensure consistent naming for RPC-related attributes
//! across different implementations and languages.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/semantic_conventions/rpc.md

// General RPC attributes
pub const RPC_SYSTEM = "rpc.system";
pub const RPC_SERVICE = "rpc.service";
pub const RPC_METHOD = "rpc.method";

// RPC status attributes
pub const RPC_GRPC_STATUS_CODE = "rpc.grpc.status_code";
pub const RPC_JSONRPC_VERSION = "rpc.jsonrpc.version";
pub const RPC_JSONRPC_REQUEST_ID = "rpc.jsonrpc.request_id";
pub const RPC_JSONRPC_ERROR_CODE = "rpc.jsonrpc.error_code";
pub const RPC_JSONRPC_ERROR_MESSAGE = "rpc.jsonrpc.error_message";
pub const RPC_CONNECT_RPC_ERROR_CODE = "rpc.connect_rpc.error_code";

// RPC system values
pub const RpcSystemValues = struct {
    pub const GRPC = "grpc";
    pub const JAVA_RMI = "java_rmi";
    pub const DOTNET_WCF = "dotnet_wcf";
    pub const APACHE_DUBBO = "apache_dubbo";
    pub const JSONRPC = "jsonrpc";
    pub const CONNECT_RPC = "connect_rpc";
};

// gRPC status code values
pub const RpcGrpcStatusCodeValues = struct {
    pub const OK = 0;
    pub const CANCELLED = 1;
    pub const UNKNOWN = 2;
    pub const INVALID_ARGUMENT = 3;
    pub const DEADLINE_EXCEEDED = 4;
    pub const NOT_FOUND = 5;
    pub const ALREADY_EXISTS = 6;
    pub const PERMISSION_DENIED = 7;
    pub const RESOURCE_EXHAUSTED = 8;
    pub const FAILED_PRECONDITION = 9;
    pub const ABORTED = 10;
    pub const OUT_OF_RANGE = 11;
    pub const UNIMPLEMENTED = 12;
    pub const INTERNAL = 13;
    pub const UNAVAILABLE = 14;
    pub const DATA_LOSS = 15;
    pub const UNAUTHENTICATED = 16;
};

// Connect RPC error code values
pub const RpcConnectRpcErrorCodeValues = struct {
    pub const CANCELLED = "cancelled";
    pub const UNKNOWN = "unknown";
    pub const INVALID_ARGUMENT = "invalid_argument";
    pub const DEADLINE_EXCEEDED = "deadline_exceeded";
    pub const NOT_FOUND = "not_found";
    pub const ALREADY_EXISTS = "already_exists";
    pub const PERMISSION_DENIED = "permission_denied";
    pub const RESOURCE_EXHAUSTED = "resource_exhausted";
    pub const FAILED_PRECONDITION = "failed_precondition";
    pub const ABORTED = "aborted";
    pub const OUT_OF_RANGE = "out_of_range";
    pub const UNIMPLEMENTED = "unimplemented";
    pub const INTERNAL = "internal";
    pub const UNAVAILABLE = "unavailable";
    pub const DATA_LOSS = "data_loss";
    pub const UNAUTHENTICATED = "unauthenticated";
};

// JSON-RPC specific attributes
pub const JsonRpcVersionValues = struct {
    pub const VERSION_1_0 = "1.0";
    pub const VERSION_2_0 = "2.0";
};

// Common JSON-RPC error codes
pub const JsonRpcErrorCodeValues = struct {
    pub const PARSE_ERROR = -32700;
    pub const INVALID_REQUEST = -32600;
    pub const METHOD_NOT_FOUND = -32601;
    pub const INVALID_PARAMS = -32602;
    pub const INTERNAL_ERROR = -32603;
    pub const SERVER_ERROR_START = -32099;
    pub const SERVER_ERROR_END = -32000;
};