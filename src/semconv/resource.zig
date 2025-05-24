//! OpenTelemetry Resource Semantic Conventions
//!
//! This module defines standard attribute names for resources according to
//! the OpenTelemetry semantic conventions specification.
//!
//! Resources represent the entity producing telemetry. These conventions
//! ensure consistent naming across different implementations.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/resource/semantic_conventions/README.md

// Service attributes
pub const SERVICE_NAME = "service.name";
pub const SERVICE_NAMESPACE = "service.namespace";
pub const SERVICE_INSTANCE_ID = "service.instance.id";
pub const SERVICE_VERSION = "service.version";

// Telemetry SDK attributes
pub const TELEMETRY_SDK_NAME = "telemetry.sdk.name";
pub const TELEMETRY_SDK_LANGUAGE = "telemetry.sdk.language";
pub const TELEMETRY_SDK_VERSION = "telemetry.sdk.version";
pub const TELEMETRY_AUTO_VERSION = "telemetry.auto.version";

// Process attributes
pub const PROCESS_PID = "process.pid";
pub const PROCESS_PARENT_PID = "process.parent_pid";
pub const PROCESS_EXECUTABLE_NAME = "process.executable.name";
pub const PROCESS_EXECUTABLE_PATH = "process.executable.path";
pub const PROCESS_COMMAND = "process.command";
pub const PROCESS_COMMAND_LINE = "process.command_line";
pub const PROCESS_COMMAND_ARGS = "process.command_args";
pub const PROCESS_OWNER = "process.owner";
pub const PROCESS_RUNTIME_NAME = "process.runtime.name";
pub const PROCESS_RUNTIME_VERSION = "process.runtime.version";
pub const PROCESS_RUNTIME_DESCRIPTION = "process.runtime.description";

// Host attributes
pub const HOST_ID = "host.id";
pub const HOST_NAME = "host.name";
pub const HOST_TYPE = "host.type";
pub const HOST_ARCH = "host.arch";
pub const HOST_IMAGE_NAME = "host.image.name";
pub const HOST_IMAGE_ID = "host.image.id";
pub const HOST_IMAGE_VERSION = "host.image.version";

// OS attributes
pub const OS_TYPE = "os.type";
pub const OS_DESCRIPTION = "os.description";
pub const OS_NAME = "os.name";
pub const OS_VERSION = "os.version";

// Container attributes
pub const CONTAINER_NAME = "container.name";
pub const CONTAINER_ID = "container.id";
pub const CONTAINER_RUNTIME = "container.runtime";
pub const CONTAINER_IMAGE_NAME = "container.image.name";
pub const CONTAINER_IMAGE_TAG = "container.image.tag";
pub const CONTAINER_IMAGE_ID = "container.image.id";

// Kubernetes attributes
pub const K8S_CLUSTER_NAME = "k8s.cluster.name";
pub const K8S_NODE_NAME = "k8s.node.name";
pub const K8S_NODE_UID = "k8s.node.uid";
pub const K8S_NAMESPACE_NAME = "k8s.namespace.name";
pub const K8S_POD_UID = "k8s.pod.uid";
pub const K8S_POD_NAME = "k8s.pod.name";
pub const K8S_CONTAINER_NAME = "k8s.container.name";
pub const K8S_CONTAINER_RESTART_COUNT = "k8s.container.restart_count";
pub const K8S_DEPLOYMENT_NAME = "k8s.deployment.name";

// Cloud attributes
pub const CLOUD_PROVIDER = "cloud.provider";
pub const CLOUD_ACCOUNT_ID = "cloud.account.id";
pub const CLOUD_REGION = "cloud.region";
pub const CLOUD_AVAILABILITY_ZONE = "cloud.availability_zone";
pub const CLOUD_PLATFORM = "cloud.platform";

