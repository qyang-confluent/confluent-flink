# Syslog intrusion detection: SLM on vLLM + Confluent Cloud Flink SQL

```
sandbox syslog -> Confluent Cloud Kafka topic
   -> Flink SQL: 1-min tumbling window per host, pack lines into one prompt
   -> ML_PREDICT -> CloudFront (https) -> vLLM on EC2 g5.xlarge (Qwen2.5-3B-Instruct, zero-shot SOC-analyst prompt)
   -> JSON verdict parsed in Flink -> `syslog_alerts` topic
```

Same shape as `../credit-card-fraud/terraform/aws`, but the model is off-the-shelf (no training); the intelligence is the
system prompt in `CREATE MODEL` (`terraform/flink_syslog.sql.tpl`).

## Deploy

```
source ~/vault/aws/qyang1.env
export TF_VAR_serve_api_key=<throwaway key>
cd terraform && terraform init && terraform apply     # generates terraform/generated/flink_syslog.sql
```
First boot takes ~10 min (`journalctl -u syslog-serve` on the box). Then run `generated/flink_syslog.sql` statement by
statement in a Confluent Cloud Flink workspace (fill `<API_KEY>` and `<syslog_table>`). Tear down: `terraform destroy`
(GPU instance bills until then).

## Open items
- Deploy Flink with `./deploy_flink.sh` (two statements: `syslog-windowing`, `syslog-scoring`); results land in topic `syslog_alerts`.
- Per-minute windows catch rate-based attacks (brute force, scans) that single lines cannot show; trade-off is up to ~1 min latency.
- No labels yet: quality is judged by eye. Once the sandbox has known attack windows, add an eval script like `credit-card-fraud/terraform/aws/eval_endpoint.py`.
- If zero-shot quality is weak, next step is the distillation path from the fraud demo (LLM-teacher labels -> LoRA).
