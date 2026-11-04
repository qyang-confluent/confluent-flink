ARG MB_VERSION=v0.59.31

# Stage 1: build the Metabase driver plugin that wraps the Confluent JDBC driver.
FROM clojure:temurin-21-tools-deps AS build
ARG MB_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends git zip && rm -rf /var/lib/apt/lists/*
RUN git clone -q --depth 1 --branch ${MB_VERSION} https://github.com/metabase/metabase /metabase
WORKDIR /metabase
COPY driver modules/drivers/confluent-flink
# Public driver, https://docs.confluent.io/cloud/current/flink/operate-and-deploy/connect-with-jdbc.html
ARG JDBC_VERSION=1.0.0
ADD https://packages.confluent.io/maven/io/confluent/jdbc/confluent-jdbc/${JDBC_VERSION}/confluent-jdbc-${JDBC_VERSION}.jar modules/drivers/confluent-flink/confluent-jdbc.jar
# The embedded poms can have an unresolvable parent, which breaks tools.deps.
RUN zip -q -d modules/drivers/confluent-flink/confluent-jdbc.jar 'META-INF/maven/*'
RUN sed -i 's|metabase/vertica            {:local/root "vertica"}|metabase/vertica {:local/root "vertica"} metabase/confluent-flink {:local/root "confluent-flink"}|' modules/drivers/deps.edn \
    && grep -q confluent-flink modules/drivers/deps.edn
RUN ./bin/build-driver.sh confluent-flink

# Stage 2: stock Metabase plus the plugin.
FROM metabase/metabase:${MB_VERSION}
COPY --from=build /metabase/resources/modules/confluent-flink.metabase-driver.jar /plugins/
