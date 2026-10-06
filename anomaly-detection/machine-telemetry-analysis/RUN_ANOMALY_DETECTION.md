# Running the Machine Anomaly Detection Pipeline on Confluent Cloud Flink

This guide explains how to run the statements in `cc-flink.sql` to detect anomalies in machine telemetry. Design background is in `machine_telemetry_anomaly_preprocessing.md`.

## Pipeline overview

```
machine.telemetry (Avro topic, raw nested CAN data)
        │  Statement 1: CREATE TABLE machine_telemetry_flat AS …
        │               (UNNEST canData + pivot, continuous)
        ▼
machine_telemetry_flat (one wide row per message)
        │  Statement 3: CREATE TABLE machine_features_10s AS … TUMBLE 10s + scaling   (continuous)
        ▼
machine_features_10s (one row per equipment per 10s, state = 'Working')
        ├─ Statement 4: machine_ad_test1      – multivariate ML_DETECT_ANOMALIES_ROBUST
        └─ Statement 5: machine_rpm_anomaly   – univariate ML_DETECT_ANOMALIES on engine speed
```

Each statement is a **separate, long-running Flink statement**. Run them one at a time, in order, and wait for the previous one to reach `RUNNING` before starting the next.

## Prerequisites

- A Confluent Cloud environment, Kafka cluster, Schema Registry (Stream Governance enabled) and a Flink compute pool in the same region.
- Confluent CLI v4+ (`brew install confluentinc/tap/cli`) logged in, or use the Flink SQL workspace in the Cloud Console.
- Docker, for the ShadowTraffic data generator (a license in `shadowtraffic/license.env`).
- `shadowtraffic/confluent-cloud.env` filled in with `CCLOUD_BOOTSTRAP_SERVERS`, `CCLOUD_SASL_JAAS_CONFIG`, `CCLOUD_SR_URL`, `CCLOUD_SR_USER_INFO`.
- The Flink SQL catalog/database must be your environment/cluster: `USE CATALOG <env-name>; USE <cluster-name>;`.

## Step 1 – Generate telemetry

The raw topic is `machine.telemetry`. If you have no live data, produce synthetic data:

```bash
cd shadowtraffic
./run.sh
```

The config emits up to 1000 events with a 10 s throttle (`maxEvents: 1000`, `throttleMs: 10000`), matching the 10 s native cadence. That is ~2.8 hours of data, produced in real time.

Anomaly detection needs a baseline before it flags anything, so let it run for a while (see "Baseline timing" below). Confirm data is arriving:

```bash
confluent kafka topic consume machine.telemetry --from-beginning \
  --value-format avro --schema-registry-endpoint <SR_URL> | head
```

or open the topic in the Cloud Console → Message viewer.

## Step 2 – Open a Flink shell

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

## Step 3 – Check remaining issues in `cc-flink.sql`

Already fixed in the file: a stray `;` inside the `telemetry_long` CTE, a wrong table name (`machine_telemetry_flat` → `machine_telemetry_flat`), and the update-changes sink error (item 4). The items below are unverified and depend on your data and cluster:

| # | Location | Problem | Fix |
|---|----------|---------|-----|
| 3 | line 45 | The format string `'yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''` only parses timestamps with exactly 3 fractional digits and a literal `Z`. Verify against real `header.timeOfCreation` values | Check a sample; adjust the pattern if the payload differs (e.g. `SSSSSS` or no fraction) |
| 4 | statement 1 | A plain `GROUP BY` emits updates, and an append-only sink rejects them ("doesn't support consuming update changes"). **Already fixed**: `machine_telemetry_flat` is now `append` with no primary key, and statement 1 pivots inside a 1 s `TUMBLE` on the Kafka record time (`$rowtime`). All signals of a message share one `$rowtime`, so each message falls in one window and the output is append-only | If you created the table from the earlier upsert DDL, `DROP TABLE machine_telemetry_flat` and re-create it. Note the flat rows now appear ~1 s plus the watermark delay after the message arrives |

Also run each statement separately: the shell and workspace execute one statement at a time, so split the file at each `;`-terminated statement.

## Step 4 – Run the statements in order

### Option A – Deploy the whole file with the CLI

The Confluent CLI submits one statement per call, so `deploy.sh` splits `cc-flink.sql` on `;` and submits each statement in order with `--wait`:

```bash
confluent login
COMPUTE_POOL=<lfcp-id> ENV_ID=<env-id> DATABASE=<kafka-cluster-name> ./deploy.sh
# add CLOUD=aws REGION=us-east-1 if you haven't run `confluent flink region use`
```

Every statement in `cc-flink.sql` is preceded by a `-- name: <statement-name>` line (lowercase letters, digits, hyphens). The script uses it as the Flink statement name:

| Statement name | What it does |
|---|---|
| `machine-drop-rpm-anomaly-m1`, `machine-drop-rpm-anomaly`, `machine-drop-ad-test1`, `machine-drop-features-10s`, `machine-drop-telemetry-flat` | drop the tables, downstream first |
| `machine-create-telemetry-flat` | create the flat table and fill it with UNNEST + pivot (CTAS, continuous) |
| `machine-features-10s` | 10 s features (continuous) |
| `machine-ad-test1` | multivariate anomaly detection (continuous) |
| `machine-rpm-anomaly` | RPM anomaly detection (continuous) |
| `machine-rpm-anomaly-m1` | RPM anomaly detection with both `AI_DETECT_ANOMALIES` (timesfm-2.5) and `ML_DETECT_ANOMALIES` (continuous) |

**Redeploys:** before creating anything, the script deletes any existing statement with these names, which stops running ones, and then creates them again. You don't need to remove old statements by hand. A statement without a `-- name:` line makes the script stop before it deploys anything. Names that don't exist yet show as `not found (ok)`.

