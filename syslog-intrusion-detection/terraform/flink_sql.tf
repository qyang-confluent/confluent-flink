terraform {
  required_providers {
    local = {
      source = "hashicorp/local"
    }
  }
}

variable "flink_connection_name" {
  type    = string
  default = "syslog_slm_conn"
}

variable "flink_model_name" {
  type    = string
  default = "syslog_analyst"
}

# Renders generated/flink_syslog.sql from the live endpoint. Nothing is sent to Confluent Cloud.
resource "local_file" "flink_syslog_sql" {
  filename = "${path.module}/generated/flink_syslog.sql"
  content = templatefile("${path.module}/flink_syslog.sql.tpl", {
    endpoint_url    = "https://${aws_cloudfront_distribution.slm.domain_name}/v1/chat/completions"
    connection_name = var.flink_connection_name
    model_name      = var.flink_model_name
    served_model    = var.serve_model_name
  })
}

output "flink_sql_file" {
  value = local_file.flink_syslog_sql.filename
}
