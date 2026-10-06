# Schema Registry of the existing environment, and an API key for it owned by the service account.
data "confluent_schema_registry_cluster" "this" {
  environment {
    id = var.environment_id
  }
}

resource "confluent_api_key" "schema_registry" {
  display_name = "${var.compute_pool_name}-schema-registry-api-key"

  owner {
    id          = var.service_account_id
    api_version = "iam/v2"
    kind        = "ServiceAccount"
  }

  managed_resource {
    id          = data.confluent_schema_registry_cluster.this.id
    api_version = data.confluent_schema_registry_cluster.this.api_version
    kind        = data.confluent_schema_registry_cluster.this.kind

    environment {
      id = var.environment_id
    }
  }
}
