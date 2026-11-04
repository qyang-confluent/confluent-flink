#!/usr/bin/env bash
# Install rsyslog's Kafka output on this Ubuntu box and point it at Confluent Cloud.
# Usage: ./install.sh [env-file]   (default: ./rsyslog.env, else ~/vault/ccloud/dsp-sandbox.env)
# Env vars (same names as ../logstash): CCLOUD_BOOTSTRAP_SERVERS, CCLOUD_SASL_JAAS_CONFIG; optional TOPIC (default syslog).
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="${1:-}"
if [[ -z "$ENV_FILE" ]]; then
  if [[ -f ./rsyslog.env ]]; then ENV_FILE=./rsyslog.env; else ENV_FILE="$HOME/vault/ccloud/dsp-sandbox.env"; fi
fi
[[ -f "$ENV_FILE" ]] || { echo "env file not found: $ENV_FILE" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a
: "${CCLOUD_BOOTSTRAP_SERVERS:?}" "${CCLOUD_SASL_JAAS_CONFIG:?}"
TOPIC="${TOPIC:-syslog}"

# Pull username/password out of: ...PlainLoginModule required username='KEY' password='SECRET';
API_KEY=$(sed -nE "s/.*username=['\"]([^'\"]+)['\"].*/\1/p" <<<"$CCLOUD_SASL_JAAS_CONFIG")
API_SECRET=$(sed -nE "s/.*password=['\"]([^'\"]+)['\"].*/\1/p" <<<"$CCLOUD_SASL_JAAS_CONFIG")
[[ -n "$API_KEY" && -n "$API_SECRET" ]] || { echo "could not parse username/password from CCLOUD_SASL_JAAS_CONFIG" >&2; exit 1; }

sudo apt-get update -qq
sudo apt-get install -y rsyslog rsyslog-kafka

# Render the template (bash substitution, so secrets with special characters are safe).
# $1 = key lines to splice in (per-host Kafka key, or empty).
DEST=/etc/rsyslog.d/60-confluent.conf
render() {
  local conf; conf=$(<60-confluent.conf.tpl)
  conf=${conf//@@BOOTSTRAP@@/$CCLOUD_BOOTSTRAP_SERVERS}
  conf=${conf//@@TOPIC@@/$TOPIC}
  conf=${conf//@@API_KEY@@/$API_KEY}
  conf=${conf//@@API_SECRET@@/$API_SECRET}
  conf=${conf//@@KEY@@/$1}
  printf '%s\n' "$conf" | sudo install -m 600 -o root -g root /dev/stdin "$DEST"
}

# Try the per-host Kafka key first; older rsyslog (omkafka without dynaKey) rejects it, then fall back to no key.
render '    key="ccloud_key"
    dynaKey="on"'
if ! sudo rsyslogd -N1; then
  echo "rsyslog rejected the Kafka key settings (old version?); installing without a key" >&2
  render ''
  sudo rsyslogd -N1                     # still failing -> real config error, abort (set -e)
fi
sudo systemctl restart rsyslog
echo "Done. Test:"
echo "  logger -p auth.warning \"test sshd[1]: Failed password for root from 203.0.113.50 port 1 ssh2\""
echo "  confluent kafka topic consume $TOPIC --from-beginning"
