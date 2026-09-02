//! OpenTelemetry Database Semantic Conventions
//!
//! This module defines standard database attribute names according to
//! the OpenTelemetry semantic conventions specification.
//!
//! These conventions ensure consistent naming for database-related attributes
//! across different implementations and languages.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/semantic_conventions/database.md

// Database connection attributes
pub const DB_SYSTEM = "db.system";
pub const DB_CONNECTION_STRING = "db.connection_string";
pub const DB_USER = "db.user";
pub const DB_NAME = "db.name";

// Database statement attributes
pub const DB_STATEMENT = "db.statement";
pub const DB_OPERATION = "db.operation";

// Database-specific attributes
pub const DB_REDIS_DATABASE_INDEX = "db.redis.database_index";
pub const DB_MONGODB_COLLECTION = "db.mongodb.collection";
pub const DB_CASSANDRA_KEYSPACE = "db.cassandra.keyspace";
pub const DB_CASSANDRA_TABLE = "db.cassandra.table";
pub const DB_CASSANDRA_CONSISTENCY_LEVEL = "db.cassandra.consistency_level";
pub const DB_CASSANDRA_PAGE_SIZE = "db.cassandra.page_size";
pub const DB_CASSANDRA_COORDINATOR_ID = "db.cassandra.coordinator.id";
pub const DB_CASSANDRA_COORDINATOR_DC = "db.cassandra.coordinator.dc";
pub const DB_CASSANDRA_IDEMPOTENCE = "db.cassandra.idempotence";
pub const DB_CASSANDRA_SPECULATIVE_EXECUTION_COUNT = "db.cassandra.speculative_execution_count";
pub const DB_SQL_TABLE = "db.sql.table";
pub const DB_JDBC_DRIVER_CLASSNAME = "db.jdbc.driver_classname";
pub const DB_MSSQL_INSTANCE_NAME = "db.mssql.instance_name";
pub const DB_COSMOSDB_CONTAINER = "db.cosmosdb.container";
pub const DB_COSMOSDB_REQUEST_CONTENT_LENGTH = "db.cosmosdb.request_content_length";
pub const DB_COSMOSDB_STATUS_CODE = "db.cosmosdb.status_code";
pub const DB_COSMOSDB_SUB_STATUS_CODE = "db.cosmosdb.sub_status_code";
pub const DB_COSMOSDB_REQUEST_CHARGE = "db.cosmosdb.request_charge";
pub const DB_ELASTICSEARCH_CLUSTER_NAME = "db.elasticsearch.cluster.name";
pub const DB_ELASTICSEARCH_NODE_NAME = "db.elasticsearch.node.name";

// Database system values
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
    pub const OPENSEARCH = "opensearch";
    pub const CLICKHOUSE = "clickhouse";
};

// Database operation values
pub const DbOperationValues = struct {
    pub const SELECT = "select";
    pub const INSERT = "insert";
    pub const UPDATE = "update";
    pub const DELETE = "delete";
    pub const CREATE = "create";
    pub const DROP = "drop";
    pub const ALTER = "alter";
    pub const EXECUTE = "execute";
};

// Cassandra consistency level values
pub const CassandraConsistencyLevelValues = struct {
    pub const ALL = "all";
    pub const EACH_QUORUM = "each_quorum";
    pub const QUORUM = "quorum";
    pub const LOCAL_QUORUM = "local_quorum";
    pub const ONE = "one";
    pub const TWO = "two";
    pub const THREE = "three";
    pub const LOCAL_ONE = "local_one";
    pub const ANY = "any";
    pub const SERIAL = "serial";
    pub const LOCAL_SERIAL = "local_serial";
};