# API key for the Kafka cluster (e.g. for producers such as shadowtraffic), owned by the service account.
resource "confluent_api_key" "kafka" {
  display_name = "${var.compute_pool_name}-kafka-api-key"

  owner {
    id          = var.service_account_id
    api_version = "iam/v2"
    kind        = "ServiceAccount"
  }

  managed_resource {
    id          = data.confluent_kafka_cluster.this.id
    api_version = data.confluent_kafka_cluster.this.api_version
    kind        = data.confluent_kafka_cluster.this.kind

    environment {
      id = var.environment_id
    }
  }
}
