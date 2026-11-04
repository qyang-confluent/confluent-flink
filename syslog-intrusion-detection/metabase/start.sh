#!/bin/bash
# Build and start Metabase on :3000, then add the data source (key/secret from terraform output) and the dashboard.
set -euo pipefail
cd "$(dirname "$0")"

for n in 1 2 3; do docker compose build && break || { [ "$n" = 3 ] && exit 1; echo "build failed, retrying"; }; done
docker compose up -d
echo -n "Waiting for Metabase"
until [ "$(curl -s localhost:3000/api/health)" = '{"status":"ok"}' ]; do echo -n .; sleep 5; done; echo

python3 setup.py
sleep 30   # let the schema sync finish before building cards
python3 build_dashboard.py
