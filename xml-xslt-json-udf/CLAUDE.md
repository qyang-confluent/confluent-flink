# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Kafka streaming sample that consumes raw XML from a Confluent Cloud topic, transforms it via XSLT, and produces the result as Avro to another topic. Everything runs from one class: `src/main/java/com/example/KafkaXmlToAvroTransformer.java`. The same XSLT-then-Jackson conversion is also exposed as a Confluent Cloud Flink SQL table function, `src/main/java/com/example/flink/XmlToProductsFunction.java` (see the Flink UDF section below).

## Commands

```bash
mvn clean compile exec:java   # build (incl. Avro codegen) and run the consumer/producer loop
mvn compile                   # build only
mvn clean package             # also produces target/xml-xslt-json-<version>-udf.jar for the Flink UDF
```

Run needs a Confluent Cloud client config file (see below). There is no test suite and no linter configured in this project.

## Configuration

Confluent Cloud credentials (bootstrap servers, SASL key/secret, Schema Registry URL + basic-auth) are never hardcoded — they're loaded at runtime from an external Java `Properties` file, resolved in this order: first CLI arg → `KAFKA_CLIENT_CONFIG` env var → `client.properties` in the working directory (see `loadClientConfig`). `client.properties.example` documents the required keys; the real file is gitignored. When adding new client behavior (e.g. SSL overrides, consumer tuning), add keys to the example file too.

## Pipeline / architecture

`KafkaXmlToAvroTransformer.main` sets up a long-running poll loop (`KafkaConsumer<String, String>` → `KafkaProducer<String, ProductRecord>`), shut down cleanly via a shutdown hook that calls `consumer.wakeup()`:

1. **Consume**: reads XML string messages from `xml-input-topic`. Each message value is expected to be a full `<products>` document (same shape as `src/main/resources/input.xml`), not a single `<product>`.
2. **Transform**: the XSLT (`src/main/resources/transform.xsl`) is compiled once into a `Templates` object at startup (`XsltTransform.compile`) — `Transformer` instances are then created per-message from it (`XsltTransform.apply`), since `Transformer` isn't thread-safe but `Templates` is safe to reuse. `XsltTransform` (`src/main/java/com/example/XsltTransform.java`) is shared with the Flink UDF below, so its `TransformerFactory` XXE hardening (`FEATURE_SECURE_PROCESSING`, external DTD/stylesheet access disabled) only needs to be preserved in one place. The XSLT buckets each product into a `category` by price: `>= 1000` → Premium, `>= 100` → Standard, otherwise Budget.
3. **Parse**: the transformed XML is deserialized into `Products`/`Product` POJOs via Jackson's `XmlMapper`.
4. **Produce**: each `Product` becomes its own Avro `ProductRecord` message (keyed by product name) sent to `product-output-topic`, serialized with Confluent's `KafkaAvroSerializer` against Schema Registry — i.e. one input XML document fans out into N Avro messages.
5. Offsets are committed manually (`enable.auto.commit=false`) after the producer flush for each poll batch succeeds, giving at-least-once delivery.

The `Product`/`Products` POJOs (Jackson/XML side) and `ProductRecord` (Avro side, generated from `src/main/avro/product.avsc` by the `avro-maven-plugin` into `target/generated-sources/avro`) are two separate models that must be kept in sync by hand in `processRecord` — there's no shared DTO. Adding a field means updating the XSLT, the `Product` POJO, `product.avsc`, and the `ProductRecord.newBuilder()` mapping together.

