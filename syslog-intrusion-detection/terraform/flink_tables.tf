# Creates the Flink tables (and therefore their Kafka topics) from Terraform, so RTCE (rtce.tf) can depend on them.
# The continuous INSERT INTO statements stay in deploy_flink.sh because they need the model and the live GPU endpoint.

variable "flink_compute_pool_id" {
  type    = string
  default = "lfcp-6k719z2"
}

data "confluent_organization" "this" {}

data "confluent_environment" "this" {
  id = var.confluent_environment_id
}

data "confluent_flink_region" "this" {
  cloud  = var.confluent_cloud
  region = var.confluent_region
}

# Runs the table DDL. EnvironmentAdmin is broad but keeps the demo free of per-topic and per-subject RBAC
# (Flink creates the topic and registers its schema); narrow it for anything shared.
resource "confluent_service_account" "flink" {
  display_name = "syslog-flink"
  description  = "Runs the syslog Flink table DDL"
}

resource "confluent_role_binding" "flink_admin" {
  principal   = "User:${confluent_service_account.flink.id}"
  role_name   = "EnvironmentAdmin"
  crn_pattern = data.confluent_environment.this.resource_name
}

resource "confluent_api_key" "flink" {
  display_name = "syslog-flink"
  description  = "Flink API key used by Terraform to submit the table DDL"

  owner {
    id          = confluent_service_account.flink.id
    api_version = confluent_service_account.flink.api_version
    kind        = confluent_service_account.flink.kind
  }
  managed_resource {
    id          = data.confluent_flink_region.this.id
    api_version = data.confluent_flink_region.this.api_version
    kind        = data.confluent_flink_region.this.kind
    environment {
      id = var.confluent_environment_id
    }
  }

  depends_on = [confluent_role_binding.flink_admin]
}

locals {
  table_statements = [for s in split(";", replace(file("${path.module}/syslog_tables.sql"), "/(?m)^--.*$/", "")) : trimspace(s) if length(regexall("CREATE TABLE", s)) > 0]
  flink_common = {
    catalog  = data.confluent_environment.this.display_name
    database = data.confluent_kafka_cluster.this.display_name
  }
}

resource "confluent_flink_statement" "syslog_windows" {
  statement_name = "syslog-create-windows-table"
  statement      = local.table_statements[0]

  properties = {
    "sql.current-catalog"  = local.flink_common.catalog
    "sql.current-database" = local.flink_common.database
  }
  organization {
    id = data.confluent_organization.this.id
  }
  environment {
    id = var.confluent_environment_id
  }
  compute_pool {
    id = var.flink_compute_pool_id
  }
  principal {
    id = confluent_service_account.flink.id
  }
  rest_endpoint = data.confluent_flink_region.this.rest_endpoint
  credentials {
    key    = confluent_api_key.flink.id
    secret = confluent_api_key.flink.secret
  }
}

resource "confluent_flink_statement" "syslog_alerts" {
  statement_name = "syslog-create-alerts-table"
  statement      = local.table_statements[1]

  properties = {
    "sql.current-catalog"  = local.flink_common.catalog
    "sql.current-database" = local.flink_common.database
  }
  organization {
    id = data.confluent_organization.this.id
  }
  environment {
    id = var.confluent_environment_id
  }
  compute_pool {
    id = var.flink_compute_pool_id
  }
  principal {
    id = confluent_service_account.flink.id
  }
  rest_endpoint = data.confluent_flink_region.this.rest_endpoint
  credentials {
    key    = confluent_api_key.flink.id
    secret = confluent_api_key.flink.secret
  }
}
