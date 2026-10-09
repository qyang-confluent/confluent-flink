#!/usr/bin/env python3
"""
Kafka Chatbot Web Application
A Flask-based web chatbot that integrates with Confluent Cloud Kafka.
"""

from flask import Flask, render_template, request, jsonify, session
from confluent_kafka import Producer, Consumer, KafkaError
from confluent_kafka.serialization import SerializationContext, MessageField
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroSerializer, AvroDeserializer
import json
import uuid
import time
import threading
from datetime import datetime
import os

app = Flask(__name__)
app.secret_key = os.urandom(24)

# Kafka configuration for Confluent Cloud
KAFKA_CONFIG = {
    'bootstrap.servers': os.getenv('KAFKA_BOOTSTRAP_SERVERS', 'YOUR_BOOTSTRAP_SERVER.confluent.cloud:9092'),
    'sasl.username': os.getenv('KAFKA_API_KEY', 'YOUR_API_KEY'),
    'sasl.password': os.getenv('KAFKA_API_SECRET', 'YOUR_API_SECRET'),
    'query_topic': 'chatbot_input',
    'response_topic': 'chatbot_output',
    'group.id': 'chatbot-web-consumer-group',
    'schema.registry.url': os.getenv('SCHEMA_REGISTRY_URL', 'YOUR_SCHEMA_REGISTRY_URL'),
    'schema.registry.basic.auth.user.info': os.getenv('SCHEMA_REGISTRY_API_KEY', 'YOUR_SR_KEY') + ':' + os.getenv('SCHEMA_REGISTRY_API_SECRET', 'YOUR_SR_SECRET')
}

# Avro schema for queries topic key
QUERIES_KEY_SCHEMA = """{
    "type": "record",
    "name": "chatbot_input_key",
    "namespace": "org.apache.flink.avro.generated.record",
    "fields": [
        {"name": "query_id", "type": "string"}
    ]
}"""

# Avro schema for queries topic value
QUERIES_VALUE_SCHEMA = """{
    "type": "record",
    "name": "queries_value",
    "namespace": "org.apache.flink.avro.generated.record",
    "fields": [
        {"name": "query", "type": ["null", "string"], "default": null}
    ]
}"""

# Avro schema for chatbot_output topic key
CHATBOT_OUT_KEY_SCHEMA = """{
    "type": "record",
    "name": "chatbot_output_key",
    "namespace": "org.apache.flink.avro.generated.record",
    "fields": [
        {"name": "query_id", "type": "string"}
    ]
}"""

# Avro schema for chatbot_output topic value
SEARCH_RESULTS_RESPONSE_SCHEMA = """{
    "type": "record",
    "name": "chatbot_output_value",
    "namespace": "org.apache.flink.avro.generated.record",
    "fields": [
        {"name": "query", "type": ["null", "string"], "default": null},
        {"name": "document_id_1", "type": ["null", "string"], "default": null},
        {"name": "chunk_1", "type": ["null", "string"], "default": null},
        {"name": "score_1", "type": ["null", "double"], "default": null},
        {"name": "document_id_2", "type": ["null", "string"], "default": null},
        {"name": "chunk_2", "type": ["null", "string"], "default": null},
        {"name": "score_2", "type": ["null", "double"], "default": null},
        {"name": "document_id_3", "type": ["null", "string"], "default": null},
        {"name": "chunk_3", "type": ["null", "string"], "default": null},
        {"name": "score_3", "type": ["null", "double"], "default": null},
        {"name": "response", "type": ["null", "string"], "default": null}
    ]
}"""

# Global storage for pending responses
pending_responses = {}
response_lock = threading.Lock()

# Initialize Kafka producer and serializers
producer = None
consumer = None
consumer_running = False
schema_registry_client = None
avro_key_serializer = None
avro_serializer = None
avro_key_deserializer = None
avro_deserializer = None


