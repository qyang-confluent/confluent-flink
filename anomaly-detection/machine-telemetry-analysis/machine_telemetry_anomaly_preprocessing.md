# Machine Telemetry Anomaly Detection Preprocessing

## Recommendation

Apply a `TUMBLE` window before `ML_DETECT_ANOMALIES_ROBUST` only when the raw stream has duplicate timestamps, irregular spacing, event bursts, or independently arriving signals.

Use the raw data directly when each machine produces one complete row every 10 seconds with regular timestamps.

## When to use `TUMBLE`

Use a regular tumbling window when:

* A machine has multiple records with the same timestamp.
* Signals arrive independently or in bursts.
* Events have timestamp gaps or jitter.
* Telemetry must be aligned into consistent intervals.

For a 10-second telemetry cadence, use a 10-second `TUMBLE` interval to preserve resolution. A 30-second interval can reduce noise, but it changes the meaning of the anomaly window.

## Aggregation guidance

| Feature | Suggested aggregation |
|---|---|
| Engine Speed | `AVG` plus `MAX` to preserve spikes |
| Engine Load | `AVG` |
| Fuel Rate | `AVG` |
| Wheel Slip | `MAX` or a high percentile |
| Engine Oil Temp | `AVG` |
| Battery Voltage | `AVG`, plus min/max for voltage drops |
| Vehicle Speed | `AVG` or latest value |
| GPS Speed | `AVG` or latest value |
| PTO Speed | `AVG` plus `MAX` |
| PTO State | Latest value or majority value |
| EquipmentStatus | Latest value |

Do not average away important short-lived events such as RPM spikes or wheel-slip peaks.

## Define event time before windowing

In streaming mode, `TUMBLE` requires a time attribute, not merely a column whose data type is `TIMESTAMP` or `TIMESTAMP_LTZ`. Define `event_ts` and its watermark on the source table before creating the flattening view.

For the ISO-8601 timestamp in the machine payload, add a computed event-time column and allow five seconds for out-of-order records:

```sql
ALTER TABLE telemetry_raw
ADD `event_ts` AS TO_TIMESTAMP_LTZ(
  header.timeOfCreation,
  'yyyy-MM-dd''T''HH:mm:ss.SSSX',
  'UTC'
);

ALTER TABLE telemetry_raw
MODIFY WATERMARK FOR `event_ts`
  AS `event_ts` - INTERVAL '5' SECOND;
```

If you are creating `telemetry_raw` from scratch, put the computed column and watermark directly in its `CREATE TABLE` DDL. Run `DESCRIBE telemetry_raw`; `event_ts` should be shown as `ROWTIME`.