A malformed/unparseable input record is logged and skipped (`processRecord` failures don't kill the poll loop) rather than treated as fatal, since it comes from an external system boundary.

## Flink UDF (`XmlToProductsFunction`)

`com.example.flink.XmlToProductsFunction` is a Flink `TableFunction<Row>` that runs the same XSLT-then-Jackson conversion as `processRecord` above, packaged as a Confluent Cloud Flink SQL UDF instead of a standalone consumer/producer loop. Because one input XML document fans out into N products, it must be called as a table function (`CROSS JOIN LATERAL TABLE(...)`), not a scalar function — it emits one `ROW<name STRING, price DOUBLE, category STRING>` per `<product>`. It reuses `XsltTransform` and the `KafkaXmlToAvroTransformer.Product`/`Products` POJOs rather than duplicating them.

`pom.xml` has two `maven-shade-plugin` executions bound to `package`, and their **order matters**: `shade-flink-udf` (filtered to only Jackson's XML dataformat + transitive deps, since `flink-table-common` is `provided`) must run *before* `shade-kafka-app` (unfiltered, everything). The shade plugin replaces the project's primary artifact with each shaded jar it produces, so a later execution shades from whatever the previous one left behind; running the narrow filter first means it still sees the original unshaded classes, and the broad kafka-app shade afterward reabsorbs everything regardless. Swapping this order silently makes `target/xml-xslt-json-<version>-udf.jar` balloon into a duplicate of the full Kafka fat jar (verified while building this) — don't reorder them without re-checking jar contents (`unzip -l ... | grep kafka`).

`mvn clean package` produces:
- `target/xml-xslt-json-<version>.jar` — the existing Kafka consumer/producer fat jar (unchanged behavior).
- `target/xml-xslt-json-<version>-udf.jar` — the lean jar to upload as a Confluent Cloud Flink artifact for `XmlToProductsFunction`.

### Deploying to Confluent Cloud Flink

Prerequisites: `confluent` CLI logged in (`confluent login`), and an existing Flink compute pool/environment. `<env>`, `<cloud>`, `<region>`, `<catalog>` (= the environment), and `<database>` (= the Kafka cluster) below are placeholders for the actual Confluent Cloud identifiers.

The commands below reflect the `confluent flink artifact` / `CREATE FUNCTION ... USING JAR` workflow for custom Flink UDFs; exact CLI flags shift between CLI versions, so confirm with `confluent flink artifact create --help` before running, and feel free to run the `CREATE FUNCTION` step from the Confluent Cloud Console's Flink SQL workspace UI instead of the CLI shell if that's easier.

1. **Build the UDF jar**
   ```bash
   mvn clean package
   ```
   This produces `target/xml-xslt-json-1.0.0-udf.jar`. Confirm its Flink version (`flink.version` in `pom.xml`) matches the Flink version your compute pool runs — check with `confluent flink region list` / the Confluent Cloud console before uploading; a mismatch can cause runtime `NoSuchMethodError`/`ClassNotFoundException` on the UDF.

2. **Upload the jar as a Flink artifact**
   ```bash
   confluent flink artifact create xml-to-products-udf \
     --artifact-file target/xml-xslt-json-1.0.0-udf.jar \
     --cloud <cloud> --region <region> --environment <env>
   ```
   Note the returned artifact ID (or list it later with `confluent flink artifact list --cloud <cloud> --region <region> --environment <env>`).

3. **Register the function in Flink SQL**

   Open a Flink SQL shell against the right catalog/database:
   ```bash
   confluent flink shell --compute-pool <compute-pool-id> --environment <env> --catalog <catalog> --database <database>
   ```
   Then create the function, pointing at the uploaded artifact:
   ```sql
   CREATE FUNCTION xml_to_products
     AS 'com.example.flink.XmlToProductsFunction'
     USING JAR 'confluent-artifact://<artifact-id>';
   ```
   Confirm it registered:
   ```sql
   SHOW USER FUNCTIONS;
   ```

4. **Use it against the XML topic**

   Because it's a table function (one input row can fan out to N output rows), call it via `CROSS JOIN LATERAL TABLE(...)`, not as a plain column expression:
   ```sql
   SELECT p.name, p.price, p.category
   FROM `xml-input-topic`
   CROSS JOIN LATERAL TABLE(xml_to_products(<xml_column>)) AS p(name, price, category);
   ```
   Replace `<xml_column>` with whatever column in the Flink table (mapped from `xml-input-topic`) holds the raw `<products>...</products>` XML string. To materialize results into a new Kafka topic, wrap the query in `INSERT INTO <sink_table> SELECT ...` against a Flink table backed by that output topic.

5. **Iterating on the UDF**

   Confluent Cloud Flink does not hot-reload artifacts — after changing `XmlToProductsFunction.java` (or `transform.xsl`), you must: rebuild (`mvn clean package`), upload a *new* artifact version (`confluent flink artifact create ...` again — artifact versions are immutable), and `DROP FUNCTION xml_to_products;` + re-run the `CREATE FUNCTION` pointing at the new artifact ID (or `CREATE OR REPLACE FUNCTION` if your CLI/SQL version supports it).