def init_kafka_producer():
    """Initialize Kafka producer with Avro serialization."""
    global producer, schema_registry_client, avro_key_serializer, avro_serializer
    try:
        # Initialize Schema Registry client
        schema_registry_conf = {
            'url': KAFKA_CONFIG['schema.registry.url'],
            'basic.auth.user.info': KAFKA_CONFIG['schema.registry.basic.auth.user.info']
        }
        schema_registry_client = SchemaRegistryClient(schema_registry_conf)
        print("✓ Schema Registry client initialized")

        # Initialize Avro key serializer
        avro_key_serializer = AvroSerializer(
            schema_registry_client,
            QUERIES_KEY_SCHEMA,
            lambda obj, ctx: obj  # Pass dict directly to serializer
        )
        print("✓ Avro key serializer initialized")

        # Initialize Avro value serializer
        avro_serializer = AvroSerializer(
            schema_registry_client,
            QUERIES_VALUE_SCHEMA,
            lambda obj, ctx: obj  # Pass dict directly to serializer
        )
        print("✓ Avro value serializer initialized")

        # Initialize Kafka producer
        producer_config = {
            'bootstrap.servers': KAFKA_CONFIG['bootstrap.servers'],
            'security.protocol': 'SASL_SSL',
            'sasl.mechanisms': 'PLAIN',
            'sasl.username': KAFKA_CONFIG['sasl.username'],
            'sasl.password': KAFKA_CONFIG['sasl.password'],
            'client.id': 'chatbot-web-producer'
        }
        producer = Producer(producer_config)
        print("✓ Kafka Producer initialized")
        return True
    except Exception as e:
        print(f"⚠ Failed to initialize Kafka Producer: {e}")
        import traceback
        traceback.print_exc()
        return False


def init_kafka_consumer():
    """Initialize Kafka consumer with Avro deserialization."""
    global consumer, consumer_running, avro_key_deserializer, avro_deserializer
    try:
        # Initialize Avro deserializers for response topic
        if schema_registry_client:
            avro_key_deserializer = AvroDeserializer(
                schema_registry_client,
                CHATBOT_OUT_KEY_SCHEMA,
                lambda obj, ctx: obj  # Return dict directly
            )
            print("✓ Avro key deserializer initialized")

            avro_deserializer = AvroDeserializer(
                schema_registry_client,
                SEARCH_RESULTS_RESPONSE_SCHEMA,
                lambda obj, ctx: obj  # Return dict directly
            )
            print("✓ Avro value deserializer initialized")

        consumer_config = {
            'bootstrap.servers': KAFKA_CONFIG['bootstrap.servers'],
            'security.protocol': 'SASL_SSL',
            'sasl.mechanisms': 'PLAIN',
            'sasl.username': KAFKA_CONFIG['sasl.username'],
            'sasl.password': KAFKA_CONFIG['sasl.password'],
            'group.id': KAFKA_CONFIG['group.id'],
            'auto.offset.reset': 'latest',
            'enable.auto.commit': True,
            'client.id': 'chatbot-web-consumer'
        }
        consumer = Consumer(consumer_config)
        consumer.subscribe([KAFKA_CONFIG['response_topic']])
        print(f"✓ Kafka Consumer initialized, subscribed to '{KAFKA_CONFIG['response_topic']}'")

        # Start consumer thread
        consumer_running = True
        consumer_thread = threading.Thread(target=consume_kafka_responses, daemon=True)
        consumer_thread.start()
        return True
    except Exception as e:
        print(f"⚠ Failed to initialize Kafka Consumer: {e}")
        import traceback
        traceback.print_exc()
        return False


def consume_kafka_responses():
    """Background thread to consume responses from Kafka with Avro deserialization."""
    global consumer, consumer_running, pending_responses

    print("[Consumer thread started]")
    while consumer_running:
        try:
            msg = consumer.poll(timeout=1.0)

            if msg is None:
                continue

            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    continue
                else:
                    print(f"⚠ Consumer error: {msg.error()}")
                    continue

            # Process the message
            try:
                # Deserialize Avro key
                if avro_key_deserializer and msg.key():
                    key_data = avro_key_deserializer(
                        msg.key(),
                        SerializationContext(KAFKA_CONFIG['response_topic'], MessageField.KEY)
                    )
                    query_id = key_data.get('query_id') if key_data else None
                else:
                    # Fallback to string key if deserializer not available
                    query_id = msg.key().decode('utf-8') if msg.key() else None

                # Deserialize Avro value
                if avro_deserializer:
                    response_data = avro_deserializer(
                        msg.value(),
                        SerializationContext(KAFKA_CONFIG['response_topic'], MessageField.VALUE)
                    )
                else:
                    # Fallback to JSON if deserializer not available
                    response_data = json.loads(msg.value().decode('utf-8'))

                if query_id and response_data:
                    # Extract only the response field
                    response_text = response_data.get('response', 'No response available')

                    with response_lock:
                        pending_responses[query_id] = {
                            'response': response_text,
                            'timestamp': datetime.now().isoformat()
                        }
                    print(f"✓ Received response for query_id: {query_id}")

            except Exception as decode_error:
                print(f"⚠ Could not decode Kafka message: {decode_error}")
                import traceback
                traceback.print_exc()

        except Exception as e:
            print(f"⚠ Error in consumer thread: {e}")
            import traceback
            traceback.print_exc()

    print("[Consumer thread stopped]")


