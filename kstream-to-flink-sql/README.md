# Kafka Streams to Flink SQL Migration Guide

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [Kafka Streams Code Summary](#kafka-streams-code-summary)
3. [Core Pattern Mapping](#core-pattern-mapping)
4. [Detailed Migration Examples](#detailed-migration-examples)
5. [Key Differences & Considerations](#key-differences--considerations)
6. [Migration Checklist](#migration-checklist)

---

## Executive Summary

This guide provides a comprehensive mapping from Kafka Streams Java DSL to Flink SQL for migrating stream processing applications. The examples in this codebase demonstrate various streaming patterns including stateless transformations, windowed aggregations, stream-table joins, session windows, and materialized views.

**Key Migration Effort Areas:**
- **Low Effort**: Basic transformations, filtering, simple aggregations
- **Medium Effort**: Time-based windowing, stream-table joins
- **High Effort**: Session windows, interactive queries, custom state stores

---

## Kafka Streams Code Summary

### 1. WordCountLambdaExample
**Purpose**: Classic word count with continuous aggregation
**Key Operations**:
- Stream reading from Kafka topic
- FlatMap (split text into words)
- GroupBy + Count aggregation
- Output to result topic

**Business Logic**: Counts word occurrences from a text stream

---

### 2. PageViewRegionLambdaExample
**Purpose**: Join page views with user profiles and aggregate by region
**Key Operations**:
- KStream (page views) ← LeftJoin → KTable (user profiles)
- Time-based hopping windows (5 min size, 1 min advance)
- Count by region within windows
- Avro serialization with Schema Registry

**Business Logic**: Compute page views per region using windowed counts

---

### 3. TopArticlesLambdaExample
**Purpose**: Calculate TopN articles per industry
**Key Operations**:
- Filter (articles only)
- Time-based tumbling windows (1 hour)
- Custom aggregation with PriorityQueue
- GroupBy industry
- TopN extraction (top 100)

**Business Logic**: Track trending articles by industry using session-based ranking

---

### 4. SessionWindowsExample
**Purpose**: Session-based event counting
**Key Operations**:
- Session windows (30 min inactivity gap)
- Count events per session
- Session merging on gap closure

**Business Logic**: Count play events per user session with automatic session detection

---

### 5. AnomalyDetectionLambdaExample
**Purpose**: Detect anomalous user behavior
**Key Operations**:
- Tumbling windows (1 minute)
- Count by user
- Filter (threshold >= 3)

**Business Logic**: Identify users with excessive activity within time windows

---

### 6. GlobalKTablesExample
**Purpose**: Enrich orders with customer and product data
**Key Operations**:
- GlobalKTable (customers, products)
- Non-partitioned joins (no repartitioning)
- Stream enrichment

**Business Logic**: Join order stream with reference data for order enrichment

---

### 7. SumLambdaExample
**Purpose**: Aggregate numeric values
**Key Operations**:
- Filter (odd numbers)
- SelectKey (re-keying)
- Reduce (sum)

**Business Logic**: Sum all odd numbers from a number stream

---

### 8. OrdersService (Microservices)
**Purpose**: CQRS pattern with materialized views
**Key Operations**:
- Materialized KTable as queryable state store
- Interactive queries
- REST API integration
- Read-your-own-writes consistency

**Business Logic**: Order management with query optimization via materialized views

---

### 9. FraudService (Microservices)
**Purpose**: Fraud detection via transaction aggregation
**Key Operations**:
- Session windows (1 hour inactivity)
- Aggregate order values by customer
- Branch on threshold (>= $2000)
- Emit validation results

**Business Logic**: Detect fraudulent transactions by monitoring customer spending patterns

---

## Core Pattern Mapping

### 1. Stream Creation

**Kafka Streams:**
```java
KStream<String, String> stream = builder.stream("input-topic");
```

**Flink SQL:**
```sql
CREATE TABLE input_stream (
    key STRING,
    value STRING,
    event_time TIMESTAMP(3) METADATA FROM 'timestamp',
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'input-topic',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);
```

---

### 2. Stateless Transformations

#### Filter
**Kafka Streams:**
```java
stream.filter((key, value) -> value % 2 != 0)
```

**Flink SQL:**
```sql
SELECT * FROM input_stream WHERE value % 2 != 0;
```

#### Map
**Kafka Streams:**
```java
stream.map((key, value) -> new KeyValue<>(key, value.toLowerCase()))
```

**Flink SQL:**
```sql
SELECT key, LOWER(value) as value FROM input_stream;
```

#### FlatMap
**Kafka Streams:**
```java
stream.flatMapValues(value -> Arrays.asList(value.split("\\s+")))
```

**Flink SQL:**
```sql
SELECT key, word
FROM input_stream
CROSS JOIN UNNEST(SPLIT(value, ' ')) AS t(word);
```

---

### 3. Aggregations

#### Simple Count
**Kafka Streams:**
```java
stream
    .groupBy((key, word) -> word)
    .count()
```

**Flink SQL:**
```sql
SELECT word, COUNT(*) as count
FROM word_stream
GROUP BY word;
```

#### Reduce
**Kafka Streams:**
```java
stream
    .groupByKey()
    .reduce((v1, v2) -> v1 + v2)
```

**Flink SQL:**
```sql
SELECT key, SUM(value) as sum
FROM input_stream
GROUP BY key;
```

---

### 4. Windowing

#### Tumbling Windows
**Kafka Streams:**
```java
stream
    .groupByKey()
    .windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofMinutes(1)))
    .count()
```

**Flink SQL:**
```sql
SELECT
    key,
    COUNT(*) as count,
    TUMBLE_START(event_time, INTERVAL '1' MINUTE) as window_start,
    TUMBLE_END(event_time, INTERVAL '1' MINUTE) as window_end
FROM input_stream
GROUP BY key, TUMBLE(event_time, INTERVAL '1' MINUTE);
```

#### Hopping Windows
**Kafka Streams:**
```java
stream
    .groupByKey()
    .windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofMinutes(5))
        .advanceBy(Duration.ofMinutes(1)))
    .count()
```

**Flink SQL:**
```sql
SELECT
    key,
    COUNT(*) as count,
    HOP_START(event_time, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE) as window_start,
    HOP_END(event_time, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE) as window_end
FROM input_stream
GROUP BY key, HOP(event_time, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE);
```

#### Session Windows
**Kafka Streams:**
```java
stream
    .groupByKey()
    .windowedBy(SessionWindows.ofInactivityGapWithNoGrace(Duration.ofMinutes(30)))
    .count()
```

**Flink SQL:**
```sql
SELECT
    key,
    COUNT(*) as count,
    SESSION_START(event_time, INTERVAL '30' MINUTE) as session_start,
    SESSION_END(event_time, INTERVAL '30' MINUTE) as session_end
FROM input_stream
GROUP BY key, SESSION(event_time, INTERVAL '30' MINUTE);
```

---

### 5. Joins

#### Stream-Table Join
**Kafka Streams:**
```java
KStream<String, PageView> views = builder.stream("PageViews");
KTable<String, UserProfile> users = builder.table("UserProfiles");

KStream<String, EnrichedView> enriched = views
    .leftJoin(users,
        (view, user) -> new EnrichedView(view, user));
```

**Flink SQL:**
```sql
CREATE TABLE page_views (
    user_id STRING,
    page STRING,
    event_time TIMESTAMP(3),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (...);

CREATE TABLE user_profiles (
    user_id STRING,
    region STRING,
    PRIMARY KEY (user_id) NOT ENFORCED
) WITH (
    'connector' = 'upsert-kafka',
    ...
);

SELECT
    v.user_id,
    v.page,
    u.region,
    v.event_time
FROM page_views v
LEFT JOIN user_profiles FOR SYSTEM_TIME AS OF v.event_time AS u
ON v.user_id = u.user_id;
```

#### Stream-Stream Join
**Kafka Streams:**
```java
KStream<String, Order> orders = builder.stream("orders");
KStream<String, Payment> payments = builder.stream("payments");

KStream<String, EnrichedOrder> enriched = orders.join(
    payments,
    (order, payment) -> new EnrichedOrder(order, payment),
    JoinWindows.ofTimeDifferenceWithNoGrace(Duration.ofMinutes(5))
);
```

**Flink SQL:**
```sql
SELECT
    o.order_id,
    o.amount,
    p.payment_id,
    o.event_time
FROM orders o
JOIN payments p
ON o.order_id = p.order_id
AND o.event_time BETWEEN p.event_time - INTERVAL '5' MINUTE
                     AND p.event_time + INTERVAL '5' MINUTE;
```

---

## Detailed Migration Examples

### Example 1: Word Count

**Kafka Streams (WordCountLambdaExample.java:185-208):**
```java
final KStream<String, String> textLines = builder.stream(inputTopic);
final Pattern pattern = Pattern.compile("\\W+", Pattern.UNICODE_CHARACTER_CLASS);

final KTable<String, Long> wordCounts = textLines
    .flatMapValues(value -> Arrays.asList(pattern.split(value.toLowerCase())))
    .groupBy((keyIgnored, word) -> word)
    .count();

wordCounts.toStream().to(outputTopic, Produced.with(Serdes.String(), Serdes.Long()));
```

**Flink SQL:**
```sql
-- Create source table
CREATE TABLE text_lines (
    value STRING,
    event_time TIMESTAMP(3) METADATA FROM 'timestamp',
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'streams-plaintext-input',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json',
    'json.fail-on-missing-field' = 'false',
    'json.ignore-parse-errors' = 'true'
);

-- Create sink table
CREATE TABLE word_counts (
    word STRING,
    count BIGINT,
    PRIMARY KEY (word) NOT ENFORCED
) WITH (
    'connector' = 'upsert-kafka',
    'topic' = 'streams-wordcount-output',
    'properties.bootstrap.servers' = 'localhost:9092',
    'key.format' = 'raw',
    'value.format' = 'json'
);

-- Insert query
INSERT INTO word_counts
SELECT
    LOWER(word) as word,
    COUNT(*) as count
FROM text_lines
CROSS JOIN UNNEST(SPLIT(REGEXP_REPLACE(value, '[^a-zA-Z0-9\\s]', ''), ' ')) AS t(word)
WHERE word <> ''
GROUP BY LOWER(word);
```

---

### Example 2: Page Views by Region with Windows

**Kafka Streams (PageViewRegionLambdaExample.java:172-184):**
```java
final KTable<Windowed<String>, Long> viewsByRegion = viewsByUser
    .leftJoin(userRegions, (view, region) -> {
        final GenericRecord viewRegion = new GenericData.Record(schema);
        viewRegion.put("user", view.get("user"));
        viewRegion.put("page", view.get("page"));
        viewRegion.put("region", region);
        return viewRegion;
    })
    .map((user, viewRegion) -> new KeyValue<>(viewRegion.get("region").toString(), viewRegion))
    .groupByKey()
    .windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofMinutes(5))
        .advanceBy(Duration.ofMinutes(1)))
    .count();
```

**Flink SQL:**
```sql
-- Source: page views
CREATE TABLE page_views (
    user_id STRING,
    page STRING,
    event_time TIMESTAMP(3) METADATA FROM 'timestamp',
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'PageViews',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'avro-confluent',
    'avro-confluent.url' = 'http://localhost:8081'
);

-- Source: user profiles
CREATE TABLE user_profiles (
    user_id STRING,
    region STRING,
    PRIMARY KEY (user_id) NOT ENFORCED
) WITH (
    'connector' = 'upsert-kafka',
    'topic' = 'UserProfiles',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'avro-confluent',
    'avro-confluent.url' = 'http://localhost:8081'
);

-- Sink: views by region
CREATE TABLE views_by_region (
    region STRING,
    window_start TIMESTAMP(3),
    window_end TIMESTAMP(3),
    view_count BIGINT,
    PRIMARY KEY (region, window_start) NOT ENFORCED
) WITH (
    'connector' = 'upsert-kafka',
    'topic' = 'PageViewsByRegion',
    'properties.bootstrap.servers' = 'localhost:9092',
    'key.format' = 'json',
    'value.format' = 'json'
);

-- Query
INSERT INTO views_by_region
SELECT
    u.region,
    HOP_START(v.event_time, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE) as window_start,
    HOP_END(v.event_time, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE) as window_end,
    COUNT(*) as view_count
FROM page_views v
LEFT JOIN user_profiles FOR SYSTEM_TIME AS OF v.event_time AS u
ON v.user_id = u.user_id
WHERE u.region IS NOT NULL
GROUP BY u.region, HOP(v.event_time, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE);
```

---

### Example 3: Anomaly Detection

**Kafka Streams (AnomalyDetectionLambdaExample.java:131-140):**
```java
final KTable<Windowed<String>, Long> anomalousUsers = views
    .map((ignoredKey, username) -> new KeyValue<>(username, username))
    .groupByKey()
    .windowedBy(TimeWindows.ofSizeWithNoGrace(Duration.ofMinutes(1)))
    .count()
    .filter((windowedUserId, count) -> count >= 3);
```

**Flink SQL:**
```sql
-- Source table
CREATE TABLE user_clicks (
    username STRING,
    event_time TIMESTAMP(3) METADATA FROM 'timestamp',
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'UserClicks',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Sink table
CREATE TABLE anomalous_users (
    username STRING,
    window_start TIMESTAMP(3),
    window_end TIMESTAMP(3),
    click_count BIGINT,
    PRIMARY KEY (username, window_start) NOT ENFORCED
) WITH (
    'connector' = 'upsert-kafka',
    'topic' = 'AnomalousUsers',
    'properties.bootstrap.servers' = 'localhost:9092',
    'key.format' = 'json',
    'value.format' = 'json'
);

-- Query
INSERT INTO anomalous_users
SELECT
    username,
    TUMBLE_START(event_time, INTERVAL '1' MINUTE) as window_start,
    TUMBLE_END(event_time, INTERVAL '1' MINUTE) as window_end,
    COUNT(*) as click_count
FROM user_clicks
GROUP BY username, TUMBLE(event_time, INTERVAL '1' MINUTE)
HAVING COUNT(*) >= 3;
```

---

### Example 4: Session Windows

**Kafka Streams (SessionWindowsExample.java:163-177):**
```java
builder.stream(PLAY_EVENTS, Consumed.with(Serdes.String(), playEventSerde))
    .groupByKey(Grouped.with(Serdes.String(), playEventSerde))
    .windowedBy(SessionWindows.ofInactivityGapAndGrace(INACTIVITY_GAP, Duration.ofMillis(100)))
    .count(Materialized.<String, Long, SessionStore<Bytes, byte[]>>as(PLAY_EVENTS_PER_SESSION)
        .withKeySerde(Serdes.String())
        .withValueSerde(Serdes.Long()))
    .toStream()
    .map((key, value) -> new KeyValue<>(key.key() + "@" + key.window().start() + "->" + key.window().end(), value))
    .to(PLAY_EVENTS_PER_SESSION, Produced.with(Serdes.String(), Serdes.Long()));
```

**Flink SQL:**
```sql
-- Source table
CREATE TABLE play_events (
    user_id STRING,
    song_id STRING,
    event_time TIMESTAMP(3) METADATA FROM 'timestamp',
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'play-events',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'avro-confluent',
    'avro-confluent.url' = 'http://localhost:8081'
);

-- Sink table
CREATE TABLE play_events_per_session (
    user_id STRING,
    session_start TIMESTAMP(3),
    session_end TIMESTAMP(3),
    play_count BIGINT
) WITH (
    'connector' = 'kafka',
    'topic' = 'play-events-per-session',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Query
INSERT INTO play_events_per_session
SELECT
    user_id,
    SESSION_START(event_time, INTERVAL '30' MINUTE) as session_start,
    SESSION_END(event_time, INTERVAL '30' MINUTE) as session_end,
    COUNT(*) as play_count
FROM play_events
GROUP BY user_id, SESSION(event_time, INTERVAL '30' MINUTE);
```

---

### Example 5: Fraud Detection

**Kafka Streams (FraudService.java:84-120):**
```java
final KTable<Windowed<Long>, OrderValue> aggregate = orders
    .groupBy((id, order) -> order.getCustomerId(), Grouped.with(Serdes.Long(), ORDERS.valueSerde()))
    .windowedBy(SessionWindows.ofInactivityGapWithNoGrace(Duration.ofHours(1)))
    .aggregate(OrderValue::new,
        (custId, order, total) -> new OrderValue(order,
            total.getValue() + order.getQuantity() * order.getPrice()),
        (k, a, b) -> simpleMerge(a, b),
        Materialized.with(null, Schemas.ORDER_VALUE_SERDE));

final Map<String, KStream<String, OrderValue>> forks = ordersWithTotals.split(Named.as("limit-"))
    .branch((id, orderValue) -> orderValue.getValue() >= FRAUD_LIMIT, Branched.as("above"))
    .branch((id, orderValue) -> orderValue.getValue() < FRAUD_LIMIT, Branched.as("below"))
    .noDefaultBranch();
```

**Flink SQL:**
```sql
-- Source table
CREATE TABLE orders (
    order_id STRING,
    customer_id BIGINT,
    quantity INT,
    price DOUBLE,
    state STRING,
    event_time TIMESTAMP(3) METADATA FROM 'timestamp',
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'orders',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'avro-confluent',
    'avro-confluent.url' = 'http://localhost:8081'
);

-- Sink for fraud validation results
CREATE TABLE order_validations (
    order_id STRING,
    validation_type STRING,
    validation_result STRING
) WITH (
    'connector' = 'kafka',
    'topic' = 'order-validations',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'avro-confluent',
    'avro-confluent.url' = 'http://localhost:8081'
);

-- Query with session-based fraud detection
INSERT INTO order_validations
SELECT
    order_id,
    'FRAUD_CHECK' as validation_type,
    CASE
        WHEN total_value >= 2000 THEN 'FAIL'
        ELSE 'PASS'
    END as validation_result
FROM (
    SELECT
        LAST_VALUE(order_id) as order_id,
        customer_id,
        SUM(quantity * price) as total_value,
        SESSION_START(event_time, INTERVAL '1' HOUR) as session_start,
        SESSION_END(event_time, INTERVAL '1' HOUR) as session_end
    FROM orders
    WHERE state = 'CREATED'
    GROUP BY customer_id, SESSION(event_time, INTERVAL '1' HOUR)
);
```

---

### Example 6: TopN Articles

**Kafka Streams (TopArticlesLambdaExample.java:192-250):**
```java
final KTable<Windowed<GenericRecord>, Long> viewCounts = articleViews
    .groupByKey(Grouped.with(keyAvroSerde, valueAvroSerde))
    .windowedBy(TimeWindows.ofSizeWithNoGrace(windowSize))
    .count();

final KTable<Windowed<String>, PriorityQueue<GenericRecord>> allViewCounts = viewCounts
    .groupBy(
        (windowedArticle, count) -> {
            final Windowed<String> windowedIndustry =
                new Windowed<>(windowedArticle.key().get("industry").toString(),
                    windowedArticle.window());
            final GenericRecord viewStats = new GenericData.Record(schema);
            viewStats.put("page", windowedArticle.key().get("page"));
            viewStats.put("count", count);
            return new KeyValue<>(windowedIndustry, viewStats);
        },
        Grouped.with(windowedStringSerde, valueAvroSerde)
    ).aggregate(
        () -> new PriorityQueue<>(comparator),
        (windowedIndustry, record, queue) -> {
            queue.add(record);
            return queue;
        },
        (windowedIndustry, record, queue) -> {
            queue.remove(record);
            return queue;
        },
        Materialized.with(windowedStringSerde, new PriorityQueueSerde<>(comparator, valueAvroSerde))
    );
```

**Flink SQL (using ROW_NUMBER for TopN):**
```sql
-- Source table
CREATE TABLE page_views (
    page STRING,
    industry STRING,
    flags STRING,
    event_time TIMESTAMP(3) METADATA FROM 'timestamp',
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'PageViews',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'avro-confluent',
    'avro-confluent.url' = 'http://localhost:8081'
);

-- Sink table
CREATE TABLE top_news_per_industry (
    industry STRING,
    window_start TIMESTAMP(3),
    window_end TIMESTAMP(3),
    top_articles STRING
) WITH (
    'connector' = 'kafka',
    'topic' = 'TopNewsPerIndustry',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- TopN query using ROW_NUMBER
INSERT INTO top_news_per_industry
SELECT
    industry,
    window_start,
    window_end,
    LISTAGG(page, CHR(10)) as top_articles
FROM (
    SELECT
        industry,
        page,
        window_start,
        window_end,
        ROW_NUMBER() OVER (PARTITION BY industry, window_start ORDER BY view_count DESC) as rank
    FROM (
        SELECT
            industry,
            page,
            COUNT(*) as view_count,
            TUMBLE_START(event_time, INTERVAL '1' HOUR) as window_start,
            TUMBLE_END(event_time, INTERVAL '1' HOUR) as window_end
        FROM page_views
        WHERE flags LIKE '%ARTICLE%'
        GROUP BY industry, page, TUMBLE(event_time, INTERVAL '1' HOUR)
    )
)
WHERE rank <= 100
GROUP BY industry, window_start, window_end;
```

---

## Key Differences & Considerations

### 1. Programming Model

| Aspect | Kafka Streams | Flink SQL |
|--------|--------------|-----------|
| **Language** | Java/Scala API | Declarative SQL |
| **Abstractions** | KStream, KTable, GlobalKTable | Tables (append-only or changelog) |
| **State Management** | Explicit state stores | Automatic state management |
| **Deployment** | Library (runs in your app) | Cluster-based (JobManager + TaskManagers) |

### 2. Time Semantics

**Kafka Streams:**
- Uses Kafka record timestamps
- Configured via `TimestampExtractor`
- Grace periods for late data

**Flink SQL:**
- Uses watermarks (explicit in table DDL)
- `WATERMARK FOR column AS expression`
- More flexible watermark strategies

### 3. State Stores & Materialized Views

**Kafka Streams:**
```java
// Interactive queries
ReadOnlyKeyValueStore<String, Order> store = streams.store(
    StoreQueryParameters.fromNameAndType("orders-store",
        QueryableStoreTypes.keyValueStore())
);
Order order = store.get(orderId);
```

**Flink SQL:**
Flink SQL doesn't provide built-in interactive queries like Kafka Streams. Options:
1. **Use Flink Table Store (Paimon)** for queryable state
2. **Sink to external database** (e.g., RocksDB, Cassandra, Redis)
3. **Use Flink's Queryable State** (lower-level API, not SQL)
4. **Materialize to Kafka topic** and query with external service

**Migration Strategy for Interactive Queries:**
```sql
-- Option 1: Materialize to changelog topic
CREATE TABLE orders_materialized (
    order_id STRING,
    customer_id STRING,
    state STRING,
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'upsert-kafka',
    'topic' = 'orders-materialized',
    'properties.bootstrap.servers' = 'localhost:9092',
    'key.format' = 'json',
    'value.format' = 'json'
);

-- Then query with KsqlDB or external service
```

### 4. Joins

**Temporal Join Syntax:**
```sql
-- Kafka Streams KStream-KTable join equivalent
SELECT o.*, c.name
FROM orders o
LEFT JOIN customers FOR SYSTEM_TIME AS OF o.event_time AS c
ON o.customer_id = c.customer_id;
```

**Stream-Stream Join:**
```sql
-- Time-bounded interval join
SELECT *
FROM orders o
JOIN shipments s
ON o.order_id = s.order_id
AND o.event_time BETWEEN s.event_time - INTERVAL '1' HOUR
                     AND s.event_time + INTERVAL '1' HOUR;
```

### 5. Windowing

| Window Type | Kafka Streams | Flink SQL |
|-------------|--------------|-----------|
| **Tumbling** | `TimeWindows.ofSizeWithNoGrace()` | `TUMBLE(time_col, INTERVAL 'X' UNIT)` |
| **Hopping** | `TimeWindows.advanceBy()` | `HOP(time_col, slide, size)` |
| **Session** | `SessionWindows.ofInactivityGap()` | `SESSION(time_col, INTERVAL 'X' UNIT)` |
| **Custom** | Custom WindowAssigner | User-defined or complex SQL |

### 6. Serialization

**Kafka Streams:**
- Uses Serdes (Serializer/Deserializer)
- Schema Registry integration via `SpecificAvroSerde`, `GenericAvroSerde`

**Flink SQL:**
- Formats specified in connector DDL
- Built-in support: JSON, Avro, CSV, Parquet, Protobuf
- Schema Registry: `'format' = 'avro-confluent'`

### 7. Exactly-Once Semantics

**Kafka Streams:**
```java
props.put(StreamsConfig.PROCESSING_GUARANTEE_CONFIG,
    StreamsConfig.EXACTLY_ONCE_V2);
```

**Flink SQL:**
```sql
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'execution.checkpointing.interval' = '60s';

-- In connector configuration
'sink.delivery-guarantee' = 'exactly-once',
'sink.transactional-id-prefix' = 'flink-txn'
```

### 8. Performance Tuning

| Configuration | Kafka Streams | Flink SQL |
|--------------|--------------|-----------|
| **Parallelism** | Topic partitions | `SET 'parallelism.default' = '4'` |
| **State Backend** | RocksDB (default) | RocksDB, HashMap, custom |
| **Caching** | `STATESTORE_CACHE_MAX_BYTES_CONFIG` | Managed automatically |
| **Commit Interval** | `COMMIT_INTERVAL_MS_CONFIG` | Checkpoint interval |

---

## Migration Checklist

### Phase 1: Assessment
- [ ] Document all Kafka Streams topologies
- [ ] Identify state stores and their usage
- [ ] Map out interactive query requirements
- [ ] Catalog custom serdes and schemas
- [ ] List all windowing operations
- [ ] Document join patterns

### Phase 2: Infrastructure Setup
- [ ] Set up Flink cluster (or use Confluent Cloud for Flink)
- [ ] Configure Kafka connectors
- [ ] Set up Schema Registry integration
- [ ] Configure checkpointing and state backends
- [ ] Set up monitoring and alerting

### Phase 3: SQL Translation
- [ ] Create table DDLs for all topics
- [ ] Migrate stateless transformations
- [ ] Migrate aggregations and windows
- [ ] Migrate joins
- [ ] Implement TopN and complex analytics
- [ ] Handle session windows

### Phase 4: State Management Migration
- [ ] Replace interactive queries with:
  - Flink Table Store for queryable state, OR
  - External database sinks, OR
  - Kafka changelog topics
- [ ] Migrate materialized views
- [ ] Implement CQRS pattern if needed

### Phase 5: Testing
- [ ] Unit test SQL queries
- [ ] Integration testing with test Kafka cluster
- [ ] Performance benchmarking
- [ ] Verify exactly-once semantics
- [ ] Test failure recovery

### Phase 6: Deployment
- [ ] Run parallel deployments (Kafka Streams + Flink)
- [ ] Compare results for correctness
- [ ] Monitor resource usage
- [ ] Gradual traffic migration
- [ ] Decommission Kafka Streams applications

---

## Advanced Patterns

### Custom Aggregations

**Kafka Streams:**
```java
.aggregate(
    () -> new CustomAggregator(),
    (key, value, agg) -> agg.add(value),
    Materialized.as("custom-store")
)
```

**Flink SQL:**
```sql
-- Use built-in aggregations or create UDAF
CREATE TEMPORARY FUNCTION custom_agg AS 'com.example.CustomAggregateFunction';

SELECT key, custom_agg(value)
FROM input_table
GROUP BY key;
```

### Branching Logic

**Kafka Streams:**
```java
Map<String, KStream<K, V>> branches = stream.split()
    .branch((k, v) -> v.getAmount() > 1000, Branched.as("high"))
    .branch((k, v) -> v.getAmount() <= 1000, Branched.as("low"))
    .noDefaultBranch();
```

**Flink SQL:**
```sql
-- Use INSERT INTO with WHERE clauses
INSERT INTO high_value_stream
SELECT * FROM input_stream WHERE amount > 1000;

INSERT INTO low_value_stream
SELECT * FROM input_stream WHERE amount <= 1000;
```

### Deduplication

**Kafka Streams:**
```java
stream.transform(() -> new DeduplicationTransformer<>(...))
```

**Flink SQL:**
```sql
SELECT
    order_id,
    customer_id,
    amount,
    event_time
FROM (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY event_time DESC) as rn
    FROM orders
)
WHERE rn = 1;
```

---

## Additional Resources

- **Flink SQL Documentation**: https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/table/sql/
- **Kafka Connector**: https://nightlies.apache.org/flink/flink-docs-stable/docs/connectors/table/kafka/
- **Schema Registry Format**: https://nightlies.apache.org/flink/flink-docs-stable/docs/connectors/table/formats/avro-confluent/
- **Confluent Flink SQL**: https://docs.confluent.io/cloud/current/flink/

---

## Summary

Migrating from Kafka Streams to Flink SQL offers:

**Benefits:**
- Declarative SQL syntax (easier to maintain)
- More powerful windowing and analytical functions
- Better separation of business logic from infrastructure
- Advanced features (TopN, pattern matching, complex joins)
- Scalability and resource management

**Challenges:**
- Interactive queries require architectural changes
- Different deployment model (cluster vs library)
- Learning curve for SQL-based stream processing
- Some custom logic may require UDFs

**Recommendation:** Start with stateless transformations and simple aggregations, then gradually migrate complex windowing and state management patterns.

