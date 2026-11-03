#!/usr/bin/env bash
# Deploys the model server: g5.xlarge GPU + vLLM + CloudFront (https) + generated terraform/generated/flink_syslog.sql,
# then waits until vLLM answers. Re-runnable (terraform is idempotent). Starts a BILLING GPU instance: stop it with ./teardown.sh.
#
#   ./deploy_terraform.sh          plan, ask for confirmation, apply, wait for the endpoint
#   ./deploy_terraform.sh --yes    no prompt
#
# Needs: terraform, curl, ~/vault/aws/qyang1.env. The vLLM bearer key is created once in ~/vault/aws/syslog-serve.key
# (throwaway; it lands in Terraform state and EC2 user_data). Add a read-only HF token only for gated models:
#   export TF_VAR_hf_token=...
cd "$(dirname "$0")/terraform" || exit 1
set -o pipefail
YES=0; [ "$1" = "--yes" ] && YES=1
KEY_FILE=~/vault/aws/syslog-serve.key

[ -f ~/vault/aws/qyang1.env ] || { echo "missing ~/vault/aws/qyang1.env" >&2; exit 1; }
source ~/vault/aws/qyang1.env
[ -s $KEY_FILE ] || ( umask 077; openssl rand -hex 24 > $KEY_FILE )
export TF_VAR_serve_api_key=$(cat $KEY_FILE)

terraform init -input=false >/dev/null || exit 1
terraform plan -input=false -out=plan || exit 1
if [ $YES = 0 ]; then
  read -r -p "Apply (starts a billing GPU instance)? Type 'apply': " a; [ "$a" = apply ] || { echo aborted; exit 1; }
fi
terraform apply -input=false plan || exit 1   # CloudFront takes ~5-10 min

URL=$(terraform output -raw serve_https_url)
echo "endpoint: $URL ; waiting for vLLM (first boot ~10-15 min: pip install vllm + model download + load)"
for i in $(seq 1 120); do
  c=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $TF_VAR_serve_api_key" "$URL/v1/models")
  [ "$c" = 200 ] && { echo "endpoint is up"; echo "next: ../deploy_flink.sh"; exit 0; }
  sleep 15
done
echo "endpoint not up after 30 min; on the box: sudo tail -50 /var/log/serve-bootstrap.log; sudo journalctl -u syslog-serve -n 30" >&2
exit 1
