#!/usr/bin/env bash
# Produces to ${TELEMETRY_TOPIC} (default: machine_telemetry). Override with:
#   TELEMETRY_TOPIC=<topic> ./run.sh
# The value schema subject used is <topic>-value, so register the schema under that subject.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

TELEMETRY_TOPIC="${TELEMETRY_TOPIC:-machine_telemetry}"
CONFIG="$(mktemp "$PWD/.config.XXXXXX")"
trap 'rm -f "$CONFIG"' EXIT
sed "s|\${TELEMETRY_TOPIC}|$TELEMETRY_TOPIC|g" shadowtraffic_machine_telemetry.json > "$CONFIG"

docker run --rm \
  --env-file license.env \
  --env-file confluent-cloud.env \
  -v "$CONFIG:/home/config/config.json:ro" \
  -v "$PWD/TelemetryDataFrameValue.avsc:/home/config/TelemetryDataFrameValue.avsc:ro" \
  shadowtraffic/shadowtraffic:latest \
  --config /home/config/config.json
