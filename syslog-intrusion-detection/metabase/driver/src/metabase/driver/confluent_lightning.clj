(ns metabase.driver.confluent-lightning
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

(driver/register! :confluent-lightning :parent :sql-jdbc)

(doseq [[feature supported?] {:describe-fields         true
                              :set-timezone            false
                              :nested-field-columns    false
                              :expression-literals     true}]
  (defmethod driver/database-supports? [:confluent-lightning feature] [_driver _feature _db] supported?))

(defmethod sql-jdbc.conn/connection-details->spec :confluent-lightning
  [_driver {:keys [lightning-endpoint environment-id lkc-id user password]}]
  ;; Public Confluent JDBC driver, Lightning (RTCE) mode. user/password are a Global API key/secret.
  ;; Extra keys become JDBC connection properties.
  {:classname   "io.confluent.jdbc.avatica.ConfluentJdbcDriver"
   :subprotocol "confluent:lightning"
   :subname     "//"
   :user        user
   :password    password
   (keyword "client.lightning-endpoint") lightning-endpoint
   (keyword "client.environment-id")     environment-id
   (keyword "client.lkc-id")             lkc-id
   (keyword "client.global-api-key")     user
   (keyword "client.global-api-secret")  password})

(defmethod sql-jdbc.conn/data-source-name :confluent-lightning
  [_driver {:keys [environment-id lkc-id]}]
  (format "confluent-lightning-%s-%s" environment-id lkc-id))

(defmethod driver/db-default-timezone :confluent-lightning [_driver _database] "UTC")
(defmethod driver/db-start-of-week :confluent-lightning [_driver] :monday)

(defmethod sql-jdbc.sync/database-type->base-type :confluent-lightning
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

;;; Lightning only accepts queries that reference a topic, so `SELECT 1` fails and getTables returns nothing.
;;; Use SHOW TABLES for both the connection test and table discovery.

(defmethod driver/can-connect? :confluent-lightning
  [driver details]
  (sql-jdbc.conn/with-connection-spec-for-testing-connection [spec [driver details]]
    (some? (jdbc/query spec ["SHOW TABLES"]))))

(defmethod driver/describe-database* :confluent-lightning
  [driver database]
  (sql-jdbc.execute/do-with-connection-with-options
   driver database nil
   (fn [^java.sql.Connection conn]
     {:tables (into #{}
                    (map (fn [row] {:name (first (vals row)), :schema nil}))
                    (jdbc/query {:connection conn} ["SHOW TABLES"]))})))

;; getColumns works only with the catalog (environment id) and schema (cluster id) spelled out; nulls match nothing. Metabase tables have no schema, so the default implementation can't be used.
(defmethod driver/describe-fields :confluent-lightning
  [driver database & {:keys [table-names]}]
  (sql-jdbc.execute/do-with-connection-with-options
   driver database nil
   (fn [^java.sql.Connection conn]
     (let [metadata (.getMetaData conn)
           {catalog :environment-id, schema :lkc-id} (:details database)
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

;;; Lightning supports neither FLOOR nor usable EXTRACT on its timestamp, so no temporal bucketing.
(defmethod sql.qp/date [:confluent-lightning :default] [_ _ expr] expr)

(defmethod sql.qp/current-datetime-honeysql-form :confluent-lightning
  [_driver]
  [:raw "CURRENT_TIMESTAMP"])

(defmethod sql.qp/add-interval-honeysql-form :confluent-lightning
  [_driver hsql-form amount unit]
  [:TIMESTAMPADD (h2x/identifier :type-name unit) (h2x/->integer amount) hsql-form])