// AWS-specific attributes
pub const AWS_ECS_CONTAINER_ARN = "aws.ecs.container.arn";
pub const AWS_ECS_CLUSTER_ARN = "aws.ecs.cluster.arn";
pub const AWS_ECS_LAUNCHTYPE = "aws.ecs.launchtype";
pub const AWS_ECS_TASK_ARN = "aws.ecs.task.arn";
pub const AWS_ECS_TASK_FAMILY = "aws.ecs.task.family";
pub const AWS_ECS_TASK_REVISION = "aws.ecs.task.revision";
pub const AWS_EKS_CLUSTER_ARN = "aws.eks.cluster.arn";
pub const AWS_LOG_GROUP_NAMES = "aws.log.group.names";
pub const AWS_LOG_GROUP_ARNS = "aws.log.group.arns";
pub const AWS_LOG_STREAM_NAMES = "aws.log.stream.names";
pub const AWS_LOG_STREAM_ARNS = "aws.log.stream.arns";

// GCP-specific attributes
pub const GCP_GCE_INSTANCE_NAME = "gcp.gce.instance.name";
pub const GCP_GCE_INSTANCE_HOSTNAME = "gcp.gce.instance.hostname";

// Deployment environment
pub const DEPLOYMENT_ENVIRONMENT = "deployment.environment";

// Device attributes
pub const DEVICE_ID = "device.id";
pub const DEVICE_MODEL_IDENTIFIER = "device.model.identifier";
pub const DEVICE_MODEL_NAME = "device.model.name";
pub const DEVICE_MANUFACTURER = "device.manufacturer";

// Function-as-a-Service attributes
pub const FAAS_NAME = "faas.name";
pub const FAAS_ID = "faas.id";
pub const FAAS_VERSION = "faas.version";
pub const FAAS_INSTANCE = "faas.instance";
pub const FAAS_MAX_MEMORY = "faas.max_memory";

// Browser attributes
pub const BROWSER_BRANDS = "browser.brands";
pub const BROWSER_LANGUAGE = "browser.language";
pub const BROWSER_MOBILE = "browser.mobile";
pub const BROWSER_PLATFORM = "browser.platform";

// Common values for certain attributes
pub const CloudProviderValues = struct {
    pub const ALIBABA_CLOUD = "alibaba_cloud";
    pub const AWS = "aws";
    pub const AZURE = "azure";
    pub const GCP = "gcp";
    pub const HEROKU = "heroku";
    pub const IBM_CLOUD = "ibm_cloud";
    pub const TENCENT_CLOUD = "tencent_cloud";
};

pub const OsTypeValues = struct {
    pub const LINUX = "linux";
    pub const WINDOWS = "windows";
    pub const DARWIN = "darwin";
    pub const FREEBSD = "freebsd";
    pub const NETBSD = "netbsd";
    pub const OPENBSD = "openbsd";
    pub const DRAGONFLYBSD = "dragonflybsd";
    pub const HPUX = "hpux";
    pub const AIX = "aix";
    pub const SOLARIS = "solaris";
    pub const Z_OS = "z_os";
};

pub const HostArchValues = struct {
    pub const AMD64 = "amd64";
    pub const ARM32 = "arm32";
    pub const ARM64 = "arm64";
    pub const IA64 = "ia64";
    pub const PPC32 = "ppc32";
    pub const PPC64 = "ppc64";
    pub const S390X = "s390x";
    pub const X86 = "x86";
};

pub const TelemetrySdkLanguageValues = struct {
    pub const CPP = "cpp";
    pub const DOTNET = "dotnet";
    pub const ERLANG_ELIXIR = "erlang";
    pub const GO = "go";
    pub const JAVA = "java";
    pub const NODEJS = "nodejs";
    pub const PHP = "php";
    pub const PYTHON = "python";
    pub const RUBY = "ruby";
    pub const RUST = "rust";
    pub const SWIFT = "swift";
    pub const WEBJS = "webjs";
    pub const ZIG = "zig";
};