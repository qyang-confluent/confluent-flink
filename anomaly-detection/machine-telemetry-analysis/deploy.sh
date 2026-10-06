#!/usr/bin/env bash
# Deploy cc-flink.sql to Confluent Cloud Flink, one statement at a time, in file order.
# This is the CLI equivalent of terraform/ (which deploys the same tables as
# confluent_flink_materialized_table resources): the file drops the old materialized tables
# (downstream first), then creates them with CREATE MATERIALIZED TABLE. Use one path or the
# other for a given environment, not both.
#
# Every statement in the file must be preceded by a line:  -- name: <statement-name>
# The name is used as the Flink statement name. Before deploying, any existing statement
# with one of those names is deleted, so the script can be re-run to redeploy.
#
# Usage:
#   COMPUTE_POOL=lfcp-xxxx ENV_ID=env-xxxx DATABASE=<kafka-cluster-name> \
#     [CLOUD=aws REGION=us-east-1] ./deploy.sh [file.sql]
#
# CLOUD/REGION are only needed if you have not run `confluent flink region use`.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

FILE="${1:-cc-flink.sql}"
: "${COMPUTE_POOL:?set COMPUTE_POOL (e.g. lfcp-xxxx)}"
: "${ENV_ID:?set ENV_ID (e.g. env-xxxx)}"
: "${DATABASE:?set DATABASE (Kafka cluster name)}"

REGION_ARGS=()
[ -n "${CLOUD:-}" ] && REGION_ARGS+=(--cloud "$CLOUD")
[ -n "${REGION:-}" ] && REGION_ARGS+=(--region "$REGION")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NAME_RE='^[[:space:]]*--[[:space:]]*name:'

# Drop plain comment lines (keep "-- name:" lines), then split on ";" into numbered files.
# Assumes no ";" inside string literals.
awk -v re="$NAME_RE" '$0 ~ re {print; next} /^[[:space:]]*--/ {next} {print}' "$FILE" \
  | awk -v dir="$TMP" -v RS=';' 'NF {printf "%s", $0 > sprintf("%s/stmt_%02d.sql", dir, ++n)}'

# Extract each statement's name; fail if one is missing.
for f in "$TMP"/stmt_*.sql; do
  name="$(grep -E -m1 "$NAME_RE" "$f" | sed -E 's/^.*name:[[:space:]]*//; s/[[:space:]]+$//' || true)"
  [ -n "$name" ] || { echo "ERROR: statement without '-- name:' in $(basename "$f"): $(tr -s '[:space:]' ' ' < "$f" | cut -c1-80)" >&2; exit 1; }
  echo "$name" > "${f%.sql}.name"
  grep -Ev "$NAME_RE" "$f" > "${f%.sql}.body" || true
done

# Phase 1: remove existing statements with these names (stops running ones).
echo "== Removing existing statements =="
for n in "$TMP"/stmt_*.name; do
  name="$(cat "$n")"
  if confluent flink statement delete "$name" --environment "$ENV_ID" "${REGION_ARGS[@]+"${REGION_ARGS[@]}"}" --force >/dev/null 2>&1; then
    echo "deleted: $name"
  else
    echo "not found (ok): $name"
  fi
done

# Phase 2: create statements in file order.
echo "== Deploying =="
for n in "$TMP"/stmt_*.name; do
  name="$(cat "$n")"
  body="${n%.name}.body"
  echo ">>> $name: $(tr -s '[:space:]' ' ' < "$body" | cut -c1-80)..."
  confluent flink statement create "$name" \
    --sql "$(cat "$body")" \
    --compute-pool "$COMPUTE_POOL" \
    --environment "$ENV_ID" \
    --database "$DATABASE" \
    "${REGION_ARGS[@]+"${REGION_ARGS[@]}"}" \
    --wait
done

echo "Done. List statements with:"
echo "  confluent flink statement list --compute-pool $COMPUTE_POOL"
