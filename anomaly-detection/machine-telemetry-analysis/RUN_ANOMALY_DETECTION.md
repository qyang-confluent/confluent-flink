# Running the Machine Anomaly Detection Pipeline on Confluent Cloud Flink

This guide explains how to run the statements in `cc-flink.sql` (or the equivalent Terraform in `terraform/`) to detect anomalies in machine telemetry. Design background is in `machine_telemetry_anomaly_preprocessing.md`.

## Pipeline overview

```
machine.telemetry (Avro topic, raw nested CAN data)
        │  machine_telemetry_flat: UNNEST canData + pivot, 1s TUMBLE on record time (continuous)
        ▼
machine_telemetry_flat (one wide row per message, watermark = event_ts - 5s)
        │  machine_features_10s: TUMBLE 10s + scaling, state = 'Working' (continuous)
        ▼
machine_features_10s (one row per equipment per 10s)
        ├─ machine_ad_test1      – multivariate ML_DETECT_ANOMALIES_ROBUST
        └─ machine_rpm_anomaly   – univariate ML_DETECT_ANOMALIES on engine speed
```

All four tables are **materialized tables** (`CREATE MATERIALIZED TABLE … AS SELECT`), each backed by its own long-running Flink statement, hash-distributed by `equipment_id` into 6 buckets. They must be created in order, since each reads the previous one.

## Two ways to deploy

Use one path per environment, not both.

| Path | Use when |
|---|---|
| **A. `deploy.sh`** (Confluent CLI) | You already have a compute pool, topic and schema, and just want to deploy `cc-flink.sql` |
| **B. `terraform/`** | You also want the compute pool, API keys, `machine.telemetry` topic and its schema created for you |
| **C. Statements by hand** | You want to step through and inspect each table in a SQL workspace |

## Prerequisites

- A Confluent Cloud environment, Kafka cluster, Schema Registry (Stream Governance enabled) and a Flink compute pool in the same region.
- Confluent CLI v4+ (`brew install confluentinc/tap/cli`), logged in, for paths A and C. Or use the Flink SQL workspace in the Cloud Console.
- Terraform, for path B.
- Docker, for the ShadowTraffic data generator (a license in `shadowtraffic/license.env`).
- `shadowtraffic/confluent-cloud.env` filled in with `CCLOUD_BOOTSTRAP_SERVERS`, `CCLOUD_SASL_JAAS_CONFIG`, `CCLOUD_SR_URL`, `CCLOUD_SR_USER_INFO`. With path B, `terraform apply` writes connection settings to `terraform/ccloud.env` (see the `env_file` variable) that you can copy from.
- The Flink SQL catalog/database must be your environment/cluster: `USE CATALOG <env-name>; USE <cluster-name>;`.

## Step 1 – Generate telemetry

The raw topic is `machine.telemetry`. If you have no live data, produce synthetic data:

```bash
cd shadowtraffic
./run.sh          # one machine  (shadowtraffic_machine_telemetry.json)
./run-fleet.sh    # many machines (shadowtraffic_machine_fleet20.json)
```

The fleet config is produced from the single-machine one by `gen_fleet.py`. Each machine gets its own VIN/serial, location, and a per-machine baseline (seeded scale factors), so per-equipment detectors learn different normals. Edit `N` in the script and re-run `python3 gen_fleet.py` to change the fleet size.

Each generator emits up to 1000 events with a 10 s throttle (`maxEvents: 1000`, `throttleMs: 10000`), matching the 10 s native cadence. That is ~2.8 hours of data per machine, produced in real time.

Anomaly detection needs a baseline before it flags anything, so let it run for a while (see "Baseline timing" below). Confirm data is arriving:

```bash
confluent kafka topic consume machine.telemetry --from-beginning \
  --value-format avro --schema-registry-endpoint <SR_URL> | head
```

or open the topic in the Cloud Console → Message viewer.

## Step 2 – Deploy

### Path A – `deploy.sh` (CLI)

`deploy.sh` splits `cc-flink.sql` on `;` and submits each statement in order with `--wait`:

