# Metabase dashboard for syslog alerts

`build_dashboard.py` creates the "Syslog IDS" dashboard (KPI tiles, verdict/category/host charts, stacked
lines-per-window chart, latest-attacks table) on the `syslog_alerts` table.

This folder has its own Metabase with a small driver plugin (`driver/`, built by the `Dockerfile`) that wraps the
**public Confluent JDBC driver** ([docs](https://docs.confluent.io/cloud/current/flink/operate-and-deploy/connect-with-jdbc.html),
`io.confluent.jdbc:confluent-jdbc:1.0.0` from `packages.confluent.io`, downloaded during the image build): container
`metabase-syslog` on **http://localhost:3000** (the insurance-fraud Metabase also uses 3000, so run only one at a time, or change the host port in `docker-compose.yml` and set `MB_URL`), own data volume, compose project
`syslog-metabase`. The plugin has two drivers on the same jar; pick one with `MB_DRIVER` when running `setup.py`:

- `lightning` (default): RTCE/Lightning (`jdbc:confluent:lightning:`), Global API key, needs RTCE on the topic; fast, no CFUs.
- `flink`: Flink SQL bounded snapshot queries (`jdbc:confluent:flink://`), same Global API key; each query runs on the compute pool.

## Prerequisites (terraform/)

`terraform apply` creates what Metabase needs:

- the Flink tables `syslog_windows` / `syslog_alerts`, via `flink_tables.tf`
- `lightning`: RTCE on `syslog_alerts` (`rtce.tf`; Lightning only exposes RTCE topics) and a **Global** API key for
  service account `syslog-metabase` (outputs `metabase_lightning`, `metabase_api_key`, `metabase_api_secret`).
- `flink`: the same service account and Global key, plus the FlinkDeveloper role and DeveloperRead on the Schema Registry
  subject `syslog_alerts-value` (output `metabase_flink`: cloud, region, organization/environment/compute-pool ids,
  catalog = environment name, database = cluster name).

## Start

```bash
./start.sh     # build, start, create admin + data source, wait for schema sync, build the dashboard
```

Or step by step: `docker compose up -d --build`, `python3 setup.py` (admin user + data source, resyncs the schema),
`python3 build_dashboard.py` (idempotent: recreates the dashboard, so its URL changes on every run).

Login: `admin@example.com` / `Metabase-demo-1` (local demo only; override with `MB_ADMIN_EMAIL` / `MB_ADMIN_PASSWORD`).
`MB_URL` overrides the base URL. If Terraform has no key, `setup.py` falls back to `CC_GLOBAL_API` / `CC_GLOBAL_API_SECRET`
from the environment.

## Viewing without a login

Public sharing is enabled (`MB_ENABLE_PUBLIC_SHARING` in `docker-compose.yml`), and `build_dashboard.py` prints a
second URL, `http://localhost:3000/public/dashboard/<uuid>`, that needs no login. Anyone who can reach the port can
open it, so keep it on localhost or a trusted network.

## Auto refresh

Dashboards do **not** refresh themselves by default; Metabase only re-queries when the page is opened or reloaded.

- In the UI: clock icon at the top right, pick an interval (1 to 60 minutes).
- By URL, per link: append `#refresh=60` (seconds), e.g.
  `http://localhost:3000/public/dashboard/<uuid>#refresh=60`. This is not stored in the dashboard.

The query cache is off by default, so every refresh hits the table. The alerts only change while the Flink
`syslog-scoring` statement is running (`../deploy_flink.sh`).

## Limits

Lightning: only RTCE-enabled topics show up as tables (rerun `setup.py` to resync after enabling one); quote identifiers (upper case).
Flink:

- Every query is a bounded snapshot query (no streaming), run on the Flink compute pool, so each dashboard card
  takes a few seconds and uses CFUs.
- No timestamp bucketing, so the time chart uses the raw `window_start`.
- The model's `category` labels are noisy (small model, free text).
- Flink column names are lower case (the old Lightning setup exposed them upper case); `build_dashboard.py` handles both.

## Test data

To fill `syslog_alerts` without the GPU, copy rows from the old archive topic with a bounded Flink statement
(`INSERT INTO syslog_alerts SELECT ... FROM syslog_alerts_archive /*+ OPTIONS('scan.startup.mode'='earliest-offset',
'scan.bounded.mode'='latest-offset') */`, timestamps cast to `TIMESTAMP(3)`). These rows stay in the topic.
