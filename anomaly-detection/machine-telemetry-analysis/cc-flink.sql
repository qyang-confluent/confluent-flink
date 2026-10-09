-- Each statement is preceded by a "-- name: <statement-name>" line. deploy.sh uses it as the
-- Flink statement name and deletes any existing statement with that name before redeploying.
-- Names must be lowercase letters, digits and hyphens.

-- Mirrors terraform/main.tf: each table is a materialized table (query in terraform/queries.tf).
-- Cleanup for redeploy (downstream first).
-- name: machine-drop-rpm-anomaly
DROP MATERIALIZED TABLE IF EXISTS `machine_rpm_anomaly`;
-- name: machine-drop-ad-test1
DROP MATERIALIZED TABLE IF EXISTS `machine_ad_test1`;
-- name: machine-drop-features-10s
DROP MATERIALIZED TABLE IF EXISTS `machine_features_10s`;
-- name: machine-drop-telemetry-flat
DROP MATERIALIZED TABLE IF EXISTS `machine_telemetry_flat`;

-- name: machine-create-telemetry-flat
CREATE MATERIALIZED TABLE `machine_telemetry_flat` (
  WATERMARK FOR `event_ts` AS `event_ts` - INTERVAL '5' SECOND
)
DISTRIBUTED BY HASH(`equipment_id`) INTO 6 BUCKETS
AS
with telemetry_long as ( 
  SELECT
  r.`$rowtime` AS row_ts,
  r.header.id AS message_id,
  r.body.equipmentIdentificationNumber AS equipment_id,
  -- COALESCE makes event_ts NOT NULL; rows with an unparsable timestamp are filtered out below
  -- (the epoch fallback is never emitted).
  COALESCE(
    TO_TIMESTAMP_LTZ(
      r.header.timeOfCreation,
      'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''',
      'UTC'
    ),
    TO_TIMESTAMP_LTZ(0, 3)
  ) AS event_ts,
  r.body.equipmentStatus AS equipment_status,
  c.can_id,
  c.can_name,
  c.unit,
  c.value_raw,
  c.`value`
FROM `machine.telemetry` AS r
CROSS JOIN UNNEST(r.body.canData)
  AS c(can_id, can_name, unit, value_raw, `value`)
)
-- Windowed (TUMBLE on the Kafka record time) so the aggregation is append-only:
-- all CAN signals of one message share the same $rowtime, so each message lands in one window.
SELECT
  equipment_id,
  message_id,
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
FROM TABLE(
  TUMBLE(TABLE telemetry_long, DESCRIPTOR(row_ts), INTERVAL '1' SECOND)
)
WHERE message_id IS NOT NULL
  AND equipment_id IS NOT NULL
  AND event_ts > TO_TIMESTAMP_LTZ(0, 3)
GROUP BY
  window_start,
  window_end,
  message_id,
  equipment_id,
  event_ts;

-- dataset to ML
-- name: machine-features-10s
CREATE MATERIALIZED TABLE machine_features_10s (
  WATERMARK FOR `window_time` AS `window_time`
)
DISTRIBUTED BY HASH(`equipment_id`) INTO 6 BUCKETS
AS
WITH telemetry_10s AS 
( SELECT
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
  equipment_status )
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
  WHERE equipment_status = 'Working';

-- multi variable anomaly detection
-- name: machine-ad-test1
CREATE MATERIALIZED TABLE `machine_ad_test1` (
  WATERMARK FOR `window_time` AS `window_time`
)
DISTRIBUTED BY HASH(`equipment_id`) INTO 6 BUCKETS
WITH ('changelog.mode' = 'append')
AS
select
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
      'window' VALUE 30,
      'threshold' VALUE 3.0,
      'imputeOutliers' VALUE TRUE
    )
  ) OVER (
    PARTITION BY equipment_id
    ORDER BY window_time
    RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS anomaly
FROM machine_features_10s;

-- rpm anomaly detection
-- name: machine-rpm-anomaly
CREATE MATERIALIZED TABLE machine_rpm_anomaly (
  WATERMARK FOR `window_time_3` AS `window_time_3`
)
DISTRIBUTED BY HASH(`equipment_id`) INTO 6 BUCKETS
WITH ('changelog.mode' = 'append')
AS
WITH clean AS (
  SELECT
    equipment_id,
    CAST(window_time AS TIMESTAMP(6)) AS window_time,
    window_time AS window_time_3,
    equipment_status,
    CAST(engine_speed AS DOUBLE) AS rpm,
    engine_speed_peak,
    engine_load,
    fuel_rate,
    vehicle_speed,
    engine_oil_temp,
    hydr_oil_temp
  FROM machine_features_10s
  WHERE equipment_status = 'Working'
    AND equipment_id IS NOT NULL
    AND window_time IS NOT NULL
    AND engine_speed IS NOT NULL
)
SELECT
  equipment_id,
  window_time,
  window_time_3,
  equipment_status,
  rpm,
  engine_speed_peak,
  engine_load,
  fuel_rate,
  vehicle_speed,
  engine_oil_temp,
  hydr_oil_temp,

  ML_DETECT_ANOMALIES(
    rpm,
    window_time,
    JSON_OBJECT(
      'minTrainingSize' VALUE 30,
      'confidencePercentage' VALUE 99.0,
      'enableStl' VALUE FALSE
    )
  ) OVER (
    PARTITION BY equipment_id
    ORDER BY window_time_3
    RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS rpm_anomaly
FROM clean;