```bash
confluent login
COMPUTE_POOL=<lfcp-id> ENV_ID=<env-id> DATABASE=<kafka-cluster-name> ./deploy.sh
# add CLOUD=aws REGION=us-east-1 if you haven't run `confluent flink region use`
```

Every statement in `cc-flink.sql` is preceded by a `-- name: <statement-name>` line (lowercase letters, digits, hyphens). The script uses it as the Flink statement name:

| Statement name | What it does |
|---|---|
| `machine-drop-rpm-anomaly` | `DROP MATERIALIZED TABLE IF EXISTS machine_rpm_anomaly` |
| `machine-drop-ad-test1` | `DROP MATERIALIZED TABLE IF EXISTS machine_ad_test1` |
| `machine-drop-features-10s` | `DROP MATERIALIZED TABLE IF EXISTS machine_features_10s` |
| `machine-drop-telemetry-flat` | `DROP MATERIALIZED TABLE IF EXISTS machine_telemetry_flat` |
| `machine-create-telemetry-flat` | create the flat table: UNNEST + pivot (continuous) |
| `machine-features-10s` | 10 s features (continuous) |
| `machine-ad-test1` | multivariate anomaly detection (continuous) |
| `machine-rpm-anomaly` | RPM anomaly detection (continuous) |

The drops run first, downstream tables first, so the file can be redeployed from scratch.

**Redeploys:** before creating anything, the script deletes any existing statement with these names, which stops running ones, and then creates them again. You don't need to remove old statements by hand. A statement without a `-- name:` line makes the script stop before it deploys anything. Names that don't exist yet show as `not found (ok)`.

The script stops at the first failed statement; check it with `confluent flink statement exception list <name>`. It assumes no `;` appears inside a string literal in the SQL file.

### Path B – Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set environment_id, kafka_cluster_name, service_account_id, cloud, region
terraform init
terraform apply
```

This creates:

- the Flink compute pool (`compute_pool_name`, `max_cfu`) and a Flink API key owned by the service account,
- the `machine.telemetry` topic and registers its value schema from `machine-schema.avsc`,
- the four materialized tables as `confluent_flink_materialized_table` resources, chained with `depends_on`: `machine_telemetry_flat` → `machine_features_10s` → the downstream anomaly tables.

The queries live in `terraform/queries.tf`. To add another downstream detector, add an entry to `local.downstream_queries`. The service account needs `FlinkDeveloper`, read on `machine.telemetry`, and write on the output topics and schemas.

`terraform output materialized_tables` lists the deployed tables. Keep `cc-flink.sql` and `queries.tf` in sync, since they define the same queries.

### Path C – Statements by hand (shell or workspace)

Either use the Cloud Console (**Environments → your env → Flink → Open SQL workspace**), or the CLI:

```bash
confluent environment use <env-id>
confluent flink shell --compute-pool <lfcp-id> --environment <env-id>
```

Then set the context:

```sql
USE CATALOG `<environment-name>`;
USE `<cluster-name>`;
```

Check that the source table is visible:

```sql
DESCRIBE `machine.telemetry`;
SELECT * FROM `machine.telemetry` LIMIT 5;
```

Run each statement from `cc-flink.sql` separately and in order, since the shell and workspace execute one statement at a time. Wait for each to reach `RUNNING` before starting the next. The sections below describe what each does.

## What each statement does

### Drops (top of file)

`cc-flink.sql` starts with four `DROP MATERIALIZED TABLE IF EXISTS` statements (downstream first). Dropping a table does not stop a statement that is still writing to it, so first delete the old streaming statements (`deploy.sh` does this for you; by hand use `confluent flink statement delete <name>`). Dropping the tables also deletes their topics and schemas.

### `machine_telemetry_flat` – UNNEST + pivot

```sql
CREATE MATERIALIZED TABLE `machine_telemetry_flat` (
  WATERMARK FOR `event_ts` AS `event_ts` - INTERVAL '5' SECOND
)
DISTRIBUTED BY HASH(`equipment_id`) INTO 6 BUCKETS
AS
WITH telemetry_long AS ( … CROSS JOIN UNNEST(r.body.canData) … )
SELECT … FROM TABLE(TUMBLE(TABLE telemetry_long, DESCRIPTOR(row_ts), INTERVAL '1' SECOND))
GROUP BY window_start, window_end, message_id, equipment_id, event_ts;
```

- Explodes `canData` into one row per signal, then pivots into columns with `MAX(CASE WHEN can_name = … THEN value END)`. `MAX` is only a pivot idiom; each signal occurs once per message.
- A plain `GROUP BY` would emit updates. The pivot therefore runs inside a 1 s `TUMBLE` on the Kafka record time (`$rowtime`). All signals of a message share one `$rowtime`, so each message falls in one window and the output is append-only. Flat rows appear about 1 s plus the watermark delay after the message arrives.
- `event_ts` is parsed from `header.timeOfCreation` and is the watermark column.

Verify:

```sql
SHOW CREATE MATERIALIZED TABLE machine_telemetry_flat;
SELECT * FROM machine_telemetry_flat LIMIT 10;
```

Check that signal columns are populated (not all `NULL`). All-NULL columns usually mean the `can_name` string does not match the payload (names are case-sensitive; check `machine-data.json`).

**Timestamp format.** The pattern `'yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''` only parses timestamps with exactly 3 fractional digits and a literal `Z`. If `event_ts` is `NULL` for every row, compare against a real `header.timeOfCreation` value and adjust the pattern (e.g. `SSSSSS` or no fraction).

