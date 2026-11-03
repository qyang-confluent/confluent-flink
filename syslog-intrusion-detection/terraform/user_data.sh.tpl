#!/bin/bash
# First boot only (cloud-init, root). Log: /var/log/serve-bootstrap.log ; service log: journalctl -u syslog-serve
exec > >(tee -a /var/log/serve-bootstrap.log) 2>&1
set -x

APT="apt -o DPkg::Lock::Timeout=900"   # unattended-upgrades holds the dpkg lock after first boot
$APT update -y
$APT install -y "python$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')-venv"

nvidia-smi || { echo "no GPU driver found: use a GPU AMI (Deep Learning AMI)"; exit 1; }

python3 -m venv /opt/vllm
/opt/vllm/bin/pip install --upgrade pip
/opt/vllm/bin/pip install "vllm==${vllm_version}" "transformers<5"

umask 077
cat > /etc/syslog-serve.env <<ENV
HF_HOME=/home/ubuntu/hf
%{ if hf_token != "" ~}
HF_TOKEN=${hf_token}
%{ endif ~}
%{ if api_key != "" ~}
VLLM_API_KEY=${api_key}
%{ endif ~}
ENV
umask 022
mkdir -p /home/ubuntu/hf && chown ubuntu:ubuntu /home/ubuntu/hf

sudo -u ubuntu env HF_HOME=/home/ubuntu/hf %{ if hf_token != "" ~}HF_TOKEN=${hf_token} %{ endif ~}/opt/vllm/bin/python -c "from huggingface_hub import snapshot_download as s; s('${model_id}', revision='${revision}', local_dir='/home/ubuntu/model', allow_patterns=['*.json','*.txt','*.safetensors','*.model','*.tiktoken'])"

# Flink cannot set generation params, so defaults live here: deterministic, short JSON verdict.
cat > /etc/systemd/system/syslog-serve.service <<UNIT
[Unit]
Description=Syslog analyst SLM (vLLM)
After=network-online.target

[Service]
User=ubuntu
EnvironmentFile=/etc/syslog-serve.env
ExecStart=/opt/vllm/bin/vllm serve /home/ubuntu/model \\
  --served-model-name ${served_name} --host 0.0.0.0 --port ${serve_port} \\
  --dtype auto --max-model-len ${max_model_len} --gpu-memory-utilization 0.90 \\
  --override-generation-config '{"temperature":0,"max_new_tokens":${max_new_tokens}}'
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now syslog-serve
