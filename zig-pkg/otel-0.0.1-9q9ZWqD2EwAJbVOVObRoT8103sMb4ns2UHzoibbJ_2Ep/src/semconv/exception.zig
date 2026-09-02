//! OpenTelemetry Exception Semantic Conventions
//!
//! This module defines standard exception attribute names according to
//! the OpenTelemetry semantic conventions specification.
//!
//! These conventions ensure consistent naming for exception-related attributes
//! across different implementations and languages.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/semantic_conventions/exceptions.md

// Exception attributes
pub const EXCEPTION_TYPE = "exception.type";
pub const EXCEPTION_MESSAGE = "exception.message";
pub const EXCEPTION_STACKTRACE = "exception.stacktrace";
pub const EXCEPTION_ESCAPED = "exception.escaped";

// Code attributes often associated with exceptions
pub const CODE_FUNCTION = "code.function";
pub const CODE_NAMESPACE = "code.namespace";
pub const CODE_FILEPATH = "code.filepath";
pub const CODE_LINENO = "code.lineno";
pub const CODE_COLUMN = "code.column";

// Thread attributes for exception context
pub const THREAD_ID = "thread.id";
pub const THREAD_NAME = "thread.name";

// Common exception types by language
pub const ExceptionTypes = struct {
    // Java exceptions
    pub const JAVA_NULL_POINTER = "java.lang.NullPointerException";
    pub const JAVA_ILLEGAL_ARGUMENT = "java.lang.IllegalArgumentException";
    pub const JAVA_ILLEGAL_STATE = "java.lang.IllegalStateException";
    pub const JAVA_INDEX_OUT_OF_BOUNDS = "java.lang.IndexOutOfBoundsException";
    pub const JAVA_CLASS_CAST = "java.lang.ClassCastException";
    pub const JAVA_ARITHMETIC = "java.lang.ArithmeticException";
    pub const JAVA_UNSUPPORTED_OPERATION = "java.lang.UnsupportedOperationException";
    pub const JAVA_IO = "java.io.IOException";
    pub const JAVA_SQL = "java.sql.SQLException";
    
    // Python exceptions
    pub const PYTHON_VALUE_ERROR = "ValueError";
    pub const PYTHON_TYPE_ERROR = "TypeError";
    pub const PYTHON_KEY_ERROR = "KeyError";
    pub const PYTHON_INDEX_ERROR = "IndexError";
    pub const PYTHON_ATTRIBUTE_ERROR = "AttributeError";
    pub const PYTHON_RUNTIME_ERROR = "RuntimeError";
    pub const PYTHON_NOT_IMPLEMENTED_ERROR = "NotImplementedError";
    pub const PYTHON_OS_ERROR = "OSError";
    pub const PYTHON_IO_ERROR = "IOError";
    
    // .NET exceptions
    pub const DOTNET_NULL_REFERENCE = "System.NullReferenceException";
    pub const DOTNET_ARGUMENT = "System.ArgumentException";
    pub const DOTNET_ARGUMENT_NULL = "System.ArgumentNullException";
    pub const DOTNET_ARGUMENT_OUT_OF_RANGE = "System.ArgumentOutOfRangeException";
    pub const DOTNET_INVALID_OPERATION = "System.InvalidOperationException";
    pub const DOTNET_NOT_SUPPORTED = "System.NotSupportedException";
    pub const DOTNET_NOT_IMPLEMENTED = "System.NotImplementedException";
    pub const DOTNET_INDEX_OUT_OF_RANGE = "System.IndexOutOfRangeException";
    pub const DOTNET_FORMAT = "System.FormatException";
    
    // JavaScript/TypeScript errors
    pub const JS_ERROR = "Error";
    pub const JS_TYPE_ERROR = "TypeError";
    pub const JS_REFERENCE_ERROR = "ReferenceError";
    pub const JS_RANGE_ERROR = "RangeError";
    pub const JS_SYNTAX_ERROR = "SyntaxError";
    pub const JS_URI_ERROR = "URIError";
    
    // Go errors (typically just the type name)
    pub const GO_ERROR = "error";
    
    // Rust errors (typically the type path)
    pub const RUST_PANIC = "panic";
    
    // C++ exceptions
    pub const CPP_EXCEPTION = "std::exception";
    pub const CPP_RUNTIME_ERROR = "std::runtime_error";
    pub const CPP_LOGIC_ERROR = "std::logic_error";
    pub const CPP_OUT_OF_RANGE = "std::out_of_range";
    pub const CPP_INVALID_ARGUMENT = "std::invalid_argument";
    
    // Database exceptions
    pub const DB_CONNECTION_ERROR = "DatabaseConnectionError";
    pub const DB_TIMEOUT_ERROR = "DatabaseTimeoutError";
    pub const DB_CONSTRAINT_VIOLATION = "ConstraintViolationError";
    
    // Network exceptions
    pub const NETWORK_TIMEOUT = "NetworkTimeoutError";
    pub const NETWORK_CONNECTION_REFUSED = "ConnectionRefusedError";
    pub const NETWORK_DNS_ERROR = "DNSResolutionError";
    
    // HTTP exceptions
    pub const HTTP_CLIENT_ERROR = "HTTPClientError";
    pub const HTTP_SERVER_ERROR = "HTTPServerError";
    pub const HTTP_TIMEOUT_ERROR = "HTTPTimeoutError";
};

// Helper function to check if an exception was caught and handled
pub fn wasExceptionEscaped(escaped: bool) []const u8 {
    return if (escaped) "true" else "false";
}

// Common patterns for stacktrace formatting
pub const StacktraceFormat = struct {
    pub const FULL = "full";
    pub const COMPACT = "compact";
    pub const SINGLE_LINE = "single_line";
};