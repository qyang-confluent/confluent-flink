variable "environment_id" {
  description = "Existing Confluent Cloud environment ID (env-xxxx)."
  type        = string
}

variable "kafka_cluster_name" {
  description = "Display name of the existing Kafka cluster in the environment. Used as the Flink database (current-database) for the compute pool's statements and tables; must hold the machine.telemetry table."
  type        = string
}

variable "cloud" {
  description = "Cloud provider of the Flink region (AWS, GCP, AZURE). Must match the Kafka cluster."
  type        = string
  default     = "AWS"
}

variable "region" {
  description = "Flink region. Must match the Kafka cluster."
  type        = string
  default     = "us-east-1"
}

variable "compute_pool_name" {
  type    = string
  default = "machine-ad-pool"
}

variable "max_cfu" {
  description = "Max CFUs for the compute pool."
  type        = number
  default     = 10
}

variable "service_account_id" {
  description = "Existing service account (sa-xxxx) the Flink statements run as. It needs FlinkDeveloper plus read on machine.telemetry and write on the output topics/schemas."
  type        = string
}

variable "env_file" {
  description = "Path of the generated env file with Kafka and Schema Registry connection settings."
  type        = string
  default     = "ccloud.env"
}

variable "telemetry_topic" {
  description = "Raw telemetry topic; its value schema is registered from machine-schema.avsc."
  type        = string
  default     = "machine.telemetry"
}
