# rsyslog -> Confluent Cloud Kafka (topic `syslog`, plain JSON, no Schema Registry).
# Rendered by install.sh into /etc/rsyslog.d/60-confluent.conf (mode 600, contains the API secret). Do not edit @@...@@ by hand.
#
# Output contract (same as ../logstash, read by terraform/flink_syslog.sql.tpl):
#   {"@timestamp":"<rfc3339>","host":"<hostname>","message":"<raw line, as written to /var/log/syslog>"}

module(load="omkafka")

# `message` mimics the line rsyslog writes to /var/log/syslog (ISO8601 ts, host, tag, text) so the SLM sees the same text
# as with the Logstash file input. JSON escaping is done per property (format="json").
template(name="ccloud_json" type="list") {
  constant(value="{\"@timestamp\":\"")
  property(name="timereported" dateFormat="rfc3339")
  constant(value="\",\"host\":\"")
  property(name="hostname" format="json")
  constant(value="\",\"message\":\"")
  property(name="timereported" dateFormat="rfc3339")
  constant(value=" ")
  property(name="hostname" format="json")
  constant(value=" ")
  property(name="syslogtag" format="json")
  property(name="msg" format="json" spifno1stsp="on" droplastlf="on")
  constant(value="\"}")
}

# Skip rsyslogd's own messages: omkafka/librdkafka errors are logged via syslog and would feed back into the topic.
if ($programname != "rsyslogd") then {
  action(
    type="omkafka"
    broker=["@@BOOTSTRAP@@"]
    topic="@@TOPIC@@"
    template="ccloud_json"
    # key="%hostname%"   # same host -> same partition; needs rsyslog >= 8.2204 (omkafka `key`)
    confParam=[
      "security.protocol=sasl_ssl",
      "sasl.mechanisms=PLAIN",
      "sasl.username=@@API_KEY@@",
      "sasl.password=@@API_SECRET@@",
      "ssl.ca.location=/etc/ssl/certs/ca-certificates.crt",
      "socket.keepalive.enable=true",
      "queue.buffering.max.ms=500"
    ]
    # Buffer on disk while the cluster is unreachable, so lines survive restarts and network blips.
    queue.type="LinkedList"
    queue.filename="ccloud_fwd"
    queue.maxDiskSpace="256m"
    queue.saveOnShutdown="on"
    queue.size="20000"
    action.resumeRetryCount="-1"
    action.resumeInterval="10"
  )
}
