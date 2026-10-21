# Private Access to Confluent Cloud for Apache Flink Using GCP Private Service Connect

## Overview

This guide describes how to provide private access from a Google Cloud VPC to Confluent Cloud for Apache Flink using Google Cloud Private Service Connect (PSC).

The resulting traffic path is:

```text
Client workload in Google Cloud VPC
        |
        | Internal IP address
        v
Google Cloud PSC endpoint
        |
        | Service attachment
        v
Confluent Cloud PrivateLink Gateway
        |
        v
Confluent Cloud for Apache Flink
```

This approach keeps Flink SQL and API traffic on a private network path rather than sending it over the public internet.

## Scope and assumptions

This guide assumes:

* Flink is provisioned in Confluent Cloud.
* The client application, VM, GKE workload, or proxy runs in a Google Cloud VPC.
* The Google Cloud VPC and the Confluent Cloud gateway use the same region.
* You have permission to administer networking in Confluent Cloud and Google Cloud.

This guide covers private access to the Flink service. Kafka cluster connectivity may require additional private networking configuration.

## Prerequisites

Before starting, collect the following values:

| Value | Example | Where to obtain it |
|---|---|---|
| Google Cloud project ID | `customer-prod-123` | Google Cloud project settings |
| Google Cloud VPC | `customer-vpc` | Google Cloud VPC network |
| Google Cloud subnet | `customer-private-subnet` | Google Cloud VPC network |
| Google Cloud region | `us-central1` | Must match the Confluent gateway region |
| Reserved PSC IP | `10.20.10.10` | An unused IP in the PSC subnet |
| Confluent environment ID | `env-abc123` | Confluent Cloud environment settings |

The Confluent user should have an OrganizationAdmin, EnvironmentAdmin, or NetworkAdmin role. The Google Cloud administrator must be able to create a regional internal IP address and PSC forwarding rule.

## Step 1: Create the Confluent PrivateLink Gateway

In the Confluent Cloud Console:

1. Open the target environment.
2. Select **Network management**.
3. Open **For serverless products**.
4. Select **Add gateway configuration**.
5. Choose **PrivateLink**.
6. Create an ingress gateway with:
   * Cloud provider: **Google Cloud**
   * Region: the Google Cloud region where the client VPC is located
7. Save the gateway.
8. Copy the generated **Service Attachment URI**.

The service attachment URI is required when creating the Google Cloud PSC endpoint.

For CLI-based provisioning:

```bash
confluent network gateway create flink-gcp-gateway \
  --cloud gcp \
  --region us-central1 \
  --type ingress-private-service-connect
```

