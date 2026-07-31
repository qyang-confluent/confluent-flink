# Apache Flink SQL Best Practices

A practical reference for writing correct, performant, and maintainable Flink SQL — covering complex queries, subqueries, and changelog (append/upsert) semantics.

---

## Table of Contents

1. [Understanding Changelog Modes](#1-understanding-changelog-modes)
2. [Subquery Best Practices](#2-subquery-best-practices)
3. [Append-Only Query & Sink Limitations](#3-append-only-query--sink-limitations)
4. [Upsert Query & Sink Limitations](#4-upsert-query--sink-limitations)
5. [Mixing Changelog Modes](#5-mixing-changelog-modes)
6. [State Management](#6-state-management)
7. [Performance Tuning](#7-performance-tuning)
8. [Query Structure & Maintainability](#8-query-structure--maintainability)
9. [Troubleshooting Checklist](#9-troubleshooting-checklist)

---

## 1. Understanding Changelog Modes

Every Flink SQL query produces a **changelog stream** in one of these modes:

| Mode | Record kinds | Notes |
|---|---|---|
| **Insert-only (Append)** | `+I` only | Never updates or deletes |
| **Upsert** | `+I`, `+U` | No `-U`/`-D` needed; requires a declared key |
| **Retract** | `+I`, `-D`, `+U`, `-U` | Full before/after image; no key required, but heavier |

Always inspect the plan before optimizing:

```sql
EXPLAIN SELECT ...
```

This reveals whether a query/subquery compiles into a `Join`, `GroupAggregate`, `Rank`, `Correlate`, or `Changelog Normalize` — each has different state implications.

---

## 2. Subquery Best Practices

### 2.1 Prefer JOINs over correlated subqueries

```sql
-- Avoid:
SELECT o.order_id, o.amount
FROM orders o
WHERE o.customer_id IN (SELECT customer_id FROM vip_customers)

-- Prefer:
SELECT o.order_id, o.amount
FROM orders o
JOIN vip_customers v ON o.customer_id = v.customer_id
```

Correlated subqueries are harder for the optimizer to reason about and often produce larger intermediate state.

### 2.2 Use temporal table joins for dimension lookups

Don't use a subquery to "look up the current value" of a reference table — use a temporal join for correct point-in-time semantics and bounded lookup cost:

```sql
SELECT o.order_id, o.amount, c.tier
FROM orders o
JOIN customers FOR SYSTEM_TIME AS OF o.proc_time AS c
ON o.customer_id = c.customer_id
```

### 2.3 Replace subquery-based "latest record" logic with `ROW_NUMBER()`

```sql
SELECT *
FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY id ORDER BY event_time DESC) AS rn
  FROM events
)
WHERE rn = 1
```

Flink has a dedicated, efficient top-N operator for this pattern — avoid reinventing it with nested subqueries.

### 2.4 Be careful with `EXISTS` / `IN` / `NOT IN`

- These retain state indefinitely by default — set a TTL:
  ```sql
  SET 'table.exec.state.ttl' = '1 h';
  ```
- `NOT IN` / `NOT EXISTS` track "absence," which is more state-expensive and can behave unexpectedly with late or retracted data.

### 2.5 Avoid non-determinism inside subqueries

- Avoid `ORDER BY ... LIMIT` without a proper partition/time key.
- Avoid non-deterministic functions (`NOW()`, `RAND()`, `UUID()`) inside subqueries — they can produce inconsistent results across retractions.

### 2.6 Watch time attributes across subquery boundaries

`proc_time` / `rowtime` attributes can be silently lost when passing through a subquery, aggregation, or non-windowed join. If downstream logic needs windowing or temporal joins, keep the time attribute alive explicitly.

### 2.7 CTEs (`WITH`) are not automatically materialized

A CTE referenced multiple times may be **inlined and recomputed** per reference, not shared. If a CTE is expensive and reused:

- Extract it into a `CREATE VIEW`, or
- Check `EXPLAIN` output for duplicate subtrees, or
- Split into separate statements using `STATEMENT SET` for multi-sink jobs.

```sql
CREATE VIEW enriched_orders AS
SELECT o.*, c.tier
FROM orders o
JOIN customers FOR SYSTEM_TIME AS OF o.proc_time AS c
ON o.customer_id = c.customer_id;
```

---

## 3. Append-Only Query & Sink Limitations

### What forces upsert/retract mode

These operators generally **cannot** produce append-only output:

- `GROUP BY` aggregation without windowing (values can update as new rows arrive)
- `ROW_NUMBER()` top-N / deduplication
- Non-windowed joins where a row can be retracted
- `EXISTS` / `IN` / `NOT IN` subqueries in many plans

### Sink compatibility

Append-only sinks — plain Kafka, Filesystem, Blackhole, Print — **reject** queries that produce updates/deletes at planning time:

```
Table sink 'x' doesn't support consuming update changes which is produced by node ...
```

### Workaround: use windowed aggregation

Windowed aggregations emit one final append-only result per window/key:

```sql
SELECT window_start, window_end, id, COUNT(*)
FROM TABLE(TUMBLE(TABLE events, DESCRIPTOR(event_time), INTERVAL '1' MINUTE))
GROUP BY window_start, window_end, id
```

---

## 4. Upsert Query & Sink Limitations

### Requires a declared primary key

Upsert sinks (JDBC, `upsert-kafka`, HBase, Elasticsearch) need a `PRIMARY KEY` in the DDL so Flink knows how to apply `+U`/`-D`:

```sql
CREATE TABLE sink_table (
  id BIGINT,
  amount DECIMAL(10,2),
  PRIMARY KEY (id) NOT ENFORCED
) WITH (
  'connector' = 'upsert-kafka',
  ...
);
```

### Key limitations to keep in mind

| Limitation | Detail |
|---|---|
| **No true deletes on plain Kafka** | Use `upsert-kafka` (tombstone = null value) instead of the plain Kafka connector |
| **Partitioning matters** | Records with the same key must land in the same partition, or final compacted state can be wrong |
| **Loses change history** | Downstream consumers only see "latest value per key" — sink a separate append/retract audit log if full history is needed |
| **`NOT ENFORCED` key is not validated** | Flink trusts your key is truly unique; if it isn't, upserts silently overwrite unrelated rows |

---

## 5. Mixing Changelog Modes

- Joining an append-only stream with an upsert/retract stream may force Flink to insert a **`Changelog Normalize`** operator, which materializes full state keyed by the declared primary key — factor this into state sizing.
- Regular (non-temporal) joins on two unbounded upsert/retract streams keep **unbounded state on both sides** — there's no automatic cleanup unless `table.exec.state.ttl` is set.

---

## 6. State Management

- Set explicit TTL for any query with unbounded key-based state:
  ```sql
  SET 'table.exec.state.ttl' = '1 h';
  ```
- Use **RocksDB** state backend instead of heap state for large key spaces (e.g., `IN`/`NOT EXISTS` subqueries against big tables, high-cardinality joins) to avoid GC pressure and OOMs.
- Prefer **windowed** aggregations/joins over unbounded ones wherever business logic allows — they bound state naturally via watermark-triggered cleanup.

---

## 7. Performance Tuning

```sql
-- Mini-batching: reduces per-record state access for high-cardinality joins/aggregations
SET 'table.exec.mini-batch.enabled' = 'true';
SET 'table.exec.mini-batch.allow-latency' = '5 s';
SET 'table.exec.mini-batch.size' = '5000';

-- Two-phase (local + global) aggregation: reduces shuffle/state for GROUP BY
SET 'table.optimizer.agg-phase-strategy' = 'TWO_PHASE';
```

Use these especially when subqueries compile down into joins or aggregations over high-cardinality keys.

---

## 8. Query Structure & Maintainability

Break very complex, deeply nested queries into **layered views**:

```
raw → cleaned → enriched → aggregated
```

Benefits:

- `EXPLAIN` output is easier to read per stage
- Intermediate stages can be tested/validated independently
- Easier to reason about state cost per stage
- Easier onboarding/review for teammates

---

## 9. Troubleshooting Checklist

When you hit a changelog-mode or performance issue:

1. **Run `EXPLAIN`** (and `EXPLAIN CHANGELOG_MODE` where available) to see what mode each part of the plan produces.
2. **Sink rejects updates?** Either switch to an upsert-capable sink (`upsert-kafka`, JDBC) or restructure the query as a windowed aggregation.
3. **Using an upsert sink?** Confirm the DDL declares a real, unique `PRIMARY KEY`.
4. **State growing unbounded?** Look for `NOT IN` / `NOT EXISTS` / non-windowed joins and add `table.exec.state.ttl`.
5. **CTE reused multiple times?** Check `EXPLAIN` for duplicate subtrees; materialize via a view if needed.
6. **Time attribute errors downstream?** Confirm `rowtime`/`proc_time` survived any subquery, join, or aggregation it passed through.
7. **High state size?** Switch to RocksDB backend and/or add mini-batching and two-phase aggregation.

---

*Reference for Apache Flink SQL (Table API / SQL). Behavior may vary slightly by Flink version — always validate against `EXPLAIN` output for your specific job.*
