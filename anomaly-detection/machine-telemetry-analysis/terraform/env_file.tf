# Env file with Kafka + Schema Registry connection settings (contains secrets, written 0600).
resource "local_sensitive_file" "ccloud_env" {
  filename        = var.env_file
  file_permission = "0600"

  content = <<-EOT
    CCLOUD_BOOTSTRAP_SERVERS=${replace(data.confluent_kafka_cluster.this.bootstrap_endpoint, "SASL_SSL://", "")}
    CCLOUD_SASL_JAAS_CONFIG=org.apache.kafka.common.security.plain.PlainLoginModule required username='${confluent_api_key.kafka.id}' password='${confluent_api_key.kafka.secret}';
    CCLOUD_SR_URL=${data.confluent_schema_registry_cluster.this.rest_endpoint}
    CCLOUD_SR_USER_INFO=${confluent_api_key.schema_registry.id}:${confluent_api_key.schema_registry.secret}
  EOT
}
