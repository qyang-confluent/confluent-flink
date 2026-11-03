#!/usr/bin/env bash
# Run Logstash in the FOREGROUND (Ctrl-C to stop) with syslog-to-confluent.conf.
# Use this instead of the systemd service for demos/debugging; stop the service first if it is running:
#   sudo systemctl stop logstash
#
# Usage:  ./start_logstash.sh [env_file]
#   env_file  file with CCLOUD_BOOTSTRAP_SERVERS and CCLOUD_SASL_JAAS_CONFIG
#             (default: ~/vault/ccloud/dsp-sandbox.env, or ./logstash.env if it exists)
# Overrides: LOGSTASH_HOME (default /usr/share/logstash), DATA_DIR (default /var/lib/logstash/foreground)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/syslog-to-confluent.conf"
LOGSTASH_HOME="${LOGSTASH_HOME:-/usr/share/logstash}"
DATA_DIR="${DATA_DIR:-/var/lib/logstash/foreground}"

if [[ $# -ge 1 ]]; then
  ENV_FILE="$1"
elif [[ -f "$HERE/logstash.env" ]]; then
  ENV_FILE="$HERE/logstash.env"
else
  ENV_FILE="$HOME/vault/ccloud/dsp-sandbox.env"
fi
[[ -f "$ENV_FILE" ]] || { echo "env file not found: $ENV_FILE" >&2; exit 1; }
[[ -x "$LOGSTASH_HOME/bin/logstash" ]] || { echo "logstash not found at $LOGSTASH_HOME/bin/logstash (set LOGSTASH_HOME)" >&2; exit 1; }

# Export the credentials so ${CCLOUD_*} references in the pipeline resolve.
set -a; source "$ENV_FILE"; set +a
: "${CCLOUD_BOOTSTRAP_SERVERS:?missing in $ENV_FILE}"
: "${CCLOUD_SASL_JAAS_CONFIG:?missing in $ENV_FILE}"

# Reading /var/log/syslog and auth.log needs root (or membership of group adm); the file input also
# writes its sincedb under /var/lib/logstash. -E keeps the exported credentials through sudo.
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo -E"

$SUDO mkdir -p "$DATA_DIR"

echo "Logstash (foreground) conf=$CONF env=$ENV_FILE data=$DATA_DIR"
# exec: Logstash becomes the foreground process, so Ctrl-C / SIGTERM shut it down cleanly.
# --config.reload.automatic: edit the .conf and it is picked up without restarting.
exec $SUDO "$LOGSTASH_HOME/bin/logstash" \
  -f "$CONF" \
  --path.data "$DATA_DIR" \
  --config.reload.automatic \
  --log.level info
