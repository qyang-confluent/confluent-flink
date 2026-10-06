#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

docker run --rm \
  --env-file license.env \
  --env-file confluent-cloud.env \
  -v "$PWD/shadowtraffic_machine_fleet20.json:/home/config/config.json:ro" \
  -v "$PWD/TelemetryDataFrameValue.avsc:/home/config/TelemetryDataFrameValue.avsc:ro" \
  shadowtraffic/shadowtraffic:latest \
  --config /home/config/config.json


