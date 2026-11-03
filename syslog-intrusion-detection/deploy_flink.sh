#!/usr/bin/env bash
# Deploys terraform/generated/flink_syslog.sql to Confluent Cloud Flink via the CLI (same approach as credit-card-fraud/start.sh):
# CREATE CONNECTION, CREATE MODEL, then the continuous CTAS as statements `syslog-windowing` and `syslog-scoring`. Re-runnable; the key never prints.
# Needs: confluent CLI logged in, ~/vault/aws/syslog-serve.key, ~/vault/ccloud/dsp-flink.env.  Usage: ./deploy_flink.sh
cd "$(dirname "$0")/terraform" || exit 1

FLINK_ENV=~/vault/ccloud/dsp-flink.env   # defines ENV_ID, POOL, DB (environment, compute pool, Kafka cluster/database)
[ -f $FLINK_ENV ] || { echo "missing $FLINK_ENV" >&2; exit 1; }
set -a; source $FLINK_ENV; set +a
: "${ENV_ID:?set ENV_ID in $FLINK_ENV}" "${POOL:?set POOL in $FLINK_ENV}" "${DB:?set DB in $FLINK_ENV}"


export SERVE_KEY=$(cat ~/vault/aws/syslog-serve.key)
flink_sql() { # <sql> [name]
  local out name=(); [ -n "$2" ] && name=("$2")
  out=$(confluent flink statement create "${name[@]}" --environment $ENV_ID --compute-pool $POOL --database $DB --wait --sql "$1" 2>&1)
  echo "$out" | grep -E "Name  |Status  |Detail|rror" | cut -c1-200
  echo "$out" | grep -qE "Status +\| (COMPLETED|RUNNING)"
}
statements() { # <regex>: matching statements from the generated file, NUL-separated, secret substituted
  python3 - generated/flink_syslog.sql "$1" <<'PY'
import os, re, sys
s = re.sub(r'^\s*--.*$', '', open(sys.argv[1]).read(), flags=re.M)
s = s.replace("<API_KEY>", os.environ["SERVE_KEY"])
for st in re.split(r';[ \t]*\n', s):
    st = re.sub(r'\s+', ' ', st).strip().rstrip(';')
    if st and re.match(sys.argv[2], st): sys.stdout.write(st + "\0")
PY
}
while IFS= read -r -d '' st; do flink_sql "$st" || { echo "FAILED: ${st:0:80}"; exit 1; }; done < <(statements '^CREATE (CONNECTION|MODEL)')
start() { # <statement-name> <create-table regex>
  if confluent flink statement describe "$1" --environment $ENV_ID >/dev/null 2>&1; then echo "statement $1 exists (stop+delete it first to redeploy)"; return 0; fi
  local st; st=$(statements "$2" | tr -d '\0')
  flink_sql "$st" "$1" || { echo "FAILED to start $1: confluent flink statement exception list $1 --environment $ENV_ID"; exit 1; }
}
start syslog-windowing '^CREATE TABLE `syslog_windows`'
start syslog-scoring   '^CREATE TABLE `syslog_alerts`'
