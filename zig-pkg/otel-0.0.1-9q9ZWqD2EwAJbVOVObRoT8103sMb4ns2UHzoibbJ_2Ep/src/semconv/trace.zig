//! OpenTelemetry Trace Semantic Conventions
//!
//! This module defines standard attribute names for traces according to
//! the OpenTelemetry semantic conventions specification.
//!
//! These conventions ensure consistent naming for span attributes across
//! different implementations and languages.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/semantic_conventions/README.md

// General attributes
pub const NET_TRANSPORT = "net.transport";
pub const NET_PEER_IP = "net.peer.ip";
pub const NET_PEER_PORT = "net.peer.port";
pub const NET_PEER_NAME = "net.peer.name";
pub const NET_HOST_IP = "net.host.ip";
pub const NET_HOST_PORT = "net.host.port";
pub const NET_HOST_NAME = "net.host.name";

// HTTP attributes
pub const HTTP_METHOD = "http.method";
pub const HTTP_URL = "http.url";
pub const HTTP_TARGET = "http.target";
pub const HTTP_HOST = "http.host";
pub const HTTP_SCHEME = "http.scheme";
pub const HTTP_STATUS_CODE = "http.status_code";
pub const HTTP_FLAVOR = "http.flavor";
pub const HTTP_USER_AGENT = "http.user_agent";
pub const HTTP_REQUEST_CONTENT_LENGTH = "http.request_content_length";
pub const HTTP_REQUEST_CONTENT_LENGTH_UNCOMPRESSED = "http.request_content_length_uncompressed";
pub const HTTP_RESPONSE_CONTENT_LENGTH = "http.response_content_length";
pub const HTTP_RESPONSE_CONTENT_LENGTH_UNCOMPRESSED = "http.response_content_length_uncompressed";
pub const HTTP_SERVER_NAME = "http.server_name";
pub const HTTP_ROUTE = "http.route";
pub const HTTP_CLIENT_IP = "http.client_ip";

// Database attributes
pub const DB_SYSTEM = "db.system";
pub const DB_CONNECTION_STRING = "db.connection_string";
pub const DB_USER = "db.user";
pub const DB_JDBC_DRIVER_CLASSNAME = "db.jdbc.driver_classname";
pub const DB_NAME = "db.name";
pub const DB_STATEMENT = "db.statement";
pub const DB_OPERATION = "db.operation";
pub const DB_MSSQL_INSTANCE_NAME = "db.mssql.instance_name";
pub const DB_CASSANDRA_KEYSPACE = "db.cassandra.keyspace";
pub const DB_CASSANDRA_PAGE_SIZE = "db.cassandra.page_size";
pub const DB_CASSANDRA_CONSISTENCY_LEVEL = "db.cassandra.consistency_level";
pub const DB_CASSANDRA_TABLE = "db.cassandra.table";
pub const DB_CASSANDRA_IDEMPOTENCE = "db.cassandra.idempotence";
pub const DB_CASSANDRA_SPECULATIVE_EXECUTION_COUNT = "db.cassandra.speculative_execution_count";
pub const DB_CASSANDRA_COORDINATOR_ID = "db.cassandra.coordinator.id";
pub const DB_CASSANDRA_COORDINATOR_DC = "db.cassandra.coordinator.dc";
pub const DB_HBASE_NAMESPACE = "db.hbase.namespace";
pub const DB_REDIS_DATABASE_INDEX = "db.redis.database_index";
pub const DB_MONGODB_COLLECTION = "db.mongodb.collection";
pub const DB_SQL_TABLE = "db.sql.table";

// RPC attributes
pub const RPC_SYSTEM = "rpc.system";
pub const RPC_SERVICE = "rpc.service";
pub const RPC_METHOD = "rpc.method";
pub const RPC_GRPC_STATUS_CODE = "rpc.grpc.status_code";
pub const RPC_JSONRPC_VERSION = "rpc.jsonrpc.version";
pub const RPC_JSONRPC_REQUEST_ID = "rpc.jsonrpc.request_id";
pub const RPC_JSONRPC_ERROR_CODE = "rpc.jsonrpc.error_code";
pub const RPC_JSONRPC_ERROR_MESSAGE = "rpc.jsonrpc.error_message";

// Messaging attributes
pub const MESSAGING_SYSTEM = "messaging.system";
pub const MESSAGING_DESTINATION = "messaging.destination";
pub const MESSAGING_DESTINATION_KIND = "messaging.destination_kind";
pub const MESSAGING_TEMP_DESTINATION = "messaging.temp_destination";
pub const MESSAGING_PROTOCOL = "messaging.protocol";
pub const MESSAGING_PROTOCOL_VERSION = "messaging.protocol_version";
pub const MESSAGING_URL = "messaging.url";
pub const MESSAGING_MESSAGE_ID = "messaging.message_id";
pub const MESSAGING_CONVERSATION_ID = "messaging.conversation_id";
pub const MESSAGING_MESSAGE_PAYLOAD_SIZE_BYTES = "messaging.message_payload_size_bytes";
pub const MESSAGING_MESSAGE_PAYLOAD_COMPRESSED_SIZE_BYTES = "messaging.message_payload_compressed_size_bytes";
pub const MESSAGING_OPERATION = "messaging.operation";
pub const MESSAGING_CONSUMER_ID = "messaging.consumer_id";
pub const MESSAGING_RABBITMQ_ROUTING_KEY = "messaging.rabbitmq.routing_key";
pub const MESSAGING_KAFKA_MESSAGE_KEY = "messaging.kafka.message_key";
pub const MESSAGING_KAFKA_CONSUMER_GROUP = "messaging.kafka.consumer_group";
pub const MESSAGING_KAFKA_CLIENT_ID = "messaging.kafka.client_id";
pub const MESSAGING_KAFKA_PARTITION = "messaging.kafka.partition";
pub const MESSAGING_KAFKA_TOMBSTONE = "messaging.kafka.tombstone";

