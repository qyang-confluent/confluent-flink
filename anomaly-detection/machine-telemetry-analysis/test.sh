#!/bin/bash

TELEMETRY_TOPIC="agco.fuse.data.telemetryDataFrame.avro.v001" \
COMPUTE_POOL=lfcp-228o5pq ENV_ID=env-7d27kp DATABASE=sandbox CLOUD=aws REGION=us-east-1 ./deploy.sh

#TELEMETRY_TOPIC=agco.fuse.data.telemetryDataFrame.avro.v001 \
#COMPUTE_POOL=lfcp-xxxx ENV_ID=env-xxxx DATABASE=<kafka-cluster-name> \
#CLOUD=aws REGION=us-east-1 ./deploy.sh

confluent flink statement list --compute-pool lfcp-228o5pq -o json | jq ' .[]|.name'
