# 1. Pick the account and environment
#confluent login

confluent environment use env-7d27kp


confluent kafka cluster use lkc-xxxx
confluent kafka topic create agco.fuse.data.telemetryDataFrame.avro.v001


confluent schema-registry schema create \
  --subject agco.fuse.data.telemetryDataFrame.avro.v001-value \
  --schema machine-schema.avsc \
  --type avro

confluent schema-registry schema describe --subject agco.fuse.data.telemetryDataFrame.avro.v001-value --version latest

