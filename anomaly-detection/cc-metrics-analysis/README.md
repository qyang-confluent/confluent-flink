# Confluent Cloud Kafka Metrics Anomaly Detection (Confluent Cloud Flink)

Anomaly detection on Confluent Cloud's own Kafka metrics, using **Confluent Cloud Flink SQL** and the built-in `ML_DETECT_ANOMALIES` function. The Confluent Telemetry source connector polls the Telemetry (Metrics v2) API and writes one record per metric sample to a topic. Flink turns that into per-series time series and flags unusual behavior.

The signals covered are listed in `confluent-cloud-kafka-anomaly-metrics.md`: throughput, consumer lag, throttling, producer latency, storage, cluster load, hot partitions, partition topology and rebalances.

## Pipeline

```
confluent-cloud-metrics      Avro topic written by the connector (long form: metric, timestamp, value, labels)
   │  strip name prefix, pick series key, 1 min TUMBLE on record time (append-only)
   ▼
cc_metrics_clean             one row per series per minute; series = (metric, kafka_id, entity)
   ├─► cc_metrics_anomaly    ML_DETECT_ANOMALIES (ARIMA) per series, continuous signals
   │      └─► cc_metrics_anomalies   flattened, anomalies only
   └─► cc_metrics_alerts     rules: cluster load, hot partitions, partition-count changes
```

All four tables are Flink **materialized tables** (continuously running statements) deployed by Terraform. `entity` is the identifying labels joined with `:` (topic, consumer group, principal, client, reason), or `cluster` when there is none.

| Detector | Signals |
|---|---|
| ARIMA (`cc_metrics_anomaly`) | `received_bytes`, `sent_bytes`, `request_count`/`request_bytes` (Produce only), `producer_latency_avg_milliseconds`, `consumer_lag_offsets`, `client_limit_milliseconds`, `retained_bytes`, `max_pending_rebalance_time_milliseconds` |
| Rules (`cc_metrics_alerts`) | cluster load 0.7 warning / 0.8 critical, `hot_partition_ingress`/`egress` = 1, `partition_count` changed |

## Contents

| Path | Purpose |
|---|---|
| `confluent-cloud-kafka-anomaly-metrics.md` | The signals to monitor and what each one detects |
| `confluentinc-kafka-connect-confluent-telemetry-0.2.0-SNAPSHOT.zip` | The prebuilt connector plugin |
| `DEPLOY.md`, `deploy.sh` | Deploy the connector with the Confluent CLI |
| `terraform/` | Terraform for the custom plugin, the connector and the Flink tables |
| `terraform/sql/` | The four Flink queries (`clean`, `anomaly`, `anomalies`, `alerts`), loaded by `terraform/queries.tf` |
| `CLAUDE.md` | Guidance for Claude Code when working in this directory |

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # environment, cluster, service account, resource_ids, ...
./run.sh                                       # exports TF_VAR_telemetry_api_key/secret from the Cloud API key, then plan + apply
```

Set `compute_pool_id` in `terraform.tfvars` to reuse an existing Flink compute pool. Left empty, Terraform creates one. `min_training_size` (default 30) and `confidence_percentage` (default 99.0) tune the detector.

## Known limits

- **Not every metric is on the topic.** Only some metrics were present when this was written (`received_bytes`, `retained_bytes`, `producer_latency_avg_milliseconds` and the request metrics). The rest give empty series until the connector emits them (check `telemetry.resource.ids` and `telemetry.dataset`). Label keys for those are assumed from the Metrics API.
- **Warm-up.** Samples arrive about once a minute, so each series needs about 30 minutes before it reports anything.
- **Cluster load scale.** The rules assume a 0-1 ratio. Change the thresholds in `terraform/sql/alerts.sql` if your data is 0-100.
- **Cardinality.** Each client, principal and consumer group gets its own ARIMA state, which costs CFUs.

## Checking for anomalies

Run these in the Flink shell or the Cloud Console workspace. Sorting a streaming table with `ORDER BY ... DESC` may be rejected or keep running; if so use `ORDER BY window_time`.

Latest anomalies, with direction and distance from the forecast:

```sql
SELECT
  window_time,
  metric,
  entity,
  metric_value,
  forecast_value,
  lower_bound,
  upper_bound,
  CASE WHEN metric_value > upper_bound THEN 'above' ELSE 'below' END AS direction,
  ROUND(metric_value - forecast_value, 2) AS deviation
FROM `cc_metrics_anomalies`
WHERE window_time > CURRENT_TIMESTAMP - INTERVAL '1' HOUR
ORDER BY window_time DESC
LIMIT 50;
```

Which signals fire most:

```sql
SELECT metric, entity, COUNT(*) AS anomaly_count, MAX(window_time) AS last_seen
FROM `cc_metrics_anomalies`
GROUP BY metric, entity
ORDER BY anomaly_count DESC;
```

Rule-based alerts:

```sql
SELECT window_time, alert, severity, metric, entity, metric_value
FROM `cc_metrics_alerts`
ORDER BY window_time DESC
LIMIT 50;
```
