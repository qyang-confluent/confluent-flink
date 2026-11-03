# Logstash: Ubuntu syslog -> Confluent Cloud

```bash
# 1. Topic (once)
confluent kafka topic create syslog --partitions 3

# 2. Logstash on the Ubuntu box (Elastic apt repo)
sudo apt install -y logstash
sudo usermod -aG adm logstash          # logstash must be able to read /var/log/syslog and auth.log
sudo mkdir -p /var/lib/logstash
sudo cp syslog-to-confluent.conf /etc/logstash/conf.d/
# credentials: use the vault file directly (only the two vars Logstash needs; Schema Registry vars are not used)
grep -E '^CCLOUD_(BOOTSTRAP_SERVERS|SASL_JAAS_CONFIG)=' ~/vault/ccloud/dsp-sandbox.env | sudo tee -a /etc/default/logstash >/dev/null
sudo chmod 600 /etc/default/logstash
sudo /usr/share/logstash/bin/logstash --path.settings /etc/logstash -t   # config test
sudo systemctl enable --now logstash

# 3. Verify
logger -p auth.warning "test sshd[1]: Failed password for root from 203.0.113.50 port 1 ssh2"
confluent kafka topic consume syslog --from-beginning
```

Each record is JSON: `{"@timestamp":..., "host":"ubuntu01", "message":"<raw line>", "source_file":"/var/log/syslog"}`.

## Flink side

The topic has no Schema Registry schema, so Confluent Cloud Flink exposes it as `key BYTES, val BYTES`. Define the
`host`/`message` view that `terraform/flink_syslog.sql.tpl` expects (use `syslog_src` as `<syslog_table>`):

```sql
CREATE VIEW `syslog_src` AS
SELECT
  JSON_VALUE(CAST(val AS STRING), '$.host')    AS host,
  JSON_VALUE(CAST(val AS STRING), '$.message') AS message,
  `$rowtime`
FROM `syslog`;
```
(If the pipeline fails on a view with `$rowtime`, use `CREATE TABLE ... AS SELECT` instead, or register a JSON_SR schema.)

Notes: the Kafka record timestamp is Logstash's send time; syslog timestamps are only used for `@timestamp` inside the JSON.
Logs from rsyslog forwarding (not file tailing) work too: swap the `file` input for `syslog { port => 5514 }`.

## Run in the foreground (no service)
```bash
sudo systemctl stop logstash                          # if the service is running
./start_logstash.sh                                   # Ctrl-C to stop
./start_logstash.sh ~/vault/ccloud/dsp-sandbox.env    # or pass an env file explicitly
```
The script loads `CCLOUD_BOOTSTRAP_SERVERS` / `CCLOUD_SASL_JAAS_CONFIG` from the env file (default: `./logstash.env`, else
`~/vault/ccloud/dsp-sandbox.env`), runs `syslog-to-confluent.conf` under `sudo -E` with its own data dir
(`/var/lib/logstash/foreground`, override with `DATA_DIR`), and reloads the config automatically when it changes.
Set `LOGSTASH_HOME` if Logstash is not in `/usr/share/logstash`.
