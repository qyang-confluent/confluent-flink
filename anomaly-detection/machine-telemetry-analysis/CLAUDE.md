# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

This is not a buildable software project — there is no build, lint, or test tooling, and it is not a git repository. It is a small reference set of design/data artifacts for a Confluent Cloud Flink SQL pipeline that detects anomalies in agricultural machine telemetry (CAN bus data) using Confluent's built-in `ML_DETECT_ANOMALIES_ROBUST` function.

The three files work together as one design:

- **`machine-schema.avsc`** — the Avro schema (`machine.fuse.data.telemetryDataFrame.TelemetryDataFrameValue`) for the raw telemetry topic. Each message has a `header` (message id, schema id/version, creation/reception timestamps) and a `body` (`CanDataFrameBody`) containing a `canData` array of individual CAN signal readings (`canID`, `canName`, `unit`, `valueRaw`, `value`), plus equipment identity/status fields and `geospatialData`.
- **`machine-data.json`** — a sample message conforming to that schema, showing a real `canData` array (GPS mode, engine speed/load/torque, fuel rate, pressures, temperatures, hydraulic/transmission signals, aftertreatment/SCR signals, etc.) for one equipment event.
- **`machine_telemetry_anomaly_preprocessing.md`** — the design doc explaining how to turn the raw nested/long-form CAN data into features suitable for anomaly detection in Confluent Cloud Flink SQL.

## Core design: raw CAN stream → anomaly detection

The preprocessing doc lays out a specific pipeline shape; when editing or extending SQL in this space, follow this flow rather than inventing a different one:

1. **`UNNEST` the `canData` array** (`telemetry_raw` → `telemetry_long`) to get one row per CAN signal, keyed by `message_id`/`equipment_id`/`event_ts`.
2. **Pivot** `telemetry_long` into a wide table (`machine_telemetry_flat`) using `MAX(CASE WHEN can_name = '...' THEN value END)` per signal of interest — `MAX` here is a pivot idiom, not real aggregation, since each signal occurs once per message.
3. **`TUMBLE`** the wide table only when needed — i.e. when a machine emits duplicate timestamps, irregular spacing, bursty/independent signal arrivals, or jitter. Skip the window if a machine emits exactly one clean row every 10 seconds. When windowing, match the tumble interval to the native cadence (10s for this telemetry) — widening it changes the meaning of the anomaly window.
4. **Aggregate per signal appropriately**, not uniformly by `AVG`: spike-prone signals (Engine Speed, Wheel Slip, PTO Speed) need `MAX`/high-percentile alongside `AVG` so short-lived events aren't averaged away; state fields (PTO State, EquipmentStatus) take the latest/majority value instead.
5. **Scale features into comparable engineering ranges** before feeding them into `ML_DETECT_ANOMALIES_ROBUST` (e.g. `engine_speed / 2500.0`, fuel rate converted m³/s → L/hour then scaled) — see the "Example Flink SQL" section for the reference scale factors, which should be replaced with validated ranges per equipment model rather than trusted as-is.
6. **Partition anomaly detection by `equipment_identification_number`**, and prefer several narrow detectors over one detector across all fields — the doc defines RPM, operational-stress, traction, and PTO detector groupings by which signals feed each. Avoid mixing engine-off/idle/transport/working states into one baseline; filter to a single operating state (e.g. `equipment_status = 'Working'`) per detector.
7. **`window` sizing** in `ML_DETECT_ANOMALIES_ROBUST` counts post-aggregation rows, not wall-clock time — it must be read together with the tumble interval to know the actual baseline duration (see the sizing table in the doc; `window = 60` with a 10s tumble ≈ 10-minute rolling baseline).

## Working with the Avro schema

- `canID` should be modeled as `STRING` in downstream SQL/tables even though the Avro type is `long` — the doc notes real-world data contains malformed, telephone-like ID values that don't fit cleanly as numeric.
- `value` is nullable (`["null", "double"]`); `valueRaw` is always present. Downstream pivots should generally select `value`, falling back to raw only when the doc/task explicitly calls for it.
- Timestamps in the schema/payload (`timeOfCreation`, `timeOfReception`, geospatial `timeStamp`) are ISO-8601 strings and need explicit casting (e.g. `CAST(... AS TIMESTAMP_LTZ(3))`) when used as Flink event time — use `header.timeOfCreation` (event time), not `timeOfReception`, as the watermark/event timestamp source.

## Related tooling

Flink SQL work targeting Confluent Cloud in this space should follow the `confluent-cloud-flink-sql` skill's CC-vs-OSS dialect rules; anomaly-detection function usage should match the [Confluent Cloud anomaly detection docs](https://docs.confluent.io/cloud/current/ai/builtin-functions/detect-anomalies.html) and [array/UNNEST docs](https://docs.confluent.io/cloud/current/flink/reference/queries/joins.html) referenced in the preprocessing doc.
