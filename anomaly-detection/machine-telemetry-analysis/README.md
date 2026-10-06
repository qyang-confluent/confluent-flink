# Machine Telemetry Anomaly Detection (Confluent Cloud Flink)

A reference implementation of anomaly detection on agricultural machine telemetry (CAN bus data) using **Confluent Cloud Flink SQL** and the built-in `ML_DETECT_ANOMALIES_ROBUST` / `ML_DETECT_ANOMALIES` functions.

Raw telemetry arrives as nested Avro messages, with one message holding an array of CAN signals (engine speed, load, torque, fuel rate, temperatures, hydraulics, and so on). The pipeline flattens that into per-equipment feature rows and flags unusual behavior against a rolling per-machine baseline.

## Pipeline

```
machine.telemetry            Avro topic, raw nested canData array
   │  UNNEST canData + pivot (1s TUMBLE on record time, append-only)
   ▼
machine_telemetry_flat       one wide row per message
   │  TUMBLE 10s, AVG/MAX per signal, scale to ~0-1 ranges, filter 'Working'
   ▼
machine_features_10s         one row per equipment per 10s
   ├─► machine_ad_test1      multivariate ML_DETECT_ANOMALIES_ROBUST (8 scaled features)
   └─► machine_rpm_anomaly   univariate ML_DETECT_ANOMALIES on engine speed
```

All four tables are Flink **materialized tables**, which are continuously running statements. Each is partitioned by `equipment_id`.

## Contents

| Path | Purpose |
|---|---|
| `machine-schema.avsc` | Avro schema for the raw topic (`TelemetryDataFrameValue`) |
| `machine-data.json` | Sample message conforming to the schema |
| `machine_telemetry_anomaly_preprocessing.md` | Design doc: why and how raw CAN data is turned into anomaly-detection features (windowing, aggregation, scaling, window sizing) |
| `cc-flink.sql` | The Flink SQL statements for the pipeline above |
| `deploy.sh` | Deploys `cc-flink.sql` with the Confluent CLI, one named statement at a time (redeployable) |
| `RUN_ANOMALY_DETECTION.md` | Step-by-step runbook, with known issues and troubleshooting |
| `shadowtraffic/` | [ShadowTraffic](https://shadowtraffic.io) configs to generate synthetic telemetry (single machine or a fleet via `gen_fleet.py`) |
| `terraform/` | Terraform alternative to `deploy.sh`: Kafka topic, Schema Registry, Flink compute pool, and the materialized tables |
| `CLAUDE.md` | Guidance for Claude Code when working in this directory |

## Quick start

1. **Generate data.** Fill in `shadowtraffic/confluent-cloud.env` and `shadowtraffic/license.env`, then:
   ```bash
   cd shadowtraffic && ./run.sh        # one machine
   ./run-fleet.sh                      # fleet of machines
   ```
   Data is emitted every 10 s per machine, so give the detectors some time to build a baseline.

2. **Deploy the pipeline.** Use one of the two paths for a given environment, not both:
   ```bash
   # Option A: Confluent CLI
   confluent login
   COMPUTE_POOL=lfcp-xxxx ENV_ID=env-xxxx DATABASE=<kafka-cluster-name> \
     CLOUD=aws REGION=us-east-1 ./deploy.sh

   # Option B: Terraform
   cd terraform
   cp terraform.tfvars.example terraform.tfvars   # then edit
   terraform init && terraform apply
   ```

3. **Inspect results** in the Flink SQL workspace:
   ```sql
   SELECT * FROM machine_ad_test1 WHERE anomaly.is_anomaly;
   SELECT * FROM machine_rpm_anomaly LIMIT 20;
   ```

See `RUN_ANOMALY_DETECTION.md` for the full walkthrough.

## Key design points

- **Pivot, not aggregate.** `MAX(CASE WHEN can_name = ... THEN value END)` is a pivot idiom. Each signal occurs once per message.
- **Event time** comes from `header.timeOfCreation`, not `timeOfReception`.
- **Tumble matches native cadence** (10 s). Widening it changes what an anomaly means.
- **Spike-prone signals** (engine speed) keep a peak column alongside the average.
- **Features are scaled** to comparable ranges before detection. The factors in `cc-flink.sql` are placeholders. Validate them per equipment model.
- **One operating state per detector.** Only `equipment_status = 'Working'` rows are scored, so idle, transport, and off states don't pollute the baseline.
- **`window` counts rows, not time.** With a 10 s tumble, `window = 30` is about a 5-minute baseline.
- **`canID` is a `STRING`** downstream, because real data contains malformed ID values.

## Prerequisites

- Confluent Cloud environment, Kafka cluster, Schema Registry (Stream Governance), and a Flink compute pool in the same region
- Confluent CLI v4+ (for `deploy.sh`) or Terraform (for `terraform/`)
- Docker and a ShadowTraffic license (for synthetic data)

## Notes

- `terraform/` contains local state files and credentials (`terraform.tfstate*`, `ccloud.env`, and `shadowtraffic/*.env`). Don't commit them.
