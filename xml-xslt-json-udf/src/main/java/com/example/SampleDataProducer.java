package com.example;

import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;
import org.apache.kafka.common.serialization.StringSerializer;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

/**
 * Sends the sample XML payload (src/main/resources/input.xml, or a file given as the second
 * CLI arg) as a single message to the input topic, for manually testing
 * {@link KafkaXmlToAvroTransformer} end-to-end.
 */
public class SampleDataProducer {

    public static void main(String[] args) throws Exception {
        Properties clientConfig = ClientConfig.load(args);
        String inputTopic = clientConfig.getProperty(ClientConfig.INPUT_TOPIC_CONFIG, ClientConfig.DEFAULT_INPUT_TOPIC);
        String payloadDescription = args.length > 1 ? args[1] : "classpath:input.xml";
        String xml = args.length > 1
                ? Files.readString(Path.of(args[1]), StandardCharsets.UTF_8)
                : readSampleResource();

        Properties props = ClientConfig.kafkaClientProperties(clientConfig);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        // A one-shot test send doesn't need idempotence, and skipping it avoids the
        // InitProducerId handshake (which needs a reachable transaction coordinator).
        props.putIfAbsent(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "false");

        try (KafkaProducer<String, String> producer = new KafkaProducer<>(props)) {
            RecordMetadata metadata = producer.send(new ProducerRecord<>(inputTopic, xml)).get();
            System.out.println("Sent " + payloadDescription + " to '" + inputTopic
                    + "' (partition " + metadata.partition() + ", offset " + metadata.offset() + ")");
        }
    }

    private static String readSampleResource() throws IOException {
        try (InputStream in = SampleDataProducer.class.getClassLoader().getResourceAsStream("input.xml")) {
            if (in == null) {
                throw new IOException("Classpath resource not found: input.xml");
            }
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
