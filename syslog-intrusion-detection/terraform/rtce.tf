# Credentials come from CONFLUENT_CLOUD_API_KEY / CONFLUENT_CLOUD_API_SECRET.
provider "confluent" {}

variable "confluent_environment_id" {
  type    = string
  default = "env-7d27kp"
}

variable "confluent_kafka_cluster_id" {
  type    = string
  default = "lkc-qov1d7"
}

variable "confluent_cloud" {
  type    = string
  default = "AWS"
}

variable "confluent_region" {
  description = "Region of the Kafka cluster (not necessarily the EC2 region)."
  type        = string
  default     = "us-east-1"
}

variable "rtce_topic_name" {
  description = "Topic to expose through the Real-Time Context Engine."
  type        = string
  default     = "syslog_alerts"
}

variable "rtce_description" {
  description = "Read by AI agents to decide when to query the topic. API limit: 256 characters."
  type        = string
  default     = "Syslog intrusion alerts: one row per host per 1-minute window, scored by an SLM. Fields: host, window_start, window_end, line_count, verdict (attack/benign), category, confidence, reason, sample. Use to find recent attacks per host."
}

# The topic is created by the table DDL in flink_tables.tf, which this depends on. Disabling = removing this resource.
# RTCE is billed per CCU while enabled.
resource "confluent_rtce_topic" "syslog_alerts" {
  topic_name  = var.rtce_topic_name
  cloud       = var.confluent_cloud
  region      = var.confluent_region
  description = var.rtce_description

  environment {
    id = var.confluent_environment_id
  }
  kafka_cluster {
    id = var.confluent_kafka_cluster_id
  }

  depends_on = [confluent_flink_statement.syslog_alerts]
}

# What Metabase (Confluent Lightning JDBC driver) needs to query the RTCE table. No secrets: the
# username/password are the Confluent Cloud API key/secret used by metabase/build_dashboard.py.
output "rtce_table" {
  description = "Table name to query in Metabase."
  value       = var.rtce_topic_name
}

output "metabase_lightning" {
  description = "Same keys as ../insurance-fraud-detection/notebook/lt-jdbc.properties."
  value = {
    "client.lightning-endpoint" = "sql.${lower(var.confluent_region)}.${lower(var.confluent_cloud)}.confluent.cloud"
    "client.environment-id"     = var.confluent_environment_id
    "client.lkc-id"             = var.confluent_kafka_cluster_id
    table                       = var.rtce_topic_name
  }
}

# Dedicated identity for Metabase (Lightning JDBC). It gets a Cloud API key and read access to the cluster's topics.
data "confluent_kafka_cluster" "this" {
  id = var.confluent_kafka_cluster_id
  environment {
    id = var.confluent_environment_id
  }
}

resource "confluent_service_account" "metabase" {
  display_name = "syslog-metabase"
  description  = "Metabase reading RTCE table syslog_alerts"
}

resource "confluent_role_binding" "metabase_read" {
  principal   = "User:${confluent_service_account.metabase.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${data.confluent_kafka_cluster.this.rbac_crn}/kafka=${data.confluent_kafka_cluster.this.id}/topic=${var.rtce_topic_name}"
}

resource "confluent_api_key" "metabase" {
  display_name = "syslog-metabase"
  description  = "Cloud API key for Metabase Lightning JDBC"
  owner {
    id          = confluent_service_account.metabase.id
    api_version = confluent_service_account.metabase.api_version
    kind        = confluent_service_account.metabase.kind
  }

  # Lightning/RTCE needs a Global key, not a plain Cloud API key.
  managed_resource {
    id          = "global"
    api_version = "global/v1"
    kind        = "Global"
  }
}

output "metabase_api_key" {
  value = confluent_api_key.metabase.id
}

output "metabase_api_secret" {
  value     = confluent_api_key.metabase.secret
  sensitive = true
}
