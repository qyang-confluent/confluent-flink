# Apache Flink SQL Use Cases and Examples

This document provides detailed use cases for Apache Flink with practical Flink SQL implementations.

## Table of Contents

1. [Real-time Fraud Detection](#1-real-time-fraud-detection)
2. [Streaming ETL Pipeline](#2-streaming-etl-pipeline)
3. [Real-time Analytics Dashboard](#3-real-time-analytics-dashboard)
4. [Customer 360 View](#4-customer-360-view)
5. [Anomaly Detection](#5-anomaly-detection)
6. [Real-time Inventory Management](#6-real-time-inventory-management)
7. [Click Stream Analysis](#7-click-stream-analysis)
8. [IoT Sensor Data Processing](#8-iot-sensor-data-processing)

---

## 1. Real-time Fraud Detection

### Use Case
Detect fraudulent transactions in real-time by analyzing transaction patterns, velocity, and anomalies across multiple dimensions.

### Business Value
- Prevent fraudulent transactions before they complete
- Reduce financial losses by 60-80%
- Improve customer trust and security

### Flink SQL Implementation

```sql
-- Create source table for incoming transactions
CREATE TABLE transactions (
    transaction_id STRING,
    user_id STRING,
    merchant_id STRING,
    amount DECIMAL(10, 2),
    currency STRING,
    card_number STRING,
    ip_address STRING,
    device_id STRING,
    location STRING,
    transaction_time TIMESTAMP(3),
    WATERMARK FOR transaction_time AS transaction_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'transactions',
    'properties.bootstrap.servers' = 'localhost:9092',
    'properties.group.id' = 'fraud-detection',
    'format' = 'json',
    'scan.startup.mode' = 'latest-offset'
);

-- Create table for user profile data (enrichment)
CREATE TABLE user_profiles (
    user_id STRING,
    country STRING,
    risk_score INT,
    account_age_days INT,
    PRIMARY KEY (user_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:postgresql://localhost:5432/userdb',
    'table-name' = 'user_profiles'
);

-- Velocity check: Count transactions per user in 5-minute windows
CREATE VIEW transaction_velocity AS
SELECT 
    user_id,
    COUNT(*) as txn_count,
    SUM(amount) as total_amount,
    TUMBLE_START(transaction_time, INTERVAL '5' MINUTE) as window_start,
    TUMBLE_END(transaction_time, INTERVAL '5' MINUTE) as window_end
FROM transactions
GROUP BY 
    user_id,
    TUMBLE(transaction_time, INTERVAL '5' MINUTE);

-- Detect duplicate transactions (potential replay attacks)
CREATE VIEW duplicate_transactions AS
SELECT 
    t1.transaction_id,
    t1.user_id,
    t1.amount,
    t1.merchant_id,
    t1.transaction_time,
    COUNT(*) as duplicate_count
FROM transactions t1
JOIN transactions t2
    ON t1.user_id = t2.user_id
    AND t1.merchant_id = t2.merchant_id
    AND t1.amount = t2.amount
    AND t2.transaction_time BETWEEN t1.transaction_time - INTERVAL '2' MINUTE 
                                AND t1.transaction_time + INTERVAL '2' MINUTE
GROUP BY 
    t1.transaction_id,
    t1.user_id,
    t1.amount,
    t1.merchant_id,
    t1.transaction_time
HAVING COUNT(*) > 1;

-- Flag suspicious transactions
CREATE TABLE fraud_alerts (
    transaction_id STRING,
    user_id STRING,
    amount DECIMAL(10, 2),
    fraud_reason STRING,
    risk_level STRING,
    detected_at TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'fraud-alerts',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Insert fraud alerts based on multiple rules
INSERT INTO fraud_alerts
SELECT 
    t.transaction_id,
    t.user_id,
    t.amount,
    CASE 
        WHEN v.txn_count > 10 THEN 'HIGH_VELOCITY'
        WHEN t.amount > 10000 THEN 'HIGH_AMOUNT'
        WHEN d.duplicate_count > 1 THEN 'DUPLICATE_TRANSACTION'
        WHEN up.risk_score > 80 THEN 'HIGH_RISK_USER'
    END as fraud_reason,
    CASE 
        WHEN v.txn_count > 20 OR t.amount > 50000 THEN 'CRITICAL'
        WHEN v.txn_count > 10 OR t.amount > 10000 THEN 'HIGH'
        ELSE 'MEDIUM'
    END as risk_level,
    CURRENT_TIMESTAMP as detected_at
FROM transactions t
LEFT JOIN transaction_velocity v 
    ON t.user_id = v.user_id 
    AND t.transaction_time BETWEEN v.window_start AND v.window_end
LEFT JOIN duplicate_transactions d
    ON t.transaction_id = d.transaction_id
LEFT JOIN user_profiles up
    ON t.user_id = up.user_id
WHERE 
    v.txn_count > 10 
    OR t.amount > 10000 
    OR d.duplicate_count > 1
    OR up.risk_score > 80;
```

---

## 2. Streaming ETL Pipeline

### Use Case
Continuously extract, transform, and load data from multiple sources into a data warehouse, with data quality checks and enrichment.

### Business Value
- Near real-time data availability (seconds vs hours)
- Automated data quality validation
- Reduced batch processing complexity

### Flink SQL Implementation

```sql
-- Source: Customer orders from Kafka
CREATE TABLE raw_orders (
    order_id STRING,
    customer_id STRING,
    product_id STRING,
    quantity INT,
    unit_price DECIMAL(10, 2),
    order_status STRING,
    order_timestamp TIMESTAMP(3),
    WATERMARK FOR order_timestamp AS order_timestamp - INTERVAL '10' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'raw-orders',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Dimension table: Product catalog
CREATE TABLE products (
    product_id STRING,
    product_name STRING,
    category STRING,
    brand STRING,
    cost DECIMAL(10, 2),
    PRIMARY KEY (product_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:mysql://localhost:3306/catalog',
    'table-name' = 'products'
);

-- Dimension table: Customer information
CREATE TABLE customers (
    customer_id STRING,
    customer_name STRING,
    email STRING,
    segment STRING,
    country STRING,
    PRIMARY KEY (customer_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:mysql://localhost:3306/crm',
    'table-name' = 'customers'
);

-- Transform and enrich orders
CREATE VIEW enriched_orders AS
SELECT 
    o.order_id,
    o.order_timestamp,
    o.customer_id,
    c.customer_name,
    c.email,
    c.segment,
    c.country,
    o.product_id,
    p.product_name,
    p.category,
    p.brand,
    o.quantity,
    o.unit_price,
    o.quantity * o.unit_price as total_amount,
    (o.quantity * o.unit_price) - (o.quantity * p.cost) as profit,
    o.order_status,
    -- Data quality flags
    CASE WHEN o.quantity <= 0 THEN TRUE ELSE FALSE END as invalid_quantity,
    CASE WHEN o.unit_price <= 0 THEN TRUE ELSE FALSE END as invalid_price,
    CASE WHEN c.customer_id IS NULL THEN TRUE ELSE FALSE END as unknown_customer,
    CASE WHEN p.product_id IS NULL THEN TRUE ELSE FALSE END as unknown_product
FROM raw_orders o
LEFT JOIN customers c ON o.customer_id = c.customer_id
LEFT JOIN products p ON o.product_id = p.product_id;

-- Sink: Clean data to data warehouse
CREATE TABLE dwh_orders (
    order_id STRING,
    order_timestamp TIMESTAMP(3),
    customer_id STRING,
    customer_name STRING,
    email STRING,
    segment STRING,
    country STRING,
    product_id STRING,
    product_name STRING,
    category STRING,
    brand STRING,
    quantity INT,
    unit_price DECIMAL(10, 2),
    total_amount DECIMAL(10, 2),
    profit DECIMAL(10, 2),
    order_status STRING,
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:postgresql://warehouse:5432/dwh',
    'table-name' = 'fact_orders'
);

-- Sink: Data quality issues
CREATE TABLE data_quality_issues (
    issue_id STRING,
    order_id STRING,
    issue_type STRING,
    issue_description STRING,
    detected_at TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'data-quality-issues',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Insert clean records to warehouse
INSERT INTO dwh_orders
SELECT 
    order_id,
    order_timestamp,
    customer_id,
    customer_name,
    email,
    segment,
    country,
    product_id,
    product_name,
    category,
    brand,
    quantity,
    unit_price,
    total_amount,
    profit,
    order_status
FROM enriched_orders
WHERE 
    NOT invalid_quantity 
    AND NOT invalid_price 
    AND NOT unknown_customer 
    AND NOT unknown_product;

-- Log data quality issues
INSERT INTO data_quality_issues
SELECT 
    CONCAT(order_id, '-', CAST(UNIX_TIMESTAMP() AS STRING)) as issue_id,
    order_id,
    CASE 
        WHEN invalid_quantity THEN 'INVALID_QUANTITY'
        WHEN invalid_price THEN 'INVALID_PRICE'
        WHEN unknown_customer THEN 'UNKNOWN_CUSTOMER'
        WHEN unknown_product THEN 'UNKNOWN_PRODUCT'
    END as issue_type,
    CASE 
        WHEN invalid_quantity THEN CONCAT('Quantity: ', CAST(quantity AS STRING))
        WHEN invalid_price THEN CONCAT('Price: ', CAST(unit_price AS STRING))
        WHEN unknown_customer THEN CONCAT('Customer ID: ', customer_id)
        WHEN unknown_product THEN CONCAT('Product ID: ', product_id)
    END as issue_description,
    CURRENT_TIMESTAMP as detected_at
FROM enriched_orders
WHERE 
    invalid_quantity 
    OR invalid_price 
    OR unknown_customer 
    OR unknown_product;
```

---

## 3. Real-time Analytics Dashboard

### Use Case
Power operational dashboards with live metrics on sales, revenue, and business KPIs updated every few seconds.

### Business Value
- Immediate visibility into business performance
- Fast response to emerging trends or issues
- Data-driven decision making in real-time

### Flink SQL Implementation

```sql
-- Source: Sales events
CREATE TABLE sales_events (
    sale_id STRING,
    store_id STRING,
    region STRING,
    product_category STRING,
    sale_amount DECIMAL(10, 2),
    quantity INT,
    payment_method STRING,
    sale_time TIMESTAMP(3),
    WATERMARK FOR sale_time AS sale_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'sales-events',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Real-time revenue by region (1-minute tumbling window)
CREATE VIEW revenue_by_region AS
SELECT 
    region,
    COUNT(*) as transaction_count,
    SUM(sale_amount) as total_revenue,
    AVG(sale_amount) as avg_transaction_value,
    SUM(quantity) as total_units_sold,
    TUMBLE_START(sale_time, INTERVAL '1' MINUTE) as window_start,
    TUMBLE_END(sale_time, INTERVAL '1' MINUTE) as window_end
FROM sales_events
GROUP BY 
    region,
    TUMBLE(sale_time, INTERVAL '1' MINUTE);

-- Top performing categories (5-minute sliding window)
CREATE VIEW top_categories AS
SELECT 
    product_category,
    SUM(sale_amount) as category_revenue,
    COUNT(*) as sales_count,
    HOP_START(sale_time, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE) as window_start,
    HOP_END(sale_time, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE) as window_end
FROM sales_events
GROUP BY 
    product_category,
    HOP(sale_time, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE);

-- Payment method distribution
CREATE VIEW payment_distribution AS
SELECT 
    payment_method,
    COUNT(*) as transaction_count,
    SUM(sale_amount) as total_amount,
    TUMBLE_START(sale_time, INTERVAL '1' MINUTE) as window_start
FROM sales_events
GROUP BY 
    payment_method,
    TUMBLE(sale_time, INTERVAL '1' MINUTE);

-- Store performance ranking
CREATE VIEW store_performance AS
SELECT 
    store_id,
    region,
    COUNT(*) as sales_count,
    SUM(sale_amount) as total_revenue,
    AVG(sale_amount) as avg_sale,
    MAX(sale_amount) as max_sale,
    ROW_NUMBER() OVER (
        PARTITION BY window_start 
        ORDER BY SUM(sale_amount) DESC
    ) as revenue_rank,
    TUMBLE_START(sale_time, INTERVAL '5' MINUTE) as window_start,
    TUMBLE_END(sale_time, INTERVAL '5' MINUTE) as window_end
FROM sales_events
GROUP BY 
    store_id,
    region,
    TUMBLE(sale_time, INTERVAL '5' MINUTE);

-- Output table for dashboard consumption
CREATE TABLE dashboard_metrics (
    metric_name STRING,
    dimension_key STRING,
    dimension_value STRING,
    metric_value DECIMAL(18, 2),
    metric_count BIGINT,
    window_start TIMESTAMP(3),
    window_end TIMESTAMP(3),
    updated_at TIMESTAMP(3)
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:postgresql://localhost:5432/analytics',
    'table-name' = 'live_metrics'
);

-- Materialize revenue metrics
INSERT INTO dashboard_metrics
SELECT 
    'revenue_by_region' as metric_name,
    'region' as dimension_key,
    region as dimension_value,
    total_revenue as metric_value,
    transaction_count as metric_count,
    window_start,
    window_end,
    CURRENT_TIMESTAMP as updated_at
FROM revenue_by_region;

-- Materialize category metrics
INSERT INTO dashboard_metrics
SELECT 
    'top_categories' as metric_name,
    'category' as dimension_key,
    product_category as dimension_value,
    category_revenue as metric_value,
    sales_count as metric_count,
    window_start,
    window_end,
    CURRENT_TIMESTAMP as updated_at
FROM top_categories;
```

---

## 4. Customer 360 View

### Use Case
Build a unified, real-time view of customer interactions across all touchpoints (web, mobile, support, transactions).

### Business Value
- Complete customer context for personalization
- Improved customer service and support
- Better targeting for marketing campaigns

### Flink SQL Implementation

```sql
-- Source: Web clickstream events
CREATE TABLE web_events (
    event_id STRING,
    customer_id STRING,
    page_url STRING,
    event_type STRING,
    session_id STRING,
    event_timestamp TIMESTAMP(3),
    WATERMARK FOR event_timestamp AS event_timestamp - INTERVAL '10' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'web-events',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Source: Customer transactions
CREATE TABLE customer_transactions (
    transaction_id STRING,
    customer_id STRING,
    amount DECIMAL(10, 2),
    product_category STRING,
    channel STRING,
    transaction_timestamp TIMESTAMP(3),
    WATERMARK FOR transaction_timestamp AS transaction_timestamp - INTERVAL '10' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'transactions',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Source: Support tickets
CREATE TABLE support_tickets (
    ticket_id STRING,
    customer_id STRING,
    category STRING,
    priority STRING,
    status STRING,
    created_timestamp TIMESTAMP(3),
    WATERMARK FOR created_timestamp AS created_timestamp - INTERVAL '10' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'support-tickets',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Calculate customer engagement score (30-day window)
CREATE VIEW customer_web_activity AS
SELECT 
    customer_id,
    COUNT(*) as page_views,
    COUNT(DISTINCT session_id) as sessions,
    COUNT(DISTINCT DATE_FORMAT(event_timestamp, 'yyyy-MM-dd')) as active_days,
    TUMBLE_START(event_timestamp, INTERVAL '1' DAY) as window_start
FROM web_events
WHERE event_timestamp > CURRENT_TIMESTAMP - INTERVAL '30' DAY
GROUP BY 
    customer_id,
    TUMBLE(event_timestamp, INTERVAL '1' DAY);

-- Calculate customer lifetime value metrics
CREATE VIEW customer_transaction_summary AS
SELECT 
    customer_id,
    COUNT(*) as transaction_count,
    SUM(amount) as total_spend,
    AVG(amount) as avg_transaction_value,
    MAX(amount) as max_transaction,
    COUNT(DISTINCT product_category) as categories_purchased,
    MAX(transaction_timestamp) as last_transaction_date,
    TUMBLE_START(transaction_timestamp, INTERVAL '1' DAY) as window_start
FROM customer_transactions
GROUP BY 
    customer_id,
    TUMBLE(transaction_timestamp, INTERVAL '1' DAY);

-- Track support interactions
CREATE VIEW customer_support_summary AS
SELECT 
    customer_id,
    COUNT(*) as total_tickets,
    SUM(CASE WHEN priority = 'HIGH' THEN 1 ELSE 0 END) as high_priority_tickets,
    SUM(CASE WHEN status = 'OPEN' THEN 1 ELSE 0 END) as open_tickets,
    MAX(created_timestamp) as last_ticket_date,
    TUMBLE_START(created_timestamp, INTERVAL '1' DAY) as window_start
FROM support_tickets
GROUP BY 
    customer_id,
    TUMBLE(created_timestamp, INTERVAL '1' DAY);

-- Build unified Customer 360 view
CREATE TABLE customer_360 (
    customer_id STRING,
    -- Engagement metrics
    total_page_views BIGINT,
    total_sessions BIGINT,
    active_days INT,
    -- Transaction metrics
    transaction_count BIGINT,
    total_lifetime_value DECIMAL(18, 2),
    avg_order_value DECIMAL(10, 2),
    categories_purchased INT,
    days_since_last_purchase INT,
    -- Support metrics
    total_support_tickets BIGINT,
    high_priority_tickets BIGINT,
    open_tickets BIGINT,
    days_since_last_ticket INT,
    -- Derived scores
    engagement_score DECIMAL(5, 2),
    customer_health_score DECIMAL(5, 2),
    churn_risk_flag BOOLEAN,
    last_updated TIMESTAMP(3),
    PRIMARY KEY (customer_id) NOT ENFORCED
) WITH (
    'connector' = 'upsert-kafka',
    'topic' = 'customer-360',
    'properties.bootstrap.servers' = 'localhost:9092',
    'key.format' = 'json',
    'value.format' = 'json'
);

-- Populate Customer 360 view
INSERT INTO customer_360
SELECT 
    COALESCE(w.customer_id, t.customer_id, s.customer_id) as customer_id,
    COALESCE(w.page_views, 0) as total_page_views,
    COALESCE(w.sessions, 0) as total_sessions,
    COALESCE(w.active_days, 0) as active_days,
    COALESCE(t.transaction_count, 0) as transaction_count,
    COALESCE(t.total_spend, 0) as total_lifetime_value,
    COALESCE(t.avg_transaction_value, 0) as avg_order_value,
    COALESCE(t.categories_purchased, 0) as categories_purchased,
    COALESCE(TIMESTAMPDIFF(DAY, t.last_transaction_date, CURRENT_TIMESTAMP), 9999) as days_since_last_purchase,
    COALESCE(s.total_tickets, 0) as total_support_tickets,
    COALESCE(s.high_priority_tickets, 0) as high_priority_tickets,
    COALESCE(s.open_tickets, 0) as open_tickets,
    COALESCE(TIMESTAMPDIFF(DAY, s.last_ticket_date, CURRENT_TIMESTAMP), 9999) as days_since_last_ticket,
    -- Engagement score (0-100)
    LEAST(100, (COALESCE(w.page_views, 0) / 10.0) + (COALESCE(w.sessions, 0) * 2)) as engagement_score,
    -- Health score (weighted combination)
    (
        (COALESCE(t.total_spend, 0) / 100.0) * 0.4 +
        (COALESCE(w.active_days, 0) * 2) * 0.3 +
        (100 - COALESCE(s.open_tickets, 0) * 10) * 0.3
    ) as customer_health_score,
    -- Churn risk: no purchase in 90 days AND low engagement
    CASE 
        WHEN TIMESTAMPDIFF(DAY, t.last_transaction_date, CURRENT_TIMESTAMP) > 90 
             AND COALESCE(w.page_views, 0) < 5 
        THEN TRUE 
        ELSE FALSE 
    END as churn_risk_flag,
    CURRENT_TIMESTAMP as last_updated
FROM customer_web_activity w
FULL OUTER JOIN customer_transaction_summary t 
    ON w.customer_id = t.customer_id AND w.window_start = t.window_start
FULL OUTER JOIN customer_support_summary s
    ON COALESCE(w.customer_id, t.customer_id) = s.customer_id 
    AND COALESCE(w.window_start, t.window_start) = s.window_start;
```

---

## 5. Anomaly Detection

### Use Case
Detect anomalies in time-series metrics (e.g., API latency, error rates, system metrics) using statistical methods.

### Business Value
- Proactive issue detection before customer impact
- Reduced MTTR (Mean Time To Resolution)
- Automated alerting for SLA violations

### Flink SQL Implementation

```sql
-- Source: Application metrics
CREATE TABLE app_metrics (
    metric_id STRING,
    service_name STRING,
    endpoint STRING,
    response_time_ms INT,
    status_code INT,
    error_message STRING,
    timestamp TIMESTAMP(3),
    WATERMARK FOR timestamp AS timestamp - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'app-metrics',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Calculate baseline statistics (30-minute window)
CREATE VIEW baseline_metrics AS
SELECT 
    service_name,
    endpoint,
    COUNT(*) as request_count,
    AVG(response_time_ms) as avg_response_time,
    STDDEV(CAST(response_time_ms AS DOUBLE)) as stddev_response_time,
    PERCENTILE(CAST(response_time_ms AS DOUBLE), 0.95) as p95_response_time,
    PERCENTILE(CAST(response_time_ms AS DOUBLE), 0.99) as p99_response_time,
    SUM(CASE WHEN status_code >= 500 THEN 1 ELSE 0 END) as error_count,
    CAST(SUM(CASE WHEN status_code >= 500 THEN 1 ELSE 0 END) AS DOUBLE) / COUNT(*) as error_rate,
    HOP_START(timestamp, INTERVAL '5' MINUTE, INTERVAL '30' MINUTE) as window_start,
    HOP_END(timestamp, INTERVAL '5' MINUTE, INTERVAL '30' MINUTE) as window_end
FROM app_metrics
GROUP BY 
    service_name,
    endpoint,
    HOP(timestamp, INTERVAL '5' MINUTE, INTERVAL '30' MINUTE);

-- Real-time metrics (1-minute window)
CREATE VIEW current_metrics AS
SELECT 
    service_name,
    endpoint,
    COUNT(*) as current_request_count,
    AVG(response_time_ms) as current_avg_response_time,
    SUM(CASE WHEN status_code >= 500 THEN 1 ELSE 0 END) as current_error_count,
    CAST(SUM(CASE WHEN status_code >= 500 THEN 1 ELSE 0 END) AS DOUBLE) / COUNT(*) as current_error_rate,
    TUMBLE_START(timestamp, INTERVAL '1' MINUTE) as window_start,
    TUMBLE_END(timestamp, INTERVAL '1' MINUTE) as window_end
FROM app_metrics
GROUP BY 
    service_name,
    endpoint,
    TUMBLE(timestamp, INTERVAL '1' MINUTE);

-- Detect anomalies using statistical thresholds
CREATE VIEW anomaly_detection AS
SELECT 
    c.service_name,
    c.endpoint,
    c.current_avg_response_time,
    b.avg_response_time as baseline_avg,
    b.stddev_response_time as baseline_stddev,
    c.current_error_rate,
    b.error_rate as baseline_error_rate,
    c.window_start,
    -- Z-score for response time
    (c.current_avg_response_time - b.avg_response_time) / NULLIF(b.stddev_response_time, 0) as response_time_zscore,
    -- Anomaly flags
    CASE 
        WHEN ABS((c.current_avg_response_time - b.avg_response_time) / NULLIF(b.stddev_response_time, 0)) > 3 
        THEN TRUE 
        ELSE FALSE 
    END as is_latency_anomaly,
    CASE 
        WHEN c.current_error_rate > b.error_rate * 2 AND c.current_error_rate > 0.05 
        THEN TRUE 
        ELSE FALSE 
    END as is_error_rate_anomaly,
    CASE 
        WHEN c.current_request_count < b.request_count * 0.3 
        THEN TRUE 
        ELSE FALSE 
    END as is_traffic_drop_anomaly
FROM current_metrics c
JOIN baseline_metrics b
    ON c.service_name = b.service_name
    AND c.endpoint = b.endpoint
    AND c.window_start BETWEEN b.window_start AND b.window_end;

-- Output: Anomaly alerts
CREATE TABLE anomaly_alerts (
    alert_id STRING,
    service_name STRING,
    endpoint STRING,
    anomaly_type STRING,
    severity STRING,
    current_value DECIMAL(10, 2),
    baseline_value DECIMAL(10, 2),
    deviation_score DECIMAL(10, 2),
    detected_at TIMESTAMP(3),
    window_start TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'anomaly-alerts',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Generate alerts for detected anomalies
INSERT INTO anomaly_alerts
SELECT 
    CONCAT(service_name, '-', endpoint, '-', CAST(UNIX_TIMESTAMP(window_start) AS STRING)) as alert_id,
    service_name,
    endpoint,
    CASE 
        WHEN is_latency_anomaly THEN 'LATENCY_SPIKE'
        WHEN is_error_rate_anomaly THEN 'ERROR_RATE_SPIKE'
        WHEN is_traffic_drop_anomaly THEN 'TRAFFIC_DROP'
    END as anomaly_type,
    CASE 
        WHEN ABS(response_time_zscore) > 5 OR current_error_rate > 0.2 THEN 'CRITICAL'
        WHEN ABS(response_time_zscore) > 3 OR current_error_rate > 0.1 THEN 'HIGH'
        ELSE 'MEDIUM'
    END as severity,
    CASE 
        WHEN is_latency_anomaly THEN current_avg_response_time
        WHEN is_error_rate_anomaly THEN current_error_rate * 100
        ELSE 0
    END as current_value,
    CASE 
        WHEN is_latency_anomaly THEN baseline_avg
        WHEN is_error_rate_anomaly THEN baseline_error_rate * 100
        ELSE 0
    END as baseline_value,
    ABS(response_time_zscore) as deviation_score,
    CURRENT_TIMESTAMP as detected_at,
    window_start
FROM anomaly_detection
WHERE 
    is_latency_anomaly = TRUE 
    OR is_error_rate_anomaly = TRUE 
    OR is_traffic_drop_anomaly = TRUE;
```

---

## 6. Real-time Inventory Management

### Use Case
Track inventory levels across multiple warehouses in real-time, trigger restock alerts, and optimize allocation.

### Business Value
- Prevent stockouts and lost sales
- Optimize inventory carrying costs
- Improve fulfillment speed and accuracy

### Flink SQL Implementation

```sql
-- Source: Inventory transactions (sales, restocks, returns)
CREATE TABLE inventory_transactions (
    transaction_id STRING,
    warehouse_id STRING,
    product_id STRING,
    transaction_type STRING, -- 'SALE', 'RESTOCK', 'RETURN', 'ADJUSTMENT'
    quantity INT,
    transaction_timestamp TIMESTAMP(3),
    WATERMARK FOR transaction_timestamp AS transaction_timestamp - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'inventory-transactions',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Reference: Product information
CREATE TABLE products (
    product_id STRING,
    product_name STRING,
    category STRING,
    min_stock_level INT,
    reorder_quantity INT,
    unit_cost DECIMAL(10, 2),
    PRIMARY KEY (product_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:mysql://localhost:3306/catalog',
    'table-name' = 'products'
);

-- Reference: Warehouse information
CREATE TABLE warehouses (
    warehouse_id STRING,
    warehouse_name STRING,
    region STRING,
    capacity INT,
    PRIMARY KEY (warehouse_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:mysql://localhost:3306/logistics',
    'table-name' = 'warehouses'
);

-- Calculate real-time inventory levels
CREATE VIEW current_inventory AS
SELECT 
    i.warehouse_id,
    i.product_id,
    SUM(
        CASE 
            WHEN i.transaction_type IN ('RESTOCK', 'RETURN') THEN i.quantity
            WHEN i.transaction_type IN ('SALE', 'ADJUSTMENT') THEN -i.quantity
            ELSE 0
        END
    ) as current_stock,
    COUNT(*) as transaction_count,
    MAX(i.transaction_timestamp) as last_update_time
FROM inventory_transactions i
GROUP BY 
    i.warehouse_id,
    i.product_id;

-- Calculate demand velocity (sales per hour)
CREATE VIEW demand_velocity AS
SELECT 
    warehouse_id,
    product_id,
    SUM(quantity) as units_sold,
    COUNT(*) as sale_count,
    SUM(quantity) / 24.0 as avg_daily_demand,
    HOP_START(transaction_timestamp, INTERVAL '1' HOUR, INTERVAL '24' HOUR) as window_start
FROM inventory_transactions
WHERE transaction_type = 'SALE'
GROUP BY 
    warehouse_id,
    product_id,
    HOP(transaction_timestamp, INTERVAL '1' HOUR, INTERVAL '24' HOUR);

-- Identify products needing reorder
CREATE VIEW reorder_recommendations AS
SELECT 
    inv.warehouse_id,
    w.warehouse_name,
    w.region,
    inv.product_id,
    p.product_name,
    p.category,
    inv.current_stock,
    p.min_stock_level,
    p.reorder_quantity,
    COALESCE(dv.avg_daily_demand, 0) as avg_daily_demand,
    -- Days until stockout
    CASE 
        WHEN COALESCE(dv.avg_daily_demand, 0) > 0 
        THEN inv.current_stock / dv.avg_daily_demand
        ELSE 999
    END as days_until_stockout,
    -- Recommended reorder quantity
    CASE 
        WHEN inv.current_stock < p.min_stock_level 
        THEN GREATEST(p.reorder_quantity, CAST(dv.avg_daily_demand * 7 AS INT))
        ELSE 0
    END as recommended_quantity,
    inv.last_update_time
FROM current_inventory inv
JOIN products p ON inv.product_id = p.product_id
JOIN warehouses w ON inv.warehouse_id = w.warehouse_id
LEFT JOIN demand_velocity dv 
    ON inv.warehouse_id = dv.warehouse_id 
    AND inv.product_id = dv.product_id
WHERE inv.current_stock < p.min_stock_level;

-- Output: Reorder alerts
CREATE TABLE reorder_alerts (
    alert_id STRING,
    warehouse_id STRING,
    warehouse_name STRING,
    product_id STRING,
    product_name STRING,
    current_stock INT,
    min_stock_level INT,
    recommended_quantity INT,
    days_until_stockout DECIMAL(10, 2),
    priority STRING,
    created_at TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'reorder-alerts',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Generate reorder alerts
INSERT INTO reorder_alerts
SELECT 
    CONCAT(warehouse_id, '-', product_id, '-', CAST(UNIX_TIMESTAMP() AS STRING)) as alert_id,
    warehouse_id,
    warehouse_name,
    product_id,
    product_name,
    current_stock,
    min_stock_level,
    recommended_quantity,
    days_until_stockout,
    CASE 
        WHEN days_until_stockout < 2 THEN 'URGENT'
        WHEN days_until_stockout < 5 THEN 'HIGH'
        ELSE 'NORMAL'
    END as priority,
    CURRENT_TIMESTAMP as created_at
FROM reorder_recommendations
WHERE current_stock < min_stock_level;

-- Output: Real-time inventory dashboard
CREATE TABLE inventory_dashboard (
    warehouse_id STRING,
    product_id STRING,
    current_stock INT,
    avg_daily_demand DECIMAL(10, 2),
    days_of_supply DECIMAL(10, 2),
    stock_status STRING,
    last_updated TIMESTAMP(3),
    PRIMARY KEY (warehouse_id, product_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:postgresql://localhost:5432/analytics',
    'table-name' = 'inventory_levels'
);

-- Update inventory dashboard
INSERT INTO inventory_dashboard
SELECT 
    inv.warehouse_id,
    inv.product_id,
    inv.current_stock,
    COALESCE(dv.avg_daily_demand, 0) as avg_daily_demand,
    CASE 
        WHEN COALESCE(dv.avg_daily_demand, 0) > 0 
        THEN inv.current_stock / dv.avg_daily_demand
        ELSE 999
    END as days_of_supply,
    CASE 
        WHEN inv.current_stock = 0 THEN 'OUT_OF_STOCK'
        WHEN inv.current_stock < p.min_stock_level THEN 'LOW_STOCK'
        WHEN inv.current_stock > p.min_stock_level * 3 THEN 'OVERSTOCK'
        ELSE 'NORMAL'
    END as stock_status,
    CURRENT_TIMESTAMP as last_updated
FROM current_inventory inv
JOIN products p ON inv.product_id = p.product_id
LEFT JOIN demand_velocity dv 
    ON inv.warehouse_id = dv.warehouse_id 
    AND inv.product_id = dv.product_id;
```

---

## 7. Click Stream Analysis

### Use Case
Analyze user behavior on websites and apps to optimize conversion funnels, detect abandonment, and personalize experiences.

### Business Value
- Increase conversion rates by 20-40%
- Reduce cart abandonment
- Personalized user experiences

### Flink SQL Implementation

```sql
-- Source: Clickstream events
CREATE TABLE clickstream (
    event_id STRING,
    user_id STRING,
    session_id STRING,
    page_url STRING,
    page_type STRING, -- 'HOME', 'PRODUCT', 'CART', 'CHECKOUT', 'CONFIRMATION'
    event_type STRING, -- 'PAGE_VIEW', 'CLICK', 'ADD_TO_CART', 'PURCHASE'
    product_id STRING,
    referrer_url STRING,
    user_agent STRING,
    ip_address STRING,
    event_timestamp TIMESTAMP(3),
    WATERMARK FOR event_timestamp AS event_timestamp - INTERVAL '10' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'clickstream',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Session analysis: Track user journey through the funnel
CREATE VIEW session_funnel AS
SELECT 
    session_id,
    user_id,
    MIN(event_timestamp) as session_start,
    MAX(event_timestamp) as session_end,
    COUNT(*) as total_events,
    COUNT(DISTINCT page_url) as unique_pages_viewed,
    MAX(CASE WHEN page_type = 'HOME' THEN 1 ELSE 0 END) as visited_home,
    MAX(CASE WHEN page_type = 'PRODUCT' THEN 1 ELSE 0 END) as visited_product,
    MAX(CASE WHEN event_type = 'ADD_TO_CART' THEN 1 ELSE 0 END) as added_to_cart,
    MAX(CASE WHEN page_type = 'CHECKOUT' THEN 1 ELSE 0 END) as started_checkout,
    MAX(CASE WHEN event_type = 'PURCHASE' THEN 1 ELSE 0 END) as completed_purchase,
    SESSION(event_timestamp, INTERVAL '30' MINUTE) as session_window
FROM clickstream
GROUP BY 
    session_id,
    user_id,
    SESSION(event_timestamp, INTERVAL '30' MINUTE);

-- Calculate conversion funnel metrics (hourly)
CREATE VIEW funnel_metrics AS
SELECT 
    COUNT(DISTINCT session_id) as total_sessions,
    SUM(visited_home) as homepage_visits,
    SUM(visited_product) as product_page_visits,
    SUM(added_to_cart) as add_to_cart_events,
    SUM(started_checkout) as checkout_started,
    SUM(completed_purchase) as purchases_completed,
    -- Conversion rates
    CAST(SUM(visited_product) AS DOUBLE) / COUNT(DISTINCT session_id) as home_to_product_rate,
    CAST(SUM(added_to_cart) AS DOUBLE) / NULLIF(SUM(visited_product), 0) as product_to_cart_rate,
    CAST(SUM(started_checkout) AS DOUBLE) / NULLIF(SUM(added_to_cart), 0) as cart_to_checkout_rate,
    CAST(SUM(completed_purchase) AS DOUBLE) / NULLIF(SUM(started_checkout), 0) as checkout_to_purchase_rate,
    CAST(SUM(completed_purchase) AS DOUBLE) / COUNT(DISTINCT session_id) as overall_conversion_rate,
    TUMBLE_START(session_start, INTERVAL '1' HOUR) as window_start,
    TUMBLE_END(session_start, INTERVAL '1' HOUR) as window_end
FROM session_funnel
GROUP BY TUMBLE(session_start, INTERVAL '1' HOUR);

-- Detect cart abandonment in real-time
CREATE VIEW cart_abandonment AS
SELECT 
    session_id,
    user_id,
    session_start,
    session_end,
    TIMESTAMPDIFF(MINUTE, MAX(event_timestamp), CURRENT_TIMESTAMP) as minutes_since_last_event,
    COUNT(DISTINCT CASE WHEN event_type = 'ADD_TO_CART' THEN product_id END) as products_in_cart
FROM clickstream
WHERE event_type = 'ADD_TO_CART'
GROUP BY session_id, user_id, session_start, session_end
HAVING 
    MAX(CASE WHEN event_type = 'PURCHASE' THEN 1 ELSE 0 END) = 0
    AND TIMESTAMPDIFF(MINUTE, MAX(event_timestamp), CURRENT_TIMESTAMP) > 10;

-- Top products viewed (no purchase)
CREATE VIEW popular_browsed_products AS
SELECT 
    product_id,
    COUNT(DISTINCT session_id) as view_count,
    COUNT(DISTINCT user_id) as unique_viewers,
    SUM(CASE WHEN event_type = 'ADD_TO_CART' THEN 1 ELSE 0 END) as add_to_cart_count,
    CAST(SUM(CASE WHEN event_type = 'ADD_TO_CART' THEN 1 ELSE 0 END) AS DOUBLE) / COUNT(*) as cart_add_rate,
    HOP_START(event_timestamp, INTERVAL '15' MINUTE, INTERVAL '1' HOUR) as window_start
FROM clickstream
WHERE page_type = 'PRODUCT' AND product_id IS NOT NULL
GROUP BY 
    product_id,
    HOP(event_timestamp, INTERVAL '15' MINUTE, INTERVAL '1' HOUR);

-- Identify high-exit pages
CREATE VIEW exit_page_analysis AS
SELECT 
    s1.page_url as exit_page,
    s1.page_type,
    COUNT(*) as exit_count,
    AVG(TIMESTAMPDIFF(SECOND, s2.first_event, s1.event_timestamp)) as avg_session_duration_seconds,
    TUMBLE_START(s1.event_timestamp, INTERVAL '30' MINUTE) as window_start
FROM (
    -- Last event in each session
    SELECT 
        session_id,
        page_url,
        page_type,
        event_timestamp,
        ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY event_timestamp DESC) as rn
    FROM clickstream
) s1
JOIN (
    -- First event in each session
    SELECT 
        session_id,
        MIN(event_timestamp) as first_event
    FROM clickstream
    GROUP BY session_id
) s2 ON s1.session_id = s2.session_id
WHERE s1.rn = 1
GROUP BY 
    s1.page_url,
    s1.page_type,
    TUMBLE(s1.event_timestamp, INTERVAL '30' MINUTE);

-- Output: Cart abandonment alerts
CREATE TABLE abandonment_alerts (
    alert_id STRING,
    user_id STRING,
    session_id STRING,
    products_in_cart INT,
    minutes_abandoned INT,
    alert_timestamp TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'cart-abandonment',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Trigger abandonment alerts
INSERT INTO abandonment_alerts
SELECT 
    CONCAT(session_id, '-', CAST(UNIX_TIMESTAMP() AS STRING)) as alert_id,
    user_id,
    session_id,
    products_in_cart,
    minutes_since_last_event as minutes_abandoned,
    CURRENT_TIMESTAMP as alert_timestamp
FROM cart_abandonment
WHERE minutes_since_last_event BETWEEN 10 AND 60;

-- Output: Funnel analytics
CREATE TABLE funnel_analytics (
    metric_name STRING,
    metric_value DECIMAL(18, 4),
    window_start TIMESTAMP(3),
    window_end TIMESTAMP(3)
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:postgresql://localhost:5432/analytics',
    'table-name' = 'conversion_funnel'
);

-- Write funnel metrics
INSERT INTO funnel_analytics
SELECT 'overall_conversion_rate', overall_conversion_rate, window_start, window_end FROM funnel_metrics
UNION ALL
SELECT 'home_to_product_rate', home_to_product_rate, window_start, window_end FROM funnel_metrics
UNION ALL
SELECT 'product_to_cart_rate', product_to_cart_rate, window_start, window_end FROM funnel_metrics
UNION ALL
SELECT 'cart_to_checkout_rate', cart_to_checkout_rate, window_start, window_end FROM funnel_metrics
UNION ALL
SELECT 'checkout_to_purchase_rate', checkout_to_purchase_rate, window_start, window_end FROM funnel_metrics;
```

---

## 8. IoT Sensor Data Processing

### Use Case
Process high-volume sensor data from IoT devices for predictive maintenance, real-time monitoring, and automated alerting.

### Business Value
- Reduce equipment downtime by 30-50%
- Extend asset lifespan through predictive maintenance
- Optimize operational efficiency

### Flink SQL Implementation

```sql
-- Source: IoT sensor readings
CREATE TABLE sensor_readings (
    device_id STRING,
    sensor_type STRING, -- 'TEMPERATURE', 'VIBRATION', 'PRESSURE', 'HUMIDITY'
    sensor_value DOUBLE,
    unit STRING,
    location STRING,
    asset_id STRING,
    reading_timestamp TIMESTAMP(3),
    WATERMARK FOR reading_timestamp AS reading_timestamp - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'iot-sensors',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Reference: Device metadata
CREATE TABLE devices (
    device_id STRING,
    device_name STRING,
    asset_id STRING,
    asset_type STRING,
    manufacturer STRING,
    install_date DATE,
    PRIMARY KEY (device_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:postgresql://localhost:5432/iot',
    'table-name' = 'devices'
);

-- Reference: Sensor thresholds for alerting
CREATE TABLE sensor_thresholds (
    sensor_type STRING,
    asset_type STRING,
    min_normal_value DOUBLE,
    max_normal_value DOUBLE,
    critical_min DOUBLE,
    critical_max DOUBLE,
    PRIMARY KEY (sensor_type, asset_type) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:postgresql://localhost:5432/iot',
    'table-name' = 'sensor_thresholds'
);

-- Calculate rolling statistics for each sensor (5-minute window)
CREATE VIEW sensor_statistics AS
SELECT 
    device_id,
    sensor_type,
    asset_id,
    location,
    COUNT(*) as reading_count,
    AVG(sensor_value) as avg_value,
    MIN(sensor_value) as min_value,
    MAX(sensor_value) as max_value,
    STDDEV(sensor_value) as stddev_value,
    HOP_START(reading_timestamp, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE) as window_start,
    HOP_END(reading_timestamp, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE) as window_end
FROM sensor_readings
GROUP BY 
    device_id,
    sensor_type,
    asset_id,
    location,
    HOP(reading_timestamp, INTERVAL '1' MINUTE, INTERVAL '5' MINUTE);

-- Detect out-of-range sensor readings
CREATE VIEW sensor_violations AS
SELECT 
    s.device_id,
    d.device_name,
    s.sensor_type,
    s.asset_id,
    d.asset_type,
    s.sensor_value,
    s.unit,
    t.min_normal_value,
    t.max_normal_value,
    t.critical_min,
    t.critical_max,
    s.reading_timestamp,
    CASE 
        WHEN s.sensor_value < t.critical_min OR s.sensor_value > t.critical_max THEN 'CRITICAL'
        WHEN s.sensor_value < t.min_normal_value OR s.sensor_value > t.max_normal_value THEN 'WARNING'
        ELSE 'NORMAL'
    END as severity
FROM sensor_readings s
JOIN devices d ON s.device_id = d.device_id
JOIN sensor_thresholds t ON s.sensor_type = t.sensor_type AND d.asset_type = t.asset_type
WHERE 
    s.sensor_value < t.min_normal_value 
    OR s.sensor_value > t.max_normal_value;

-- Detect anomalous patterns using statistical deviation
CREATE VIEW anomaly_patterns AS
SELECT 
    curr.device_id,
    curr.sensor_type,
    curr.asset_id,
    curr.sensor_value as current_value,
    stats.avg_value as baseline_avg,
    stats.stddev_value as baseline_stddev,
    (curr.sensor_value - stats.avg_value) / NULLIF(stats.stddev_value, 0) as z_score,
    curr.reading_timestamp
FROM sensor_readings curr
JOIN sensor_statistics stats
    ON curr.device_id = stats.device_id
    AND curr.sensor_type = stats.sensor_type
    AND curr.reading_timestamp BETWEEN stats.window_start AND stats.window_end
WHERE ABS((curr.sensor_value - stats.avg_value) / NULLIF(stats.stddev_value, 0)) > 3;

-- Detect sustained high readings (potential equipment failure)
CREATE VIEW sustained_high_readings AS
SELECT 
    device_id,
    sensor_type,
    asset_id,
    COUNT(*) as violation_count,
    AVG(sensor_value) as avg_violation_value,
    MIN(reading_timestamp) as first_violation,
    MAX(reading_timestamp) as last_violation,
    TUMBLE_START(reading_timestamp, INTERVAL '10' MINUTE) as window_start
FROM sensor_violations
WHERE severity IN ('WARNING', 'CRITICAL')
GROUP BY 
    device_id,
    sensor_type,
    asset_id,
    TUMBLE(reading_timestamp, INTERVAL '10' MINUTE)
HAVING COUNT(*) > 5; -- More than 5 violations in 10 minutes

-- Calculate equipment health score
CREATE VIEW equipment_health AS
SELECT 
    d.asset_id,
    d.asset_type,
    d.device_name,
    d.location,
    COUNT(DISTINCT s.device_id) as sensor_count,
    AVG(
        CASE 
            WHEN s.sensor_type = 'TEMPERATURE' THEN s.avg_value 
        END
    ) as avg_temperature,
    AVG(
        CASE 
            WHEN s.sensor_type = 'VIBRATION' THEN s.avg_value 
        END
    ) as avg_vibration,
    COUNT(DISTINCT v.device_id) as devices_with_violations,
    -- Health score (100 = perfect, 0 = critical)
    100 - (COUNT(DISTINCT v.device_id) * 10) - 
          (COUNT(DISTINCT CASE WHEN v.severity = 'CRITICAL' THEN v.device_id END) * 20) as health_score,
    s.window_start
FROM sensor_statistics s
JOIN devices d ON s.device_id = d.device_id
LEFT JOIN sensor_violations v 
    ON s.device_id = v.device_id 
    AND v.reading_timestamp BETWEEN s.window_start AND s.window_end
GROUP BY 
    d.asset_id,
    d.asset_type,
    d.device_name,
    d.location,
    s.window_start;

-- Output: Real-time alerts
CREATE TABLE sensor_alerts (
    alert_id STRING,
    device_id STRING,
    device_name STRING,
    sensor_type STRING,
    alert_type STRING, -- 'THRESHOLD_VIOLATION', 'ANOMALY', 'SUSTAINED_HIGH'
    severity STRING,
    current_value DOUBLE,
    expected_range STRING,
    message STRING,
    created_at TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'sensor-alerts',
    'properties.bootstrap.servers' = 'localhost:9092',
    'format' = 'json'
);

-- Generate threshold violation alerts
INSERT INTO sensor_alerts
SELECT 
    CONCAT(device_id, '-', sensor_type, '-', CAST(UNIX_TIMESTAMP(reading_timestamp) AS STRING)) as alert_id,
    device_id,
    device_name,
    sensor_type,
    'THRESHOLD_VIOLATION' as alert_type,
    severity,
    sensor_value as current_value,
    CONCAT(CAST(min_normal_value AS STRING), ' - ', CAST(max_normal_value AS STRING), ' ', unit) as expected_range,
    CONCAT(sensor_type, ' reading of ', CAST(sensor_value AS STRING), ' ', unit, 
           ' is outside normal range for ', asset_type) as message,
    CURRENT_TIMESTAMP as created_at
FROM sensor_violations
WHERE severity = 'CRITICAL';

-- Generate sustained high reading alerts
INSERT INTO sensor_alerts
SELECT 
    CONCAT(device_id, '-', sensor_type, '-sustained-', CAST(UNIX_TIMESTAMP(window_start) AS STRING)) as alert_id,
    device_id,
    CAST(NULL AS STRING) as device_name,
    sensor_type,
    'SUSTAINED_HIGH' as alert_type,
    'CRITICAL' as severity,
    avg_violation_value as current_value,
    CONCAT(CAST(violation_count AS STRING), ' violations in 10 minutes') as expected_range,
    CONCAT('Sustained high ', sensor_type, ' readings detected. ', 
           CAST(violation_count AS STRING), ' violations in 10 minutes.') as message,
    CURRENT_TIMESTAMP as created_at
FROM sustained_high_readings;

-- Output: Equipment health dashboard
CREATE TABLE equipment_health_dashboard (
    asset_id STRING,
    asset_type STRING,
    device_name STRING,
    location STRING,
    health_score INT,
    avg_temperature DOUBLE,
    avg_vibration DOUBLE,
    active_sensors INT,
    devices_with_issues INT,
    status STRING,
    last_updated TIMESTAMP(3),
    PRIMARY KEY (asset_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:postgresql://localhost:5432/analytics',
    'table-name' = 'equipment_health'
);

-- Update equipment health dashboard
INSERT INTO equipment_health_dashboard
SELECT 
    asset_id,
    asset_type,
    device_name,
    location,
    CAST(health_score AS INT) as health_score,
    avg_temperature,
    avg_vibration,
    sensor_count as active_sensors,
    devices_with_violations as devices_with_issues,
    CASE 
        WHEN health_score >= 80 THEN 'HEALTHY'
        WHEN health_score >= 60 THEN 'DEGRADED'
        WHEN health_score >= 40 THEN 'WARNING'
        ELSE 'CRITICAL'
    END as status,
    CURRENT_TIMESTAMP as last_updated
FROM equipment_health;
```

---

## Best Practices for Flink SQL

### 1. Watermark Strategy
- Use watermarks to handle late-arriving events
- Adjust watermark delay based on data source characteristics
- Monitor watermark progress to detect backpressure

### 2. Window Selection
- **Tumbling windows**: Non-overlapping, fixed-size windows for periodic aggregations
- **Hopping windows**: Overlapping windows for moving averages and trend analysis
- **Session windows**: Dynamic windows based on activity gaps (e.g., user sessions)

### 3. State Management
- Use changelog mode for updates (upsert-kafka connector)
- Configure state backend (RocksDB for large state)
- Set TTL for state to prevent unbounded growth

### 4. Performance Optimization
- Filter early in the query to reduce data volume
- Use temporal joins for dimension lookups
- Partition data appropriately in Kafka topics
- Monitor checkpointing and adjust intervals

### 5. Testing
- Test with realistic data volumes
- Validate watermark behavior with late data
- Monitor resource usage (CPU, memory, network)
- Set up proper alerting for job failures

---

## Deployment Considerations

### Resource Configuration
```sql
-- Set parallelism for the job
SET 'parallelism.default' = '4';

-- Configure checkpointing
SET 'execution.checkpointing.interval' = '60s';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';

-- State backend configuration
SET 'state.backend' = 'rocksdb';
SET 'state.backend.rocksdb.localdir' = '/tmp/flink/rocksdb';

-- Network buffer configuration
SET 'taskmanager.network.memory.fraction' = '0.2';
```

### Monitoring Queries
```sql
-- Enable metrics reporting
SET 'metrics.reporters' = 'prometheus';
SET 'metrics.reporter.prometheus.class' = 'org.apache.flink.metrics.prometheus.PrometheusReporter';
SET 'metrics.reporter.prometheus.port' = '9091';
```

---

## Additional Resources

- Apache Flink SQL Documentation: https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/table/sql/overview/
- Flink SQL Connectors: https://nightlies.apache.org/flink/flink-docs-stable/docs/connectors/table/overview/
- Flink Best Practices: https://nightlies.apache.org/flink/flink-docs-stable/docs/learn-flink/overview/
