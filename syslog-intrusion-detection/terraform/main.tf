provider "aws" {
  region = var.region
}

# One GPU instance running vLLM. AMI must ship the Nvidia driver (e.g. Deep Learning Base AMI, Ubuntu).
resource "aws_instance" "slm" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  key_name               = var.key_name

  tags = {
    Name        = "syslog-slm"
    Environment = "Dev"
  }

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    model_id       = var.hf_model_id
    revision       = var.hf_revision
    hf_token       = var.hf_token
    api_key        = var.serve_api_key
    vllm_version   = var.vllm_version
    max_model_len  = var.max_model_len
    max_new_tokens = var.max_new_tokens
    served_name    = var.serve_model_name
    serve_port     = var.serve_port
  })
  # user_data only runs on first boot; replacement changes the public DNS (and therefore the CloudFront origin).
  user_data_replace_on_change = var.replace_on_user_data_change
}

output "instance_public_dns" {
  value = aws_instance.slm.public_dns
}
