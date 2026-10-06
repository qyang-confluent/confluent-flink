data "confluent_organization" "this" {}

data "confluent_environment" "this" {
  id = var.environment_id
}

data "confluent_kafka_cluster" "this" {
  display_name = var.kafka_cluster_name
  environment {
    id = var.environment_id
  }
}

data "confluent_flink_region" "this" {
  cloud  = var.cloud
  region = var.region
}

# 1. Compute pool in the existing environment
resource "confluent_flink_compute_pool" "this" {
  display_name = var.compute_pool_name
  cloud        = var.cloud
  region       = var.region
  max_cfu      = var.max_cfu

  environment {
    id = var.environment_id
  }
}

# Flink API key used by the provider to submit statements
resource "confluent_api_key" "flink" {
  display_name = "${var.compute_pool_name}-flink-api-key"

  owner {
    id          = var.service_account_id
    api_version = "iam/v2"
    kind        = "ServiceAccount"
  }

  managed_resource {
    id          = data.confluent_flink_region.this.id
    api_version = data.confluent_flink_region.this.api_version
    kind        = data.confluent_flink_region.this.kind

    environment {
      id = var.environment_id
    }
  }
}

# 2. Tables as materialized tables (queries in queries.tf).
# Chain: machine_telemetry_flat -> machine_features_10s -> anomaly tables.
locals {
  flink_session_options = {
    "sql.current-catalog"  = data.confluent_environment.this.display_name
    "sql.current-database" = data.confluent_kafka_cluster.this.display_name
  }
}

resource "confluent_flink_materialized_table" "telemetry_flat" {
  # The machine.telemetry topic and its schema must exist before Flink can read the table.
  depends_on = [confluent_kafka_topic.telemetry, confluent_schema.telemetry]

  display_name    = "machine_telemetry_flat"
  query           = local.telemetry_flat_query
  session_options = local.flink_session_options
  rest_endpoint   = data.confluent_flink_region.this.rest_endpoint

  watermark {
    column     = "event_ts"
    expression = "`event_ts` - INTERVAL '5' SECOND"
  }

  distribution {
    kind         = "HASH"
    keys         = ["equipment_id"]
    bucket_count = 6
  }

  kafka_cluster { id = data.confluent_kafka_cluster.this.id }
  organization { id = data.confluent_organization.this.id }
  environment { id = var.environment_id }
  compute_pool { id = confluent_flink_compute_pool.this.id }
  principal { id = var.service_account_id }
  credentials {
    key    = confluent_api_key.flink.id
    secret = confluent_api_key.flink.secret
  }
}

resource "confluent_flink_materialized_table" "features_10s" {
  depends_on = [confluent_flink_materialized_table.telemetry_flat]

  display_name    = "machine_features_10s"
  query           = local.features_query
  session_options = local.flink_session_options
  rest_endpoint   = data.confluent_flink_region.this.rest_endpoint

  distribution {
    kind         = "HASH"
    keys         = ["equipment_id"]
    bucket_count = 6
  }

  kafka_cluster { id = data.confluent_kafka_cluster.this.id }
  organization { id = data.confluent_organization.this.id }
  environment { id = var.environment_id }
  compute_pool { id = confluent_flink_compute_pool.this.id }
  principal { id = var.service_account_id }
  credentials {
    key    = confluent_api_key.flink.id
    secret = confluent_api_key.flink.secret
  }
}

resource "confluent_flink_materialized_table" "downstream" {
  for_each   = local.downstream_queries
  depends_on = [confluent_flink_materialized_table.features_10s]

  display_name    = each.key
  query           = each.value
  session_options = local.flink_session_options
  rest_endpoint   = data.confluent_flink_region.this.rest_endpoint

  distribution {
    kind         = "HASH"
    keys         = ["equipment_id"]
    bucket_count = 6
  }

  kafka_cluster { id = data.confluent_kafka_cluster.this.id }
  organization { id = data.confluent_organization.this.id }
  environment { id = var.environment_id }
  compute_pool { id = confluent_flink_compute_pool.this.id }
  principal { id = var.service_account_id }
  credentials {
    key    = confluent_api_key.flink.id
    secret = confluent_api_key.flink.secret
  }
}
