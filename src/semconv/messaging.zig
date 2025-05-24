//! OpenTelemetry Messaging Semantic Conventions
//!
//! This module defines standard messaging attribute names according to
//! the OpenTelemetry semantic conventions specification.
//!
//! These conventions ensure consistent naming for messaging-related attributes
//! across different implementations and languages.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/semantic_conventions/messaging.md

// General messaging attributes
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

// Messaging system values
pub const MessagingSystemValues = struct {
    pub const ACTIVEMQ = "activemq";
    pub const AWS_SQS = "aws_sqs";
    pub const AWS_EVENTBRIDGE = "aws_eventbridge";
    pub const AWS_SNS = "aws_sns";
    pub const AWS_KINESIS = "aws_kinesis";
    pub const AZURE_SERVICEBUS = "azure_servicebus";
    pub const AZURE_EVENTHUBS = "azure_eventhubs";
    pub const AZURE_EVENTGRID = "azure_eventgrid";
    pub const KAFKA = "kafka";
    pub const RABBITMQ = "rabbitmq";
    pub const ROCKETMQ = "rocketmq";
    pub const GCP_PUBSUB = "gcp_pubsub";
    pub const JMS = "jms";
    pub const IBMMQ = "ibmmq";
    pub const PULSAR = "pulsar";
};

// Messaging destination kind values
pub const MessagingDestinationKindValues = struct {
    pub const QUEUE = "queue";
    pub const TOPIC = "topic";
};

// Messaging operation values
pub const MessagingOperationValues = struct {
    pub const PUBLISH = "publish";
    pub const RECEIVE = "receive";
    pub const PROCESS = "process";
};

// RabbitMQ specific attributes
pub const MESSAGING_RABBITMQ_ROUTING_KEY = "messaging.rabbitmq.routing_key";

// Kafka specific attributes
pub const MESSAGING_KAFKA_MESSAGE_KEY = "messaging.kafka.message_key";
pub const MESSAGING_KAFKA_CONSUMER_GROUP = "messaging.kafka.consumer_group";
pub const MESSAGING_KAFKA_CLIENT_ID = "messaging.kafka.client_id";
pub const MESSAGING_KAFKA_PARTITION = "messaging.kafka.partition";
pub const MESSAGING_KAFKA_TOMBSTONE = "messaging.kafka.tombstone";
pub const MESSAGING_KAFKA_MESSAGE_OFFSET = "messaging.kafka.message.offset";

// RocketMQ specific attributes
pub const MESSAGING_ROCKETMQ_NAMESPACE = "messaging.rocketmq.namespace";
pub const MESSAGING_ROCKETMQ_CLIENT_GROUP = "messaging.rocketmq.client_group";
pub const MESSAGING_ROCKETMQ_CLIENT_ID = "messaging.rocketmq.client_id";
pub const MESSAGING_ROCKETMQ_MESSAGE_DELIVERY_TIMESTAMP = "messaging.rocketmq.message.delivery_timestamp";
pub const MESSAGING_ROCKETMQ_MESSAGE_GROUP = "messaging.rocketmq.message.group";
pub const MESSAGING_ROCKETMQ_MESSAGE_TYPE = "messaging.rocketmq.message.type";
pub const MESSAGING_ROCKETMQ_MESSAGE_TAG = "messaging.rocketmq.message.tag";
pub const MESSAGING_ROCKETMQ_MESSAGE_KEYS = "messaging.rocketmq.message.keys";
pub const MESSAGING_ROCKETMQ_CONSUMPTION_MODEL = "messaging.rocketmq.consumption_model";

// GCP Pub/Sub specific attributes
pub const MESSAGING_GCP_PUBSUB_MESSAGE_ORDERING_KEY = "messaging.gcp_pubsub.message.ordering_key";

// Azure Event Hubs specific attributes
pub const MESSAGING_AZURE_EVENTHUBS_MESSAGE_ENQUEUED_TIME = "messaging.eventhubs.message.enqueued_time";

// Consumer attributes
pub const MESSAGING_CONSUMER = "messaging.consumer";
pub const MESSAGING_CONSUMER_ID = "messaging.consumer.id";

// Message batch attributes
pub const MESSAGING_BATCH_MESSAGE_COUNT = "messaging.batch.message_count";

// RocketMQ message type values
pub const RocketMQMessageTypeValues = struct {
    pub const NORMAL = "normal";
    pub const FIFO = "fifo";
    pub const DELAY = "delay";
    pub const TRANSACTION = "transaction";
};

// RocketMQ consumption model values
pub const RocketMQConsumptionModelValues = struct {
    pub const CLUSTERING = "clustering";
    pub const BROADCASTING = "broadcasting";
};