// FaaS attributes
pub const FAAS_TRIGGER = "faas.trigger";
pub const FAAS_EXECUTION = "faas.execution";
pub const FAAS_DOCUMENT_COLLECTION = "faas.document.collection";
pub const FAAS_DOCUMENT_OPERATION = "faas.document.operation";
pub const FAAS_DOCUMENT_TIME = "faas.document.time";
pub const FAAS_DOCUMENT_NAME = "faas.document.name";
pub const FAAS_TIME = "faas.time";
pub const FAAS_CRON = "faas.cron";
pub const FAAS_COLDSTART = "faas.coldstart";
pub const FAAS_INVOKED_NAME = "faas.invoked_name";
pub const FAAS_INVOKED_PROVIDER = "faas.invoked_provider";
pub const FAAS_INVOKED_REGION = "faas.invoked_region";

// Exception attributes
pub const EXCEPTION_TYPE = "exception.type";
pub const EXCEPTION_MESSAGE = "exception.message";
pub const EXCEPTION_STACKTRACE = "exception.stacktrace";
pub const EXCEPTION_ESCAPED = "exception.escaped";

// Code attributes
pub const CODE_FUNCTION = "code.function";
pub const CODE_NAMESPACE = "code.namespace";
pub const CODE_FILEPATH = "code.filepath";
pub const CODE_LINENO = "code.lineno";

// Thread attributes
pub const THREAD_ID = "thread.id";
pub const THREAD_NAME = "thread.name";

// Common HTTP method values
pub const HttpMethodValues = struct {
    pub const CONNECT = "CONNECT";
    pub const DELETE = "DELETE";
    pub const GET = "GET";
    pub const HEAD = "HEAD";
    pub const OPTIONS = "OPTIONS";
    pub const PATCH = "PATCH";
    pub const POST = "POST";
    pub const PUT = "PUT";
    pub const TRACE = "TRACE";
};

// Common database system values
pub const DbSystemValues = struct {
    pub const OTHER_SQL = "other_sql";
    pub const MSSQL = "mssql";
    pub const MYSQL = "mysql";
    pub const ORACLE = "oracle";
    pub const DB2 = "db2";
    pub const POSTGRESQL = "postgresql";
    pub const REDSHIFT = "redshift";
    pub const HIVE = "hive";
    pub const CLOUDSCAPE = "cloudscape";
    pub const HSQLDB = "hsqldb";
    pub const PROGRESS = "progress";
    pub const MAXDB = "maxdb";
    pub const HANADB = "hanadb";
    pub const INGRES = "ingres";
    pub const FIRSTSQL = "firstsql";
    pub const EDB = "edb";
    pub const CACHE = "cache";
    pub const ADABAS = "adabas";
    pub const FIREBIRD = "firebird";
    pub const DERBY = "derby";
    pub const FILEMAKER = "filemaker";
    pub const INFORMIX = "informix";
    pub const INSTANTDB = "instantdb";
    pub const INTERBASE = "interbase";
    pub const MARIADB = "mariadb";
    pub const NETEZZA = "netezza";
    pub const PERVASIVE = "pervasive";
    pub const POINTBASE = "pointbase";
    pub const SQLITE = "sqlite";
    pub const SYBASE = "sybase";
    pub const TERADATA = "teradata";
    pub const VERTICA = "vertica";
    pub const H2 = "h2";
    pub const COLDFUSION = "coldfusion";
    pub const CASSANDRA = "cassandra";
    pub const HBASE = "hbase";
    pub const MONGODB = "mongodb";
    pub const REDIS = "redis";
    pub const COUCHBASE = "couchbase";
    pub const COUCHDB = "couchdb";
    pub const COSMOSDB = "cosmosdb";
    pub const DYNAMODB = "dynamodb";
    pub const NEO4J = "neo4j";
    pub const GEODE = "geode";
    pub const ELASTICSEARCH = "elasticsearch";
    pub const MEMCACHED = "memcached";
    pub const COCKROACHDB = "cockroachdb";
};

// Common messaging operation values
pub const MessagingOperationValues = struct {
    pub const RECEIVE = "receive";
    pub const PROCESS = "process";
};

// Common messaging destination kind values
pub const MessagingDestinationKindValues = struct {
    pub const QUEUE = "queue";
    pub const TOPIC = "topic";
};

// Common RPC gRPC status code values
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

// Common FaaS trigger values
pub const FaasTriggerValues = struct {
    pub const DATASOURCE = "datasource";
    pub const HTTP = "http";
    pub const PUBSUB = "pubsub";
    pub const TIMER = "timer";
    pub const OTHER = "other";
};

// Common FaaS document operation values
pub const FaasDocumentOperationValues = struct {
    pub const INSERT = "insert";
    pub const EDIT = "edit";
    pub const DELETE = "delete";
};