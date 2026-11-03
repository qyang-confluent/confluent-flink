variable "region" {
  type    = string
  default = "us-east-1"
}

# Defaults below are the author's sandbox account (same as credit-card-fraud/terraform/aws). Override for yours.
variable "ami_id" {
  type    = string
  default = "ami-012ba162b9cd2729c"
}

variable "instance_type" {
  type    = string
  default = "g5.xlarge" # 1x A10G 24 GB: fits a 3B model in bf16 with plenty of KV cache
}

variable "subnet_id" {
  type    = string
  default = "subnet-023945ae06219d8ca"
}

variable "security_group_id" {
  type        = string
  default     = "sg-0b6e033028d61f10d"
  description = "Must allow inbound TCP on serve_port (CloudFront origin) and SSH from you"
}

variable "key_name" {
  type    = string
  default = "qyang-confluent"
}

variable "hf_model_id" {
  type        = string
  default     = "Qwen/Qwen2.5-3B-Instruct"
  description = "Off-the-shelf instruct SLM from Hugging Face (public). Alternatives: meta-llama/Llama-3.2-3B-Instruct (gated), ibm-granite/granite-3.3-2b-instruct, microsoft/Phi-3.5-mini-instruct"
}

variable "hf_revision" {
  type    = string
  default = "main"
}

variable "hf_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Only needed for gated/private repos. Stored in Terraform state and user_data: use a read-only token via TF_VAR_hf_token."
}

variable "vllm_version" {
  type    = string
  default = "0.10.2"
}

variable "max_model_len" {
  type        = number
  default     = 8192
  description = "Context length. A window of log lines is packed into one prompt, so this is larger than the fraud demo"
}

variable "max_new_tokens" {
  type        = number
  default     = 160
  description = "Cap on the JSON verdict. Flink's ML_PREDICT cannot set it, so it is baked into the server's default generation config"
}

variable "serve_model_name" {
  type    = string
  default = "syslog-analyst"
}

variable "serve_api_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Bearer key vLLM requires (empty = public endpoint). Stored in state and user_data: use a throwaway via TF_VAR_serve_api_key."
}

variable "serve_port" {
  type    = number
  default = 8080
}

variable "replace_on_user_data_change" {
  type    = bool
  default = false
}

output "serve_url" {
  value       = local.vllm ? "http://${aws_instance.slm[0].public_dns}:${var.serve_port}" : null
  description = "Direct vLLM URL (first boot ~10 min: pip install vllm + model download + load)"
}
