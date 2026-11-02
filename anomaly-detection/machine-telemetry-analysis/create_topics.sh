# 1. Pick the account and environment
#confluent login

confluent environment use env-7d27kp


confluent kafka cluster use lkc-xxxx
confluent kafka topic create machine_telemetry


confluent schema-registry schema create \
  --subject machine_telemetry-value \
  --schema machine-schema.avsc \
  --type avro

confluent schema-registry schema describe --subject machine_telemetry-value --version latest