To remove the deployed statements without redeploying:

```bash
for n in machine-rpm-anomaly machine-ad-test1 machine-features-10s machine-create-telemetry-flat; do
  confluent flink statement delete "$n" --environment <env-id> --force
done
```

The script stops at the first failed statement; check it with `confluent flink statement exception list <name>`. It assumes no `;` appears inside a string literal in the SQL file.

### Option B – Run statements one by one (shell or workspace)

Use the sections below.

### Statement 0 – Drop existing tables (top of file)

`cc-flink.sql` starts with four `DROP TABLE IF EXISTS` statements (downstream first), so the whole file can be redeployed from scratch. Dropping a table does not stop a statement that is still writing to it: first delete the old streaming statements (`deploy.sh` does this for you; by hand use `confluent flink statement delete <name>`). Dropping the tables also deletes their topics and schemas.

### Statement 1 – Create the flat table and fill it (UNNEST + pivot)

```sql
CREATE TABLE `machine_telemetry_flat` ( … ) DISTRIBUTED BY … WITH ( … ) AS (
  WITH telemetry_long AS ( … )
  SELECT … FROM TABLE(TUMBLE(…)) GROUP BY window_start, window_end, message_id, equipment_id, event_ts
);
```

Creates the target topic and Avro schemas in Schema Registry, and starts the continuous statement that populates it (a single CTAS replaces the earlier separate `CREATE TABLE` + `INSERT INTO`). Verify:

```sql
SHOW CREATE TABLE machine_telemetry_flat;
```

- Explodes `canData` into one row per signal, then pivots into columns with `MAX(CASE WHEN can_name = … THEN value END)`. `MAX` is only a pivot idiom; each signal occurs once per message.
- The statement is continuous. Verify output:

```sql
SELECT * FROM machine_telemetry_flat LIMIT 10;
```

Check that signal columns are populated (not all `NULL`). All-NULL columns usually mean the `can_name` string does not match the payload (names are case-sensitive; check `machine-data.json`).

### Statement 3 – 10 s feature table

```sql
CREATE TABLE machine_features_10s AS ( WITH telemetry_10s AS (…) SELECT … );
```

- `TUMBLE` 10 s matches the native cadence. Don't widen it, since that changes the meaning of the anomaly window.
- `AVG` is used for most signals; `engine_speed_peak` keeps `MAX` so short spikes survive.
- Values are scaled to roughly 0–1 (e.g. `engine_speed / 2500.0`; fuel rate m³/s → L/h `* 3600000` then `/ 100`). These are reference scales; replace them with validated ranges per equipment model.
- Only rows with `equipment_status = 'Working'` are kept, so the baseline isn't polluted by idle or transport states.

Verify (a window row appears only after the watermark passes the 10 s boundary, so allow ~15 s):

```sql
SELECT * FROM machine_features_10s LIMIT 10;
```

### Statement 4 – Multivariate anomaly detection

```sql
CREATE TABLE machine_ad_test1 AS
SELECT …, ML_DETECT_ANOMALIES_ROBUST(ROW(…8 scaled features…), window_time,
  JSON_OBJECT('window' VALUE 30, 'threshold' VALUE 3.0, 'imputeOutliers' VALUE TRUE))
  OVER (PARTITION BY equipment_id ORDER BY window_time
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS anomaly
FROM machine_features_10s;
```

- One baseline per `equipment_id` (`PARTITION BY`).
- `window = 30` counts **rows**, not time: 30 × 10 s = **5-minute** rolling baseline.
- `threshold = 3.0` is the robust z-score cut-off (lower = more sensitive).
- `imputeOutliers = TRUE` replaces detected outliers in the baseline so one spike doesn't skew later scoring.

### Statement 5 – RPM anomaly detection (`machine-rpm-anomaly`)

```sql
CREATE TABLE machine_rpm_anomaly AS
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

## Step 5 – Read the results

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

With ShadowTraffic at one message per 10 s, this means several minutes of data before the first reliable result. Only 'Working' rows count, so the clock runs only while the machine is in that state.

## Step 6 – Verify the detector actually fires

To see a positive result in a demo, change the generator to inject a spike (for example a few `ENGINE_SPEED` values far outside the normal range for one `equipmentIdentificationNumber`) in `shadowtraffic_machine_telemetry.json`, re-run `./run.sh`, and re-check the `WHERE anomaly.is_anomaly = TRUE` queries above.

## Monitoring and management

```bash
confluent flink statement list --compute-pool <lfcp-id>
confluent flink statement describe <statement-name>
confluent flink statement exception list <statement-name>
```

- Statements should show `RUNNING`. `FAILING` or `DEGRADED` usually means a SQL or format problem (see exceptions).
- Compute pool usage is in the Console. Increase max CFUs if statements stay `PENDING`.

## Cleanup (stops cost)

Stop the streaming statements and drop the tables when finished:

```bash
confluent flink statement delete <statement-name>
```

```sql
DROP TABLE machine_rpm_anomaly;
DROP TABLE machine_ad_test1;
DROP TABLE machine_features_10s;
DROP TABLE machine_telemetry_flat;
```

Stop the generator with `Ctrl+C` (or `docker stop`) if it is still running.

## Tuning notes

- **Too many alerts**: raise `threshold` (e.g. 3.5–4) or `window`.
- **Missed spikes**: lower `threshold`, or add more narrow detectors (RPM, operational stress, traction, PTO) rather than one wide detector; see the design doc.
- **Scale factors** in statement 3 are placeholders; replace with validated ranges per equipment model.
- Keep one operating state per detector (`equipment_status = 'Working'`); don't mix idle, transport and working data in one baseline.
