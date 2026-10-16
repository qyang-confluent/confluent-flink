# Access Confluent Cloud for Apache Flink Through an AWS CCN

## Overview

Confluent Cloud for Apache Flink can be accessed privately through an existing Confluent Cloud Network (CCN) associated with a Confluent Cloud Dedicated Kafka cluster.

This approach allows customers to reuse existing AWS private connectivity—such as VPC peering, AWS PrivateLink, or Transit Gateway—to reach the Flink private endpoint without creating a separate PrivateLink Gateway for Flink.

The CCN option is available for AWS and Azure and requires an existing CCN with at least one Dedicated Kafka cluster in the environment and region where Flink is used.

See [Private Networking with Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/concepts/flink-private-networking.html) for the supported networking model.

## Architecture

```text
Customer AWS VPC
       |
       | Existing VPC peering, PrivateLink, or Transit Gateway
       |
Confluent Cloud Network
       |
Private Flink endpoint
       |
Flink Compute Pool
       |
Internal Confluent Cloud routing
       |
Dedicated Kafka cluster
```

The customer network reaches Flink through the CCN endpoint. Flink then accesses the private Dedicated Kafka cluster through Confluent Cloud's internal routing.

## Prerequisites

* A Confluent Cloud environment with Apache Flink enabled.
* A Confluent Cloud Dedicated Kafka cluster.
* An existing AWS Confluent Cloud Network associated with the Dedicated cluster.
* Flink and the Dedicated Kafka cluster in the same AWS region.
* Existing private connectivity from the customer VPC to the CCN.
* DNS resolution configured for the existing Kafka private endpoints.
* Required Flink and Kafka RBAC/ACL permissions.

## Step 1: Verify the Confluent Cloud Network

In the Confluent Cloud Console:

1. Open the target environment.
2. Select Network management.
3. Open the For Dedicated clusters section.
4. Confirm that a CCN exists for the required AWS region.
5. Confirm that the CCN is associated with the Dedicated Kafka cluster.
6. Record the network ID and AWS region.

If no CCN exists, create one by following [Create a Confluent Cloud Network on AWS](https://docs.confluent.io/cloud/current/networking/ccloud-network/aws.html).

## Step 2: Verify AWS private connectivity

Confirm that the customer VPC can already reach the CCN through the existing private networking configuration.

Depending on the deployment, verify:

* The AWS VPC peering connection is active.
* The required Confluent Cloud CIDR ranges are present in the customer VPC route tables.
* Security groups and network ACLs permit the required traffic.
* DNS resolution is enabled in the VPC.
* Route 53 forwarding or private DNS records used for Kafka are working.
* Transit Gateway attachments and routes are available, if Transit Gateway is used.

The [AWS VPC Peering documentation](https://docs.confluent.io/cloud/current/networking/peering/aws-peering.html) describes the AWS peering workflow, route tables, CIDR requirements, and DNS considerations.

## Step 3: Configure the Flink endpoint

In the Confluent Cloud Console:

1. Open the environment containing Flink.
2. Open the Flink Endpoints page.
3. Select the private CCN endpoint for the required AWS region.
4. Set it as the default endpoint for the user or environment, as appropriate.

The endpoint format depends on the CCN network ID and DNS configuration. Use the endpoint displayed by Confluent Cloud rather than constructing the hostname manually.

## Step 4: Configure the Confluent CLI

Select the Flink region and list the available endpoints:

```bash
confluent flink region use --cloud aws --region <aws-region>
confluent flink endpoint list
confluent flink endpoint use https://flink-xxxxx.us-east-1.aws.glb.confluent.cloud
```

Select the CCN/private endpoint shown for the environment before using the Flink SQL shell or submitting statements.

The [Enable Private Networking with Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/operate-and-deploy/private-networking.html) guide describes the endpoint selection workflow.

## DNS considerations

If the customer VPC already resolves the Kafka private endpoints through public DNS or the existing CCN configuration, no additional DNS changes may be required.

For private DNS configurations, ensure that the Flink endpoint is included in the same routing or forwarding rules used for the CCN. If a reverse proxy or host-file entry is used, add the Flink endpoint to that configuration.

Do not hardcode individual Kafka broker hostnames. Broker names returned through Kafka metadata are not static.

## Validation checklist

Run the following checks from a client located in the customer VPC or connected through the customer private network:

* Confirm the Flink endpoint resolves successfully.
* Confirm the resolved address follows the expected private-network path.
* Confirm TCP connectivity to HTTPS port 443.
* Confirm the Flink endpoint is the CCN/private endpoint, not the public endpoint.
* Confirm the Flink environment and Dedicated Kafka cluster are in the same AWS region.
* Confirm the Flink service account has permission to access the Kafka cluster and topics.
* Submit a test Flink statement that reads from a permitted Kafka topic.

## Common issues

### The CCN endpoint is not listed

Verify that:

* A Dedicated Kafka cluster exists in the environment and region.
* The CCN is configured for that region.
* The user has permission to view or use the private endpoint.

### Flink uses the public endpoint

The Confluent CLI and Cloud Console may default to the public endpoint. Explicitly select the private CCN endpoint using the Flink endpoint configuration.

### DNS resolves, but the connection fails

Check VPC route tables, security groups, network ACLs, DNS forwarding, and Transit Gateway routes. Also verify that the client is using the correct region-specific hostname.

### The Kafka cluster is Enterprise or self-managed

The CCN option described here is intended for an existing CCN associated with a Dedicated Kafka cluster. For other cluster types or external Kafka services, use the appropriate private connectivity option, such as a PrivateLink Gateway or a supported egress connectivity pattern.

## Reference documentation

* [Private Networking with Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/concepts/flink-private-networking.html)
* [Enable Private Networking with Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/operate-and-deploy/private-networking.html)
* [Create a Confluent Cloud Network on AWS](https://docs.confluent.io/cloud/current/networking/ccloud-network/aws.html)
* [Use AWS VPC Peering with Confluent Cloud](https://docs.confluent.io/cloud/current/networking/peering/aws-peering.html)