def publish_to_kafka(query, query_id):
    """Publish query to Kafka with Avro serialization."""
    if not producer or not avro_key_serializer or not avro_serializer:
        return False

    try:
        # Create key according to Avro key schema
        avro_key = {
            'query_id': query_id
        }

        # Create value according to Avro value schema
        avro_value = {
            'query': query
        }

        # Serialize the key using Avro
        serialized_key = avro_key_serializer(
            avro_key,
            SerializationContext(KAFKA_CONFIG['query_topic'], MessageField.KEY)
        )

        # Serialize the value using Avro
        serialized_value = avro_serializer(
            avro_value,
            SerializationContext(KAFKA_CONFIG['query_topic'], MessageField.VALUE)
        )

        producer.produce(
            topic=KAFKA_CONFIG['query_topic'],
            key=serialized_key,
            value=serialized_value
        )
        producer.poll(0)
        print(f"✓ Published query to Kafka (Avro key+value): {query_id}")
        return True

    except Exception as e:
        print(f"⚠ Failed to publish to Kafka: {e}")
        import traceback
        traceback.print_exc()
        return False


def wait_for_kafka_response(query_id, timeout=10):
    """Wait for a response from Kafka with timeout."""
    start_time = time.time()

    while time.time() - start_time < timeout:
        with response_lock:
            if query_id in pending_responses:
                response = pending_responses.pop(query_id)
                return response
        time.sleep(0.1)

    return None


@app.route('/')
def index():
    """Render the chat interface."""
    if 'user_id' not in session:
        session['user_id'] = str(uuid.uuid4())
    return render_template('index.html')


@app.route('/api/chat', methods=['POST'])
def chat():
    """Handle chat messages."""
    data = request.get_json()
    user_message = data.get('message', '').strip()

    if not user_message:
        return jsonify({'error': 'Empty message'}), 400

    # Generate unique query ID
    query_id = f"query-{uuid.uuid4()}"

    # Try to send to Kafka
    response_text = None
    source = "local"

    if producer:
        success = publish_to_kafka(user_message, query_id)
        if success:
            # Wait for response from Kafka
            kafka_response = wait_for_kafka_response(query_id, timeout=300)
            if kafka_response:
                response_text = kafka_response['response']
                source = "kafka"
            else:
                response_text = "I sent your query to the search service, but didn't receive a response in time. Please try again."
                source = "timeout"
        else:
            response_text = "Sorry, I'm having trouble connecting to the search service right now."
            source = "error"
    else:
        response_text = "Kafka is not configured. Please check the connection settings."
        source = "no-kafka"

    return jsonify({
        'response': response_text,
        'query_id': query_id,
        'source': source,
        'timestamp': datetime.now().isoformat()
    })


@app.route('/api/health', methods=['GET'])
def health():
    """Health check endpoint."""
    return jsonify({
        'status': 'healthy',
        'kafka_producer': producer is not None,
        'kafka_consumer': consumer is not None,
        'consumer_running': consumer_running
    })


if __name__ == '__main__':
    print("=" * 70)
    print("Kafka Chatbot Web Application with Avro Serialization")
    print("=" * 70)
    print(f"\nQuery Topic:      {KAFKA_CONFIG['query_topic']} (Avro)")
    print(f"Response Topic:   {KAFKA_CONFIG['response_topic']} (Avro)")
    print(f"Bootstrap:        {KAFKA_CONFIG['bootstrap.servers']}")
    print(f"Schema Registry:  {KAFKA_CONFIG['schema.registry.url']}")
    print("\n⚠  Set environment variables for Confluent Cloud:")
    print("   Kafka:")
    print("   - KAFKA_BOOTSTRAP_SERVERS")
    print("   - KAFKA_API_KEY")
    print("   - KAFKA_API_SECRET")
    print("   Schema Registry:")
    print("   - SCHEMA_REGISTRY_URL")
    print("   - SCHEMA_REGISTRY_API_KEY")
    print("   - SCHEMA_REGISTRY_API_SECRET")
    print("=" * 70)

    # Initialize Kafka
    init_kafka_producer()
    init_kafka_consumer()

    # Run Flask app
    print("\nStarting Flask server...")
    app.run(host='0.0.0.0', port=5000, debug=True, use_reloader=False)
