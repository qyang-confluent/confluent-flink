# XML → XSLT → Avro Kafka Sample

This project runs a continuous Kafka consumer/producer:

1. Consumes raw XML messages (same shape as `src/main/resources/input.xml`) from the Confluent Cloud topic `xml-input-topic`.
2. Applies `src/main/resources/transform.xsl` to each message.
3. Maps the transformed XML to Java objects, one per `<product>`.
4. Produces each product as an Avro record (schema in `src/main/avro/product.avsc`) to the topic `product-output-topic`, using Confluent Schema Registry.

The XSLT assigns categories based on price:

- `price >= 1000`: Premium product
- `price >= 100`: Standard product
- otherwise: Budget product

## Requirements

- Java 17+
- Maven 3.8+
- A Confluent Cloud cluster with the `xml-input-topic` and `product-output-topic` topics created, and Schema Registry enabled

## Configure credentials

Copy `client.properties.example` to `client.properties` and fill in your cluster/API key and Schema Registry values (Confluent Cloud UI: Cluster -> Clients -> Java gives you a ready-made snippet). `client.properties` is gitignored — never commit it.

## Run

```bash
mvn clean compile exec:java
```

By default the app looks for `client.properties` in the working directory. Override with a CLI arg or the `KAFKA_CLIENT_CONFIG` env var:

```bash
mvn exec:java -Dexec.args=/path/to/client.properties
# or
KAFKA_CLIENT_CONFIG=/path/to/client.properties mvn exec:java
```

The consumer runs until interrupted (Ctrl+C).

## Sending test data

Send the contents of `src/main/resources/input.xml` as a single message value to `xml-input-topic`, e.g. with [kcat](https://github.com/edenhill/kcat):

```bash
kcat -F client.properties -P -t xml-input-topic <<< "$(tr -d '\n' < src/main/resources/input.xml)"
```