### `machine_features_10s` – 10 s feature table

- `TUMBLE` 10 s on `event_ts` matches the native cadence. Don't widen it, since that changes the meaning of the anomaly window.
- `AVG` is used for most signals; `engine_speed_peak` keeps `MAX` so short spikes survive.
- Features are scaled to roughly 0–1 (e.g. `engine_speed / 2500.0`, `engine_load / 100.0`, fuel rate m³/s → L/h `* 3600000` then `/ 100`, `trans_tractive_force / 50000.0`). These are reference scales; replace them with validated ranges per equipment model.
- Only rows with `equipment_status = 'Working'` are kept, so the baseline isn't polluted by idle or transport states.

Verify (a window row appears only after the watermark passes the 10 s boundary, so allow ~15 s):

```sql
SELECT * FROM machine_features_10s LIMIT 10;
```

### `machine_ad_test1` – multivariate anomaly detection

```sql
ML_DETECT_ANOMALIES_ROBUST(
  ROW(engine_speed_scaled, engine_load_scaled, torque_scaled, fuel_rate_scaled,
      vehicle_speed_scaled, engine_oil_temp_scaled, hydr_oil_temp_scaled, tractive_force_scaled),
  window_time,
  JSON_OBJECT('window' VALUE 30, 'threshold' VALUE 3.0, 'imputeOutliers' VALUE TRUE)
) OVER (PARTITION BY equipment_id ORDER BY window_time
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS anomaly
```

- One baseline per `equipment_id` (`PARTITION BY`).
- `window = 30` counts **rows**, not time: 30 × 10 s = **5-minute** rolling baseline.
- `threshold = 3.0` is the robust z-score cut-off (lower = more sensitive).
- `imputeOutliers = TRUE` replaces detected outliers in the baseline so one spike doesn't skew later scoring.

### `machine_rpm_anomaly` – RPM anomaly detection

```sql
WITH clean AS (
  SELECT equipment_id, CAST(window_time AS TIMESTAMP(6)) AS window_time, equipment_status,
         CAST(engine_speed AS DOUBLE) AS rpm, …
  FROM machine_features_10s
  WHERE equipment_status = 'Working' AND equipment_id IS NOT NULL
    AND window_time IS NOT NULL AND engine_speed IS NOT NULL
)
SELECT …, ML_DETECT_ANOMALIES(rpm, window_time,
  JSON_OBJECT('minTrainingSize' VALUE 30, 'confidencePercentage' VALUE 99.0, 'enableStl' VALUE FALSE))
  OVER (PARTITION BY equipment_id ORDER BY window_time
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS rpm_anomaly
FROM clean;
```

