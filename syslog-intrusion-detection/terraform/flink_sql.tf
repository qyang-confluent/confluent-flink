terraform {
  required_providers {
    local = {
      source = "hashicorp/local"
    }
    confluent = {
      source  = "confluentinc/confluent"
      version = "~> 2.0"
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

variable "slm_backend" {
  description = "vllm = self-hosted Qwen on EC2 GPU (needs the AWS resources); managed = Confluent Cloud managed model (no GPU, no AWS)."
  type        = string
  default     = "vllm"
  validation {
    condition     = contains(["vllm", "managed"], var.slm_backend)
    error_message = "slm_backend must be vllm or managed."
  }
}

variable "managed_model" {
  description = "Managed model name (without the system. prefix); run SHOW MODELS in Flink to list the ones in your region."
  type        = string
  default     = "anthropic.claude-sonnet-4-6"
}

locals {
  vllm = var.slm_backend == "vllm"

  system_prompt = <<-EOT
You are a SOC analyst reviewing Linux syslog lines from one host over one minute, joined by the pipe character. Decide whether they show hacking activity: SSH or password brute force, credential stuffing, login from unusual source after many failures, privilege escalation (sudo or su abuse, new root or uid 0 accounts), port scanning, new persistence (cron jobs, ssh keys, systemd units, new users), log tampering, or reverse shells and malware download. Routine events (cron, DHCP, ntp, a few typos in passwords, normal sudo by admins) are benign. Reply with ONLY one JSON object and nothing else. The verdict value must be exactly attack or benign (never none). Use category none when benign. Keep reason under 15 words. Format: {"verdict":"attack|benign","category":"brute_force|privilege_escalation|recon|persistence|defense_evasion|exfil_or_c2|none","confidence":0.0-1.0,"reason":"short evidence"}
  EOT
}

# Renders generated/flink_syslog.sql. Nothing is sent to Confluent Cloud.
# managed: no connection, model provider `confluent`, called with AI_COMPLETE (input column `prompt`, output `response`).
resource "local_file" "flink_syslog_sql" {
  filename = "${path.module}/generated/flink_syslog.sql"
  content = templatefile("${path.module}/flink_syslog.sql.tpl", {
    backend         = var.slm_backend
    endpoint_url    = local.vllm ? "https://${aws_cloudfront_distribution.slm[0].domain_name}/v1/chat/completions" : ""
    connection_name = var.flink_connection_name
    model_name      = var.flink_model_name
    served_model    = var.serve_model_name
    managed_model   = var.managed_model
    system_prompt   = trimspace(local.system_prompt)
    predict_fn      = local.vllm ? "ML_PREDICT" : "AI_COMPLETE"
    in_col          = local.vllm ? "text" : "prompt"
    out_col         = local.vllm ? "verdict" : "response"
  })
}

output "flink_sql_file" {
  value = local_file.flink_syslog_sql.filename
}
