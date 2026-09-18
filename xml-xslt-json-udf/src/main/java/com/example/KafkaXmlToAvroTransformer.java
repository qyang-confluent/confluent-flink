package com.example;

import com.example.avro.ProductRecord;
import com.fasterxml.jackson.dataformat.xml.XmlMapper;
import com.fasterxml.jackson.dataformat.xml.annotation.JacksonXmlElementWrapper;
import com.fasterxml.jackson.dataformat.xml.annotation.JacksonXmlProperty;

import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.errors.WakeupException;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;

import javax.xml.transform.Templates;
import java.math.BigDecimal;
import java.time.Duration;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicBoolean;

public class KafkaXmlToAvroTransformer {

    public static void main(String[] args) throws Exception {
        Properties clientConfig = ClientConfig.load(args);
        String inputTopic = clientConfig.getProperty(ClientConfig.INPUT_TOPIC_CONFIG, ClientConfig.DEFAULT_INPUT_TOPIC);
        String outputTopic = clientConfig.getProperty(ClientConfig.OUTPUT_TOPIC_CONFIG, ClientConfig.DEFAULT_OUTPUT_TOPIC);
        Templates xsltTemplates = XsltTransform.compile("transform.xsl");
        XmlMapper xmlMapper = new XmlMapper();

        try (KafkaConsumer<String, String> consumer = createConsumer(clientConfig);
             KafkaProducer<String, ProductRecord> producer = createProducer(clientConfig)) {

            AtomicBoolean running = new AtomicBoolean(true);
            Thread mainThread = Thread.currentThread();
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                running.set(false);
                consumer.wakeup();
                try {
                    mainThread.join();
                } catch (InterruptedException ignored) {
                }
            }));

            consumer.subscribe(List.of(inputTopic));
            System.out.println("Consuming XML from '" + inputTopic + "', producing Avro to '" + outputTopic + "'...");

            try {
                while (running.get()) {
                    ConsumerRecords<String, String> records = consumer.poll(Duration.ofSeconds(1));
                    AtomicBoolean batchHadSendFailure = new AtomicBoolean(false);
                    for (ConsumerRecord<String, String> record : records) {
                        try {
                            processRecord(record.value(), outputTopic, xsltTemplates, xmlMapper, producer, batchHadSendFailure);
                        } catch (Exception e) {
                            System.err.println("Skipping record at offset " + record.offset() + ": " + e.getMessage());
                        }
                    }
                    if (!records.isEmpty()) {
                        producer.flush();
                        if (batchHadSendFailure.get()) {
                            System.err.println("Not committing offsets: at least one send to '" + outputTopic + "' failed for this batch.");
                        } else {
                            consumer.commitSync();
                        }
                    }
                }
            } catch (WakeupException e) {
                // triggered by shutdown hook; fall through to close consumer/producer
            }
        }
        System.out.println("Shut down.");
    }

    private static void processRecord(
            String xml,
            String outputTopic,
            Templates xsltTemplates,
            XmlMapper xmlMapper,
            KafkaProducer<String, ProductRecord> producer,
            AtomicBoolean batchHadSendFailure
    ) throws Exception {
        String transformedXml = XsltTransform.apply(xml, xsltTemplates);
        Products products = xmlMapper.readValue(transformedXml, Products.class);

        for (Product product : products.products) {
            ProductRecord avroRecord = ProductRecord.newBuilder()
                    .setName(product.name)
                    .setPrice(product.price.doubleValue())
                    .setCategory(product.category)
                    .build();
            producer.send(new ProducerRecord<>(outputTopic, product.name, avroRecord), (metadata, exception) -> {
                if (exception != null) {
                    batchHadSendFailure.set(true);
                    System.err.println("Failed to send '" + product.name + "' to '" + outputTopic + "': " + exception);
                }
            });
        }
    }

    private static KafkaConsumer<String, String> createConsumer(Properties base) {
        Properties props = ClientConfig.kafkaClientProperties(base);
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.putIfAbsent(ConsumerConfig.GROUP_ID_CONFIG, "xml-xslt-avro-consumer");
        props.putIfAbsent(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
        return new KafkaConsumer<>(props);
    }

    private static KafkaProducer<String, ProductRecord> createProducer(Properties base) {
        Properties props = ClientConfig.kafkaClientProperties(base);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, "io.confluent.kafka.serializers.KafkaAvroSerializer");
        props.putIfAbsent(ProducerConfig.ACKS_CONFIG, "all");
        return new KafkaProducer<>(props);
    }

    public static class Products {
        @JacksonXmlElementWrapper(useWrapping = false)
        @JacksonXmlProperty(localName = "product")
        public List<Product> products;
    }

    public static class Product {
        public String name;
        public BigDecimal price;
        public String category;
    }
}