The watermark definition is required because casting a string to `TIMESTAMP_LTZ(3)` alone creates an ordinary timestamp, not a rowtime attribute. See the [Confluent Cloud event-time and watermark documentation](https://docs.confluent.io/cloud/current/flink/concepts/timely-stream-processing.html).

## Flattening the nested `canData` array

The sample payload contains one message with an array of CAN records. Flatten it in two stages:

1. Use `UNNEST` to create one row per CAN signal.
2. Pivot selected `canName` values into one wide row per equipment event.

The source table below assumes `telemetry_raw` already has a nested schema. Model `canID` as `STRING` because the sample contains both numeric IDs and malformed telephone-like values.

### Long-form signal table

```sql
CREATE VIEW telemetry_long AS
SELECT
  r.header.id AS message_id,
  r.body.equipmentIdentificationNumber AS equipment_id,
  r.event_ts AS event_ts,
  r.body.equipmentStatus AS equipment_status,
  c.can_id,
  c.can_name,
  c.unit,
  c.value_raw,
  c.`value`
FROM telemetry_raw AS r
CROSS JOIN UNNEST(r.body.canData)
  AS c(can_id, can_name, unit, value_raw, value);
```

### Wide telemetry table

Create `machine_telemetry_flat` as a persistent materialized table. The grouped columns are declared `NOT NULL` and used as an explicit primary key because Flink materialized tables infer a key from grouped columns. `equipment_status` remains nullable and is aggregated rather than included in the key.

```sql
CREATE MATERIALIZED TABLE machine_telemetry_flat (
  message_id STRING NOT NULL,
  equipment_id STRING NOT NULL,
  event_ts TIMESTAMP_LTZ(3) NOT NULL,
  equipment_status STRING,
  engine_speed DOUBLE,
  engine_load DOUBLE,
  engine_percent_torque DOUBLE,
  fuel_rate DOUBLE,
  vehicle_speed DOUBLE,
  engine_oil_temp DOUBLE,
  hydr_oil_temp DOUBLE,
  trans_act_ratio DOUBLE,
  trans_set_ratio DOUBLE,
  trans_tractive_force DOUBLE,
  rear_draft DOUBLE,
  hitch_position_rear DOUBLE,
  WATERMARK FOR event_ts AS event_ts - INTERVAL '5' SECOND,
  PRIMARY KEY (message_id, equipment_id, event_ts) NOT ENFORCED
)
WITH (
  'value.format' = 'avro-registry'
)
AS
SELECT
  message_id,
  equipment_id,
  event_ts,
  MAX(equipment_status) AS equipment_status,

  MAX(CASE WHEN can_name = 'ENGINE_SPEED'
           THEN `value` END) AS engine_speed,
  MAX(CASE WHEN can_name = 'ENGINE_LOAD'
           THEN `value` END) AS engine_load,
  MAX(CASE WHEN can_name = 'ENGINE_PERCENT_TORQUE'
           THEN `value` END) AS engine_percent_torque,
  MAX(CASE WHEN can_name = 'FUEL_RATE'
           THEN `value` END) AS fuel_rate,
  MAX(CASE WHEN can_name = 'VEHICLE_SPEED'
           THEN `value` END) AS vehicle_speed,
  MAX(CASE WHEN can_name = 'ENGINE_OIL_TEMP'
           THEN `value` END) AS engine_oil_temp,
  MAX(CASE WHEN can_name = 'HYDR_OIL_TEMP'
           THEN `value` END) AS hydr_oil_temp,
  MAX(CASE WHEN can_name = 'TRANS_ACT_RATIO'
           THEN `value` END) AS trans_act_ratio,
  MAX(CASE WHEN can_name = 'TRANS_SET_RATIO'
           THEN `value` END) AS trans_set_ratio,
  MAX(CASE WHEN can_name = 'TRANS_TRACTIVE_FORCE'
           THEN `value` END) AS trans_tractive_force,
  MAX(CASE WHEN can_name = 'REAR_DRAFT'
           THEN `value` END) AS rear_draft,
  MAX(CASE WHEN can_name = 'HITCH_POSITION_REAR'
           THEN `value` END) AS hitch_position_rear
FROM telemetry_long
WHERE message_id IS NOT NULL
  AND equipment_id IS NOT NULL
  AND event_ts IS NOT NULL
GROUP BY
  message_id,
  equipment_id,
  event_ts;
```

`MAX` is used only as a pivot operation. Each signal should occur once per message. This materialized table creates a persistent Kafka-backed result that can be queried by downstream Flink statements.

### Ten-second aggregation

Apply `TUMBLE` to `machine_telemetry_flat`, whose `event_ts` is declared as a rowtime attribute with a watermark in the materialized table definition.

```sql
CREATE VIEW telemetry_10s AS
SELECT
  window_start,
  window_end,
  window_time,
  equipment_id,
  equipment_status,

  AVG(engine_speed) AS engine_speed,
  MAX(engine_speed) AS engine_speed_peak,
  AVG(engine_load) AS engine_load,
  AVG(engine_percent_torque) AS engine_percent_torque,
  AVG(fuel_rate) AS fuel_rate,
  AVG(vehicle_speed) AS vehicle_speed,
  AVG(engine_oil_temp) AS engine_oil_temp,
  AVG(hydr_oil_temp) AS hydr_oil_temp,
  AVG(trans_act_ratio) AS trans_act_ratio,
  AVG(trans_tractive_force) AS trans_tractive_force
FROM TABLE(
  TUMBLE(
    TABLE machine_telemetry_flat,
    DESCRIPTOR(event_ts),
    INTERVAL '10' SECOND
  )
)
GROUP BY
  window_start,
  window_end,
  window_time,
  equipment_id,
  equipment_status;
```

`window_time` remains the time attribute produced by the window TVF and can be used by downstream event-time processing.

## Example Flink SQL

The query below uses the `telemetry_10s` view above. Because the materialized table owns the `event_ts` watermark and TUMBLE is applied there, this query only scales the features and applies anomaly detection.

The numeric fields are scaled to comparable engineering ranges before multivariate detection. Replace the scale factors with validated ranges for the specific equipment model.

```sql
WITH scaled_features AS (
  SELECT
    equipment_id,
    window_time,
    equipment_status,
    engine_speed,
    engine_speed_peak,
    engine_load,
    fuel_rate,
    vehicle_speed,
    engine_oil_temp,
    hydr_oil_temp,

    CAST(engine_speed / 2500.0 AS DOUBLE) AS engine_speed_scaled,
    CAST(engine_load / 100.0 AS DOUBLE) AS engine_load_scaled,
    CAST(engine_percent_torque / 100.0 AS DOUBLE) AS torque_scaled,
    -- Convert m3/s to L/hour, then scale by a 100 L/hour reference.
    CAST((fuel_rate * 3600000.0) / 100.0 AS DOUBLE) AS fuel_rate_scaled,
    CAST(vehicle_speed / 15.0 AS DOUBLE) AS vehicle_speed_scaled,
    CAST(engine_oil_temp / 150.0 AS DOUBLE) AS engine_oil_temp_scaled,
    CAST(hydr_oil_temp / 150.0 AS DOUBLE) AS hydr_oil_temp_scaled,
    CAST(trans_tractive_force / 50000.0 AS DOUBLE) AS tractive_force_scaled
  FROM telemetry_10s
  WHERE equipment_status = 'Working'
)
SELECT
  equipment_id,
  window_time,
  equipment_status,
  engine_speed,
  engine_speed_peak,
  engine_load,
  fuel_rate,
  vehicle_speed,
  engine_oil_temp,
  hydr_oil_temp,
  ML_DETECT_ANOMALIES_ROBUST(
    ROW(
      engine_speed_scaled,
      engine_load_scaled,
      torque_scaled,
      fuel_rate_scaled,
      vehicle_speed_scaled,
      engine_oil_temp_scaled,
      hydr_oil_temp_scaled,
      tractive_force_scaled
    ),
    window_time,
    JSON_OBJECT(
      'window' VALUE 60,
      'threshold' VALUE 3.0,
      'imputeOutliers' VALUE TRUE
    )
  ) OVER (
    PARTITION BY equipment_id
    ORDER BY window_time
    RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS anomaly
FROM scaled_features;
```

## Window sizing

The `window` parameter counts rows after aggregation:

| Tumble interval | `window` value | Baseline duration |
|---|---:|---:|
| 10 seconds | 30 | 5 minutes |
| 10 seconds | 60 | 10 minutes |
| 30 seconds | 20 | 10 minutes |
| 30 seconds | 60 | 30 minutes |

A good starting point for machine telemetry is `window = 60` with a 10-second tumbling interval, giving a 10-minute rolling baseline. Use shorter windows for sudden RPM spikes and longer windows for slow signals such as oil temperature or battery voltage.

## Recommended detectors

Use separate detectors rather than one detector over every field:

* RPM anomaly: Engine Speed, Engine Load, and Vehicle Speed.
* Operational stress: Engine Load, Fuel Rate, Wheel Slip, and Engine Oil Temp.
* Traction anomaly: Wheel Slip, Vehicle Speed, GPS Speed, and Engine Load.
* PTO anomaly: PTO Speed, PTO State, and Engine Speed.

Partition by `equipment_identification_number` and, where possible, by operating mode or equipment model. Avoid combining engine-off, idle, transport, and working states into one baseline.

## Source

[Confluent Cloud anomaly detection documentation](https://docs.confluent.io/cloud/current/ai/builtin-functions/detect-anomalies.html)
