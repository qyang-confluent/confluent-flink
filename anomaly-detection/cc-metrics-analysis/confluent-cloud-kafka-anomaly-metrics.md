# Confluent Cloud Kafka Anomaly Detection Metrics

| Area | Metrics/signals | Detects |
|---|---|---|
| Cluster capacity | Cluster load: average and maximum | Saturation; sustained values above 70–80% may indicate capacity risk. |
| Throughput | `io.confluent.kafka.server/received_bytes` and `sent_bytes`, grouped by topic or principal | Traffic spikes, drops, or unexpected producer/consumer behavior. |
| Consumer health | `io.confluent.kafka.server/consumer_lag_offsets`; consumer latency | Stuck or slow consumers, growing backlog, processing delays. |
| Throttling | `io.confluent.kafka.server/client_limit_milliseconds`, grouped by principal and reason | Quota violations, cluster saturation, hot partitions, or skewed traffic. |
| Producer performance | `io.confluent.kafka.server/producer_latency_avg_milliseconds` | Increased broker-side produce latency. |
| Hot partitions | `hot_partition_ingress` and `hot_partition_egress` | Uneven key distribution or overloaded partitions. A value of `1` indicates a hot partition. |
| Storage/retention | `io.confluent.kafka.server/retained_bytes` | Unexpected retention growth or storage pressure. |
| Partition topology | Partition count and sudden partition changes | Deployment/configuration anomalies or scaling events. |
| Consumer-group stability | `max_pending_rebalance_time_milliseconds` | Frequent or prolonged rebalances causing lag spikes. |
