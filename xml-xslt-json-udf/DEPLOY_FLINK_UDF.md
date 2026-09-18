# Deploying the Flink UDF to Confluent Cloud

Instructions for deploying `com.example.flink.XmlToProductsFunction` as a Confluent Cloud Flink SQL UDF.

Prerequisites: `confluent` CLI logged in (`confluent login`), and an existing Flink compute pool/environment. `<env>`, `<cloud>`, `<region>`, `<catalog>` (= the environment), and `<database>` (= the Kafka cluster) below are placeholders for the actual Confluent Cloud identifiers.

The commands below reflect the `confluent flink artifact` / `CREATE FUNCTION ... USING JAR` workflow for custom Flink UDFs; exact CLI flags shift between CLI versions, so confirm with `confluent flink artifact create --help` before running, and feel free to run the `CREATE FUNCTION` step from the Confluent Cloud Console's Flink SQL workspace UI instead of the CLI shell if that's easier.

## 1. Build the UDF jar

```bash
mvn clean package
```

This produces `target/xml-xslt-json-1.0.0-udf.jar`. Confirm its Flink version (`flink.version` in `pom.xml`) matches the Flink version your compute pool runs — check with `confluent flink region list` / the Confluent Cloud console before uploading; a mismatch can cause runtime `NoSuchMethodError`/`ClassNotFoundException` on the UDF.

## 2. Upload the jar as a Flink artifact

```bash
confluent flink artifact create xml-to-products-udf \
  --artifact-file target/xml-xslt-json-1.0.0-udf.jar \
  --cloud <cloud> --region <region> --environment <env>
```

Note the returned artifact ID (or list it later with `confluent flink artifact list --cloud <cloud> --region <region> --environment <env>`).

## 3. Register the function in Flink SQL

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

## 4. Use it against the XML topic

Because it's a table function (one input row can fan out to N output rows), call it via `CROSS JOIN LATERAL TABLE(...)`, not as a plain column expression:

```sql
SELECT p.name, p.price, p.category
FROM `xml-input-topic`
CROSS JOIN LATERAL TABLE(xml_to_products(<xml_column>)) AS p(name, price, category);
```

Replace `<xml_column>` with whatever column in the Flink table (mapped from `xml-input-topic`) holds the raw `<products>...</products>` XML string. To materialize results into a new Kafka topic, wrap the query in `INSERT INTO <sink_table> SELECT ...` against a Flink table backed by that output topic.

## 5. Iterating on the UDF

Confluent Cloud Flink does not hot-reload artifacts — after changing `XmlToProductsFunction.java` (or `transform.xsl`), you must: rebuild (`mvn clean package`), upload a *new* artifact version (`confluent flink artifact create ...` again — artifact versions are immutable), and `DROP FUNCTION xml_to_products;` + re-run the `CREATE FUNCTION` pointing at the new artifact ID (or `CREATE OR REPLACE FUNCTION` if your CLI/SQL version supports it).
