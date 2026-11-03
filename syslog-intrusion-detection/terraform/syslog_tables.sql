-- Created by Terraform (flink_tables.tf) so the topics exist before RTCE is enabled. The INSERT INTO statements
-- in flink_syslog.sql.tpl (deploy_flink.sh) fill them. Keep exactly two statements, windows first.

CREATE TABLE IF NOT EXISTS `syslog_windows` (
  host         STRING,
  window_start TIMESTAMP(3),
  window_end   TIMESTAMP(3),
  line_count   BIGINT,
  text         STRING
);

CREATE TABLE IF NOT EXISTS `syslog_alerts` (
  host         STRING,
  window_start TIMESTAMP(3),
  window_end   TIMESTAMP(3),
  line_count   BIGINT,
  verdict      STRING,
  category     STRING,
  confidence   DOUBLE,
  reason       STRING,
  sample       STRING
);