Reference: [Use Google Cloud Private Service Connect for serverless products on Confluent Cloud](https://docs.confluent.io/cloud/current/networking/gcp-platt.html)

## Step 2: Reserve an internal IP address in Google Cloud

Reserve an internal IP address in the client subnet. The IP must be available and must be in the same region as the Confluent gateway.

```bash
export PROJECT_ID="customer-prod-123"
export REGION="us-central1"
export VPC="customer-vpc"
export SUBNET="customer-private-subnet"

gcloud config set project "$PROJECT_ID"

gcloud compute addresses create flink-psc-ip \
  --region "$REGION" \
  --subnet "$SUBNET" \
  --addresses 10.20.10.10
```

If you prefer Google Cloud to select an available address, omit the `--addresses` option.

## Step 3: Create the Google Cloud PSC endpoint

Create a regional PSC forwarding rule that targets the Service Attachment URI from Step 1.

```bash
export SERVICE_ATTACHMENT_URI="SERVICE_ATTACHMENT_URI_FROM_CONFLUENT"

gcloud compute forwarding-rules create flink-psc-endpoint \
  --region "$REGION" \
  --network "$VPC" \
  --subnet "$SUBNET" \
  --address flink-psc-ip \
  --target-service-attachment "$SERVICE_ATTACHMENT_URI"
```

Verify the endpoint:

```bash
gcloud compute forwarding-rules describe flink-psc-endpoint \
  --region "$REGION"
```

Confirm that the endpoint has an internal IP address and that its PSC connection is accepted or approved.

Reference: [Access published services through Private Service Connect endpoints](https://docs.cloud.google.com/vpc/docs/configure-private-service-connect-services)

## Step 4: Register the PSC endpoint in Confluent Cloud

The PSC endpoint must be registered as an access point on the Confluent gateway.

1. In Google Cloud, open the PSC endpoint details.
2. Copy the Google Cloud PSC connection ID.
3. In Confluent Cloud, open the gateway created in Step 1.
4. Open the **Access points** tab.
5. Select **Create access point**.
6. Enter an access point name such as `flink-gcp-access`.
7. Enter the PSC connection ID.
8. Create the access point.
9. Wait until the gateway and access point show **READY**.

CLI equivalent:

```bash
export GATEWAY_ID="gw-XXXXXXXX"
export PSC_CONNECTION_ID="PSC_CONNECTION_ID_FROM_GOOGLE_CLOUD"

confluent network access-point private-link ingress-endpoint create \
  flink-gcp-access \
  --cloud gcp \
  --gateway "$GATEWAY_ID" \
  --psc-connection-id "$PSC_CONNECTION_ID"
```

A separate Confluent access point is required for each PSC endpoint. Do not reuse a connection ID from a deleted PSC endpoint.

Reference: [Create a GCP ingress Private Service Connect access point](https://docs.confluent.io/confluent-cli/current/command-reference/network/access-point/private-link/ingress-endpoint/confluent_network_access-point_private-link_ingress-endpoint_create.html)

## Step 5: Configure private DNS

Private DNS ensures that Flink hostnames resolve to the PSC endpoint instead of a public address.

1. In Confluent Cloud, open the gateway’s network details.
2. Copy the displayed DNS domain and Flink endpoint hostname.
3. In Google Cloud, create a Cloud DNS private managed zone for the Confluent DNS domain.
4. Associate the zone with the client VPC.
5. Create the A record or records provided by Confluent, pointing to the PSC endpoint IP address.
6. Confirm that the client workload uses the VPC’s DNS resolver.

Use the exact DNS values displayed in Confluent Cloud. Do not construct the hostname manually or hardcode broker names.

Example validation:

```bash
FLINK_HOST="flink.<region>.<cloud>.private.confluent.cloud"

dig +short "$FLINK_HOST"
nc -vz "$FLINK_HOST" 443
```

The DNS response should resolve to the internal PSC endpoint IP address, such as `10.20.10.10`.

Reference: [Enable private networking with Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/operate-and-deploy/private-networking.html)

## Step 6: Validate Flink access

Run these tests from a VM, GKE pod, or other workload inside the VPC.

### DNS resolution

```bash
dig "$FLINK_HOST"
```

Confirm that the answer is private and resolves to the PSC endpoint address.

### TCP connectivity

```bash
nc -vz "$FLINK_HOST" 443
```

A successful connection confirms network reachability to the Flink endpoint.

### Application-level validation

Use the Confluent Cloud Console, Flink SQL shell, or your application from the private network. Confirm that:

* Flink statements can be submitted.
* Statement status and results can be retrieved.
* SQL autocomplete and error highlighting work if using the Flink SQL shell or Console through a proxy.

## Troubleshooting

### PSC endpoint remains pending

Check the following:

* The endpoint uses the correct Service Attachment URI.
* The endpoint and Confluent gateway are in the same region.
* The Google Cloud project and VPC are authorized for the Confluent gateway.
* The PSC connection ID registered in Confluent matches the current endpoint.

### DNS resolves publicly

Check the following:

* The Cloud DNS zone is private.
* The zone is associated with the correct VPC.
* The client workload uses the VPC DNS resolver.
* The private record points to the PSC endpoint IP.
* There is no more-specific public or private zone overriding the intended record.

### TCP connection fails

Check the following:

* The client is running in the VPC or has private routing into it.
* Egress firewall rules allow TCP/443.
* The PSC endpoint is in the expected region and subnet.
* The PSC endpoint and access point both show a ready or approved state.
* Proxy or NAT configuration is not replacing the private DNS response.

### Access works from a VM but not from GKE

Check the following:

* The GKE nodes or pods have routes to the PSC endpoint subnet.
* Network policies allow egress to TCP/443.
* The pod’s DNS configuration uses the VPC resolver.
* Any service mesh or egress proxy preserves the Flink hostname and TLS SNI.

## Operational considerations

* Treat the PSC endpoint IP as an internal service address and protect it with normal VPC firewall and routing controls.
* Monitor the Confluent gateway and access point status.
* Document the Service Attachment URI, PSC endpoint name, endpoint IP, gateway ID, and access point ID.
* If the PSC endpoint is deleted and recreated, register the new PSC connection ID in Confluent Cloud.
* Keep the private DNS zone and PSC endpoint in the same deployment ownership boundary to simplify operations.

## References

* [Confluent Cloud: Google Cloud Private Service Connect for serverless products](https://docs.confluent.io/cloud/current/networking/gcp-platt.html)
* [Confluent Cloud: Private networking for Apache Flink](https://docs.confluent.io/cloud/current/flink/operate-and-deploy/private-networking.html)
* [Google Cloud: Access published services through PSC endpoints](https://docs.cloud.google.com/vpc/docs/configure-private-service-connect-services)
* [Confluent CLI: Create a GCP ingress PSC access point](https://docs.confluent.io/confluent-cli/current/command-reference/network/access-point/private-link/ingress-endpoint/confluent_network_access-point_private-link_ingress-endpoint_create.html)
