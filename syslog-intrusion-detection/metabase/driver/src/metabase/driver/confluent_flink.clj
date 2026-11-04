(ns metabase.driver.confluent-flink
  (:require
   [clojure.java.jdbc :as jdbc]
   [metabase.driver :as driver]
   [metabase.driver.sql-jdbc.execute :as sql-jdbc.execute]
   [metabase.driver.sql-jdbc.connection :as sql-jdbc.conn]
   [metabase.driver.sql-jdbc.sync :as sql-jdbc.sync]
   [metabase.driver.sql-jdbc.sync.describe-table :as sql-jdbc.describe-table]
   [metabase.driver.sql.query-processor :as sql.qp]
   [metabase.util.honey-sql-2 :as h2x]))

(set! *warn-on-reflection* true)

(driver/register! :confluent-flink :parent :sql-jdbc)

(doseq [[feature supported?] {:describe-fields         true
                              :set-timezone            false
                              :nested-field-columns    false
                              :expression-literals     true}]
  (defmethod driver/database-supports? [:confluent-flink feature] [_driver _feature _db] supported?))

(defmethod sql-jdbc.conn/connection-details->spec :confluent-flink
  [_driver {:keys [cloud region organization-id environment-id compute-pool-id catalog database user password]}]
  ;; Public Confluent JDBC driver (io.confluent.jdbc:confluent-jdbc). user/password are a Flink API key/secret.
  ;; Extra keys become JDBC connection properties (see "Connect with JDBC" in the Confluent Cloud Flink docs).
  {:classname   "io.confluent.jdbc.avatica.ConfluentJdbcDriver"
   :subprotocol "confluent:flink"
   :subname     (format "//flink.%s.%s.confluent.cloud" region cloud)
   :user        user
   :password    password
   (keyword "client.organization-id")  organization-id
   (keyword "client.environment-id")   environment-id
   (keyword "client.compute-pool-id")  compute-pool-id
   (keyword "client.cloud")            cloud
   (keyword "client.region")           region
   (keyword "sql.current-catalog")     catalog
   (keyword "sql.current-database")    database})

(defmethod sql-jdbc.conn/data-source-name :confluent-flink
  [_driver {:keys [environment-id compute-pool-id]}]
  (format "confluent-flink-%s-%s" environment-id compute-pool-id))

;; Flink SQL quotes identifiers with backticks.
(defmethod sql.qp/quote-style :confluent-flink [_driver] :mysql)

(defmethod driver/db-default-timezone :confluent-flink [_driver _database] "UTC")
(defmethod driver/db-start-of-week :confluent-flink [_driver] :monday)

(defmethod sql-jdbc.sync/database-type->base-type :confluent-flink
  [_driver database-type]
  ({:VARCHAR                  :type/Text
    :CHAR                     :type/Text
    :BOOLEAN                  :type/Boolean
    :TINYINT                  :type/Integer
    :SMALLINT                 :type/Integer
    :INTEGER                  :type/Integer
    :BIGINT                   :type/BigInteger
    :FLOAT                    :type/Float
    :DOUBLE                   :type/Float
    :DECIMAL                  :type/Decimal
    :DATE                     :type/Date
    :TIME                     :type/Time
    :TIMESTAMP                :type/DateTime
    :TIMESTAMP_WITH_TIME_ZONE :type/DateTimeWithLocalTZ
    :VARBINARY                :type/*}
   database-type
   :type/*))

;;; Use SHOW TABLES (in the configured catalog/database) for both the connection test and table discovery.
;;; Every query runs as a bounded snapshot query, so results are finite.

(defmethod driver/can-connect? :confluent-flink
  [driver details]
  (sql-jdbc.conn/with-connection-spec-for-testing-connection [spec [driver details]]
    (some? (jdbc/query spec ["SHOW TABLES"]))))

(defmethod driver/describe-database* :confluent-flink
  [driver database]
  (sql-jdbc.execute/do-with-connection-with-options
   driver database nil
   (fn [^java.sql.Connection conn]
     {:tables (into #{}
                    (map (fn [row] {:name (first (vals row)), :schema nil}))
                    (jdbc/query {:connection conn} ["SHOW TABLES"]))})))

;; getColumns takes the catalog (environment name) and schema (Kafka cluster name) spelled out. Metabase tables have no schema, so the default implementation can't be used.
(defmethod driver/describe-fields :confluent-flink
  [driver database & {:keys [table-names]}]
  (sql-jdbc.execute/do-with-connection-with-options
   driver database nil
   (fn [^java.sql.Connection conn]
     (let [metadata (.getMetaData conn)
           {:keys [catalog database]} (:details database)
           schema   database
           tables   (or (seq table-names)
                        (map (comp first vals) (jdbc/query {:connection conn} ["SHOW TABLES"])))]
       (into []
             (comp cat (sql-jdbc.describe-table/describe-fields-xf driver database))
             (for [table tables]
               (with-open [rs (.getColumns metadata catalog schema table "%")]
                 (loop [cols []]
                   (if (.next rs)
                     (recur (cond-> cols
                              ;; skip $$-prefixed system columns
                              (not (.startsWith (.getString rs "COLUMN_NAME") "$$"))
                              (conj {:table-name        table
                                     :table-schema      nil
                                     :name              (.getString rs "COLUMN_NAME")
                                     :database-type     (.getString rs "TYPE_NAME")
                                     :database-position (dec (.getInt rs "ORDINAL_POSITION"))})))
                     cols)))))))))

;;; No temporal bucketing for now (keeps the raw window_start on the time chart).
(defmethod sql.qp/date [:confluent-flink :default] [_ _ expr] expr)

(defmethod sql.qp/current-datetime-honeysql-form :confluent-flink
  [_driver]
  [:raw "CURRENT_TIMESTAMP"])

(defmethod sql.qp/add-interval-honeysql-form :confluent-flink
  [_driver hsql-form amount unit]
  [:TIMESTAMPADD (h2x/identifier :type-name unit) (h2x/->integer amount) hsql-form])
