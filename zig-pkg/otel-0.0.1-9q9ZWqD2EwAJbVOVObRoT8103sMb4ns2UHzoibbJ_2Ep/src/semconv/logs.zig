//! OpenTelemetry Logs Semantic Conventions
//!
//! This module defines standard attribute names for logs according to
//! the OpenTelemetry semantic conventions specification.
//!
//! These conventions ensure consistent naming for log attributes across
//! different implementations and languages.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/semantic_conventions/README.md

// Log-specific attributes
pub const LOG_IOSTREAM = "log.iostream";
pub const LOG_FILE_NAME = "log.file.name";
pub const LOG_FILE_NAME_RESOLVED = "log.file.name_resolved";
pub const LOG_FILE_PATH = "log.file.path";
pub const LOG_FILE_PATH_RESOLVED = "log.file.path_resolved";
pub const LOG_RECORD_UID = "log.record.uid";

// Event attributes
pub const EVENT_NAME = "event.name";
pub const EVENT_DOMAIN = "event.domain";

// Standard event names
pub const EventName = struct {
    // Device events
    pub const DEVICE_APP_LIFECYCLE = "device.app.lifecycle";
    
    // Browser events
    pub const BROWSER_NAVIGATE = "browser.navigate";
    
    // Feature flag events
    pub const FEATURE_FLAG = "feature_flag";
    
    // Error events
    pub const ERROR = "error";
    pub const EXCEPTION = "exception";
    
    // Metric events
    pub const METRIC = "metric";
};

// Event domains
pub const EventDomain = struct {
    pub const BROWSER = "browser";
    pub const DEVICE = "device";
    pub const K8S = "k8s";
};

// Log iostream values
pub const LogIostreamValues = struct {
    pub const STDOUT = "stdout";
    pub const STDERR = "stderr";
};

// Common log attributes (shared with trace)
pub const EXCEPTION_TYPE = "exception.type";
pub const EXCEPTION_MESSAGE = "exception.message";
pub const EXCEPTION_STACKTRACE = "exception.stacktrace";

// Code attributes for log location
pub const CODE_FUNCTION = "code.function";
pub const CODE_NAMESPACE = "code.namespace";
pub const CODE_FILEPATH = "code.filepath";
pub const CODE_LINENO = "code.lineno";
pub const CODE_COLUMN = "code.column";

// Thread attributes for log context
pub const THREAD_ID = "thread.id";
pub const THREAD_NAME = "thread.name";

// Process attributes commonly used in logs
pub const PROCESS_PID = "process.pid";
pub const PROCESS_EXECUTABLE_NAME = "process.executable.name";

// Log-specific HTTP attributes
pub const HTTP_REQUEST_METHOD = "http.request.method";
pub const HTTP_REQUEST_BODY_SIZE = "http.request.body.size";
pub const HTTP_RESPONSE_STATUS_CODE = "http.response.status_code";
pub const HTTP_RESPONSE_BODY_SIZE = "http.response.body.size";

// User attributes often in logs
pub const USER_ID = "user.id";
pub const USER_EMAIL = "user.email";
pub const USER_NAME = "user.name";
pub const USER_FULL_NAME = "user.full_name";

// Session attributes
pub const SESSION_ID = "session.id";
pub const SESSION_PREVIOUS_ID = "session.previous_id";

// Log severity text values (in addition to numeric severity)
pub const SeverityTextValues = struct {
    pub const TRACE = "TRACE";
    pub const DEBUG = "DEBUG";
    pub const INFO = "INFO";
    pub const WARN = "WARN";
    pub const ERROR = "ERROR";
    pub const FATAL = "FATAL";
};

// Common log categories/domains
pub const LogCategory = struct {
    pub const SECURITY = "security";
    pub const AUDIT = "audit";
    pub const PERFORMANCE = "performance";
    pub const TRANSACTION = "transaction";
    pub const SYSTEM = "system";
    pub const APPLICATION = "application";
    pub const ACCESS = "access";
};

// Feature flag attributes
pub const FEATURE_FLAG_KEY = "feature_flag.key";
pub const FEATURE_FLAG_VARIANT = "feature_flag.variant";
pub const FEATURE_FLAG_PROVIDER_NAME = "feature_flag.provider_name";

// Container log attributes
pub const CONTAINER_NAME = "container.name";
pub const CONTAINER_ID = "container.id";
pub const CONTAINER_IMAGE_NAME = "container.image.name";
pub const CONTAINER_IMAGE_TAG = "container.image.tag";

// Kubernetes log attributes
pub const K8S_POD_NAME = "k8s.pod.name";
pub const K8S_POD_UID = "k8s.pod.uid";
pub const K8S_CONTAINER_NAME = "k8s.container.name";
pub const K8S_NAMESPACE_NAME = "k8s.namespace.name";
pub const K8S_DEPLOYMENT_NAME = "k8s.deployment.name";
pub const K8S_REPLICASET_NAME = "k8s.replicaset.name";
pub const K8S_NODE_NAME = "k8s.node.name";

// Cloud log attributes
pub const CLOUD_PROVIDER = "cloud.provider";
pub const CLOUD_ACCOUNT_ID = "cloud.account.id";
pub const CLOUD_REGION = "cloud.region";
pub const CLOUD_AVAILABILITY_ZONE = "cloud.availability_zone";

// Service attributes commonly in logs
pub const SERVICE_NAME = "service.name";
pub const SERVICE_VERSION = "service.version";
pub const SERVICE_INSTANCE_ID = "service.instance.id";
pub const SERVICE_NAMESPACE = "service.namespace";