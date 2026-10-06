# Raw telemetry topic (10 partitions, 7d retention) and its Avro value schema.
# If the topic already exists, import it instead of creating it:
#   terraform import confluent_kafka_topic.telemetry <kafka-cluster-id>/machine.telemetry
resource "confluent_kafka_topic" "telemetry" {
  topic_name       = var.telemetry_topic
  partitions_count = 10
  rest_endpoint    = data.confluent_kafka_cluster.this.rest_endpoint

  config = {
    "cleanup.policy" = "delete"
    "retention.ms"   = "604800000"
  }

  kafka_cluster {
    id = data.confluent_kafka_cluster.this.id
  }

  credentials {
    key    = confluent_api_key.kafka.id
    secret = confluent_api_key.kafka.secret
  }
}

resource "confluent_schema" "telemetry" {
  subject_name  = "${var.telemetry_topic}-value"
  format        = "AVRO"
  schema        = file("${path.module}/machine-schema.avsc")
  rest_endpoint = data.confluent_schema_registry_cluster.this.rest_endpoint

  schema_registry_cluster {
    id = data.confluent_schema_registry_cluster.this.id
  }

  credentials {
    key    = confluent_api_key.schema_registry.id
    secret = confluent_api_key.schema_registry.secret
  }
}
