#!/usr/bin/env bash
# Inverse of deploy_terraform.sh + deploy_flink.sh: stops/deletes the two Flink statements, then terraform destroy
# (GPU instance + CloudFront). By default the Flink tables/model/connection and the `syslog` topic are kept.
#   ./teardown.sh                 asks for confirmation
#   ./teardown.sh --yes           no prompt
#   ./teardown.sh --purge         ALSO drop from Confluent Cloud: model syslog_analyst, connection syslog_slm_conn (holds the
#                                 vLLM API key), tables syslog_alerts and syslog_windows (their topics and schemas go too).
#                                 The `syslog` source topic is never touched.
# Flags combine, e.g. ./teardown.sh --yes --purge
cd "$(dirname "$0")/terraform" || exit 1
YES=0; PURGE=0
for a in "$@"; do case $a in --yes) YES=1 ;; --purge) PURGE=1 ;; *) echo "unknown flag $a" >&2; exit 2 ;; esac; done
FLINK_ENV=~/vault/ccloud/dsp-flink.env   # defines ENV_ID, POOL, DB (environment, compute pool, Kafka cluster/database)
[ -f $FLINK_ENV ] || { echo "missing $FLINK_ENV" >&2; exit 1; }
set -a; source $FLINK_ENV; set +a
: "${ENV_ID:?set ENV_ID in $FLINK_ENV}"
[ $PURGE = 1 ] && : "${POOL:?set POOL in $FLINK_ENV}" "${DB:?set DB in $FLINK_ENV}"

if [ $YES = 0 ]; then
  msg="Destroy the GPU instance + CloudFront and stop Flink statements"
  [ $PURGE = 1 ] && msg="$msg, and DROP model/connection/tables syslog_analyst syslog_slm_conn syslog_windows syslog_alerts"
  read -r -p "$msg? Type 'teardown': " a; [ "$a" = teardown ] || { echo aborted; exit 1; }
fi

for n in syslog-scoring syslog-windowing; do
  confluent flink statement stop "$n" --environment $ENV_ID 2>&1 | tail -1
  confluent flink statement delete "$n" --environment $ENV_ID --force 2>&1 | tail -1
done

if [ $PURGE = 1 ]; then
  drop() { # <sql>: run one DDL statement, print its status line
    confluent flink statement create --environment $ENV_ID --compute-pool $POOL --database $DB --wait --sql "$1" 2>&1 \
      | grep -E "Status Detail|rror" | cut -c1-160 | sed "s|^|$1 -> |"
  }
  # dependency order: consumers of a table first, then the model, then the connection it uses
  drop 'DROP TABLE IF EXISTS `syslog_alerts`'
  drop 'DROP TABLE IF EXISTS `syslog_windows`'
  drop 'DROP MODEL IF EXISTS `syslog_analyst`'
  drop 'DROP CONNECTION IF EXISTS `syslog_slm_conn`'
fi

source ~/vault/aws/qyang1.env
export TF_VAR_serve_api_key=$(cat ~/vault/aws/syslog-serve.key)
terraform destroy -input=false -auto-approve
