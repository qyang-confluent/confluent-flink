# rsyslog: Ubuntu syslog -> Confluent Cloud

Alternative to `../logstash`: rsyslog (already on Ubuntu) forwards every syslog message to topic `syslog` through its
`omkafka` module. Same record shape, so the Flink SQL is unchanged:
`{"@timestamp":..., "host":"ubuntu01", "message":"<raw line>"}`. Use one forwarder per host, not both (duplicates).

```bash
# 1. Topic (once, skip if Logstash already created it)
confluent kafka topic create syslog --partitions 3

# 2. On the Ubuntu box: installs rsyslog-kafka, renders /etc/rsyslog.d/60-confluent.conf (mode 600), restarts rsyslog
./install.sh                          # uses ./rsyslog.env, else ~/vault/ccloud/dsp-sandbox.env
                                      # (needs CCLOUD_BOOTSTRAP_SERVERS and CCLOUD_SASL_JAAS_CONFIG; optional TOPIC)

# 3. Verify
logger -p auth.warning "test sshd[1]: Failed password for root from 203.0.113.50 port 1 ssh2"
confluent kafka topic consume syslog --from-beginning
```

The API key needs WRITE on the topic. Copy `../logstash/logstash.env.example` to `rsyslog.env` if you don't use the vault file.

## Notes
- Ubuntu's rsyslog applies the rule to all local messages (the rule file sorts after `50-default.conf`, which does not stop
  processing), so it covers what lands in `/var/log/syslog` and `auth.log` (sshd, sudo, cron, kernel via imklog).
- `rsyslogd`'s own messages are skipped: librdkafka errors are logged via syslog and would otherwise loop into the topic.
- Messages are buffered in a disk queue (`/var/spool/rsyslog/ccloud_fwd*`, 256 MB) while Confluent Cloud is unreachable.
- Debug: `sudo journalctl -u rsyslog -f`, or `sudo rsyslogd -N1`. SASL/auth errors show up there as `omkafka` failures.
- `omkafka`'s `key` (per-host partitioning) is commented out in the template: it needs rsyslog >= 8.2204. Windows are
  grouped by `host` in Flink regardless, so it only affects partition spread.
- Receiving remote hosts' syslog (UDP/TCP 514 via `imudp`/`imtcp`) works with the same output: `host` is then the sender's hostname.
- Untested end to end: written without access to the Ubuntu box. Run step 3 and check `rsyslogd -N1` output first.