- Univariate detection on engine speed per machine, using the function's default model settings (no explicit ARIMA `p`/`q`/`d`).
- The `clean` CTE drops null rows and casts the time column to `TIMESTAMP(6)` and the value to `DOUBLE`, as the function expects.
- `minTrainingSize = 30`: no results are scored until 30 rows (~5 min) have been seen.
- `confidencePercentage = 99.0`: width of the forecast band. A reading outside it is flagged, so a higher value flags fewer points.
- `enableStl = FALSE`: no seasonal-trend decomposition.

## Step 3 – Read the results

Look at the output column:

```sql
SELECT equipment_id, window_time, engine_speed, anomaly
FROM machine_ad_test1;
```

`anomaly` is a ROW with fields such as `timestamp`, `actual_value`, `forecast_value`, `lower_bound`, `upper_bound`, `rmse`, and `is_anomaly`. Field names may vary by function; run `DESCRIBE machine_ad_test1` to confirm. Show only the flagged rows:

```sql
SELECT equipment_id, window_time, engine_speed, engine_speed_peak, engine_load,
       anomaly.is_anomaly
FROM machine_ad_test1
WHERE anomaly.is_anomaly = TRUE;

SELECT equipment_id, window_time, rpm, rpm_anomaly
FROM machine_rpm_anomaly
WHERE rpm_anomaly.is_anomaly = TRUE;
```

If `is_anomaly` does not resolve as written, use `DESCRIBE` on the table and adjust the field name.

### Baseline timing

| Detector | Warm-up before scoring is meaningful | Rolling baseline |
|----------|--------------------------------------|------------------|
| `machine_ad_test1` (`window = 30`) | at least ~30 rows ≈ 5 min | 30 × 10 s = 5 min |
| `machine_rpm_anomaly` (`minTrainingSize = 30`) | 30 rows ≈ 5 min | grows (unbounded range) |

With ShadowTraffic at one message per 10 s per machine, this means several minutes of data before the first reliable result. Only 'Working' rows count, so the clock runs only while the machine is in that state.

## Step 4 – Verify the detector actually fires

To see a positive result in a demo, change the generator to inject a spike (for example a few `ENGINE_SPEED` values far outside the normal range for one `equipmentIdentificationNumber`) in `shadowtraffic/shadowtraffic_machine_telemetry.json`, re-run `./run.sh`, and re-check the `WHERE … is_anomaly = TRUE` queries above.

## Monitoring and management

```bash
confluent flink statement list --compute-pool <lfcp-id>
confluent flink statement describe <statement-name>
confluent flink statement exception list <statement-name>
```

- Statements should show `RUNNING`. `FAILING` or `DEGRADED` usually means a SQL or format problem (see exceptions).
- Compute pool usage is in the Console. Increase `max_cfu` (Terraform) or the pool's max CFUs if statements stay `PENDING`.

## Cleanup (stops cost)

Stop the generator with `Ctrl+C` (or `docker stop`) if it is still running, then:

- **Terraform:** `cd terraform && terraform destroy`.
- **CLI:** delete the statements, then drop the tables (downstream first):

```bash
for n in machine-rpm-anomaly machine-ad-test1 machine-features-10s machine-create-telemetry-flat; do
  confluent flink statement delete "$n" --environment <env-id> --force
done
```

```sql
DROP MATERIALIZED TABLE machine_rpm_anomaly;
DROP MATERIALIZED TABLE machine_ad_test1;
DROP MATERIALIZED TABLE machine_features_10s;
DROP MATERIALIZED TABLE machine_telemetry_flat;
```

## Tuning notes

- **Too many alerts**: raise `threshold` (e.g. 3.5–4) or `window`.
- **Missed spikes**: lower `threshold`, or add more narrow detectors (RPM, operational stress, traction, PTO) rather than one wide detector; see the design doc.
- **Scale factors** in `machine_features_10s` are placeholders; replace with validated ranges per equipment model.
- Keep one operating state per detector (`equipment_status = 'Working'`); don't mix idle, transport and working data in one baseline.
