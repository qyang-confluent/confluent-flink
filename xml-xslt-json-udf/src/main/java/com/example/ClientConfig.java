package com.example;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Properties;

final class ClientConfig {

    static final String CONFIG_ENV_VAR = "KAFKA_CLIENT_CONFIG";
    static final String DEFAULT_CONFIG_PATH = "client.properties";
    static final String INPUT_TOPIC_CONFIG = "app.topic.input";
    static final String OUTPUT_TOPIC_CONFIG = "app.topic.output";
    static final String DEFAULT_INPUT_TOPIC = "xml-input-topic";
    static final String DEFAULT_OUTPUT_TOPIC = "product-output-topic";

    private ClientConfig() {
    }

    static Properties load(String[] args) throws IOException {
        Path path = Paths.get(
                args.length > 0 ? args[0] : System.getenv().getOrDefault(CONFIG_ENV_VAR, DEFAULT_CONFIG_PATH)
        );
        if (!Files.exists(path)) {
            throw new IOException(
                    "Kafka client config file not found: " + path.toAbsolutePath()
                            + " (pass a path as the first argument, or set " + CONFIG_ENV_VAR + ")"
            );
        }
        Properties props = new Properties();
        try (InputStream in = Files.newInputStream(path)) {
            props.load(in);
        }
        return props;
    }

    static Properties kafkaClientProperties(Properties base) {
        Properties props = new Properties();
        props.putAll(base);
        props.remove(INPUT_TOPIC_CONFIG);
        props.remove(OUTPUT_TOPIC_CONFIG);
        return props;
    }
}
