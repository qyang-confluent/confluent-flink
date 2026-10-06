output "compute_pool_id" {
  value = confluent_flink_compute_pool.this.id
}

output "materialized_tables" {
  value = sort(concat(
    [
      confluent_flink_materialized_table.telemetry_flat.display_name,
      confluent_flink_materialized_table.features_10s.display_name,
    ],
    keys(confluent_flink_materialized_table.downstream),
  ))
}

output "schema_registry_url" {
  value = data.confluent_schema_registry_cluster.this.rest_endpoint
}

output "schema_registry_api_key" {
  value = confluent_api_key.schema_registry.id
}

output "schema_registry_api_secret" {
  value     = confluent_api_key.schema_registry.secret
  sensitive = true
}

output "kafka_bootstrap_servers" {
  value = data.confluent_kafka_cluster.this.bootstrap_endpoint
}

output "kafka_api_key" {
  value = confluent_api_key.kafka.id
}

output "kafka_api_secret" {
  value     = confluent_api_key.kafka.secret
  sensitive = true
}
