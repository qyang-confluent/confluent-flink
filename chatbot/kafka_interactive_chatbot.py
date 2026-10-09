#!/usr/bin/env python3
"""
Interactive Kafka Chatbot
Sends user questions to 'queries' topic and receives responses from 'search_results_response' topic.
"""

import re
import random
import json
import threading
import time
from datetime import datetime
from confluent_kafka import Producer, Consumer, KafkaError
import socket


class InteractiveKafkaChatbot:
    def __init__(self, name="Bot", kafka_config=None):
        self.name = name
        self.conversation_history = []
        self.running = False

        # Kafka configuration
        self.kafka_config = kafka_config or {}
        self.producer = None
        self.consumer = None
        self.query_topic = kafka_config.get('query_topic', 'queries') if kafka_config else 'queries'
        self.response_topic = kafka_config.get('response_topic', 'search_results_response') if kafka_config else 'search_results_response'

        # Pending responses (correlation tracking)
        self.pending_responses = {}

        if kafka_config:
            self._setup_kafka()

        # Local response patterns (fallback)
        self.patterns = {
            r'\b(hi|hello|hey)\b': [
                "Hello! How can I help you today?",
                "Hi there! What's on your mind?",
                "Hey! Nice to meet you!"
            ],
            r'\b(how are you|how\'s it going)\b': [
                "I'm doing great, thanks for asking! How about you?",
                "I'm functioning perfectly! How are you?",
                "All systems operational! How can I assist you?"
            ],
            r'\b(what is your name|who are you)\b': [
                f"I'm {self.name}, your friendly chatbot assistant!",
                f"My name is {self.name}. Nice to meet you!",
                f"I'm {self.name}, here to chat with you!"
            ],
            r'\b(bye|goodbye|see you)\b': [
                "Goodbye! Have a great day!",
                "See you later! Take care!",
                "Bye! Feel free to come back anytime!"
            ],
            r'\b(thank|thanks)\b': [
                "You're welcome!",
                "Happy to help!",
                "Anytime! Glad I could assist."
            ],
        }

        self.default_responses = [
            "That's interesting! Tell me more.",
            "I see. Can you elaborate on that?",
            "Hmm, I'm not sure I understand completely. Could you rephrase?",
        ]

    def _setup_kafka(self):
        """Initialize Kafka producer and consumer."""
        try:
            # Producer configuration
            producer_config = {
                'bootstrap.servers': self.kafka_config.get('bootstrap.servers'),
                'security.protocol': 'SASL_SSL',
                'sasl.mechanisms': 'PLAIN',
                'sasl.username': self.kafka_config.get('sasl.username'),
                'sasl.password': self.kafka_config.get('sasl.password'),
                'client.id': f"{socket.gethostname()}-producer"
            }
            self.producer = Producer(producer_config)
            print(f"✓ Kafka Producer connected")

            # Consumer configuration
            consumer_config = {
                'bootstrap.servers': self.kafka_config.get('bootstrap.servers'),
                'security.protocol': 'SASL_SSL',
                'sasl.mechanisms': 'PLAIN',
                'sasl.username': self.kafka_config.get('sasl.username'),
                'sasl.password': self.kafka_config.get('sasl.password'),
                'group.id': self.kafka_config.get('group.id', 'chatbot-consumer-group'),
                'auto.offset.reset': 'latest',  # Only read new messages
                'enable.auto.commit': True,
                'client.id': f"{socket.gethostname()}-consumer"
            }
            self.consumer = Consumer(consumer_config)
            self.consumer.subscribe([self.response_topic])
            print(f"✓ Kafka Consumer connected to topic '{self.response_topic}'")

        except Exception as e:
            print(f"⚠ Warning: Could not connect to Kafka: {e}")
            print("  Continuing without Kafka integration...")

    def _delivery_callback(self, err, msg):
        """Callback for Kafka message delivery."""
        if err:
            print(f"⚠ Message delivery failed: {err}")
        else:
            print(f"✓ Query sent to {msg.topic()}")

    def publish_query(self, user_input, query_id):
        """Publish user question to Kafka 'queries' topic."""
        if not self.producer:
            return False

        try:
            message = {
                'query_id': query_id,
                'timestamp': datetime.now().isoformat(),
                'query': user_input,
                'bot_name': self.name
            }

            self.producer.produce(
                topic=self.query_topic,
                key=query_id,
                value=json.dumps(message),
                callback=self._delivery_callback
            )

            # Trigger delivery reports
            self.producer.poll(0)
            return True

        except Exception as e:
            print(f"⚠ Failed to publish to Kafka: {e}")
            return False

    def consume_responses(self):
        """Background thread to consume responses from Kafka."""
        print(f"[Consumer thread started, listening to '{self.response_topic}']")

        while self.running:
            try:
                msg = self.consumer.poll(timeout=1.0)

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
                    response_data = json.loads(msg.value().decode('utf-8'))
                    query_id = response_data.get('query_id', msg.key().decode('utf-8') if msg.key() else None)

                    if query_id and query_id in self.pending_responses:
                        self.pending_responses[query_id] = response_data
                        print(f"\n✓ Received response from Kafka!")
                        print(f"{self.name}: {response_data.get('response', response_data.get('result', 'No response content'))}\n")
                        print("You: ", end='', flush=True)

                except json.JSONDecodeError:
                    print(f"⚠ Could not decode message from Kafka")

            except Exception as e:
                print(f"⚠ Error in consumer thread: {e}")

        print("[Consumer thread stopped]")

    def get_local_response(self, user_input):
        """Generate a local response based on patterns."""
        user_input_lower = user_input.lower()

        # Check patterns
        for pattern, responses in self.patterns.items():
            if re.search(pattern, user_input_lower):
                return random.choice(responses)

        # Default response if no pattern matches
        return random.choice(self.default_responses)

    def chat(self):
        """Main chat loop."""
        print(f"\n{self.name}: Hello! I'm {self.name}, your chatbot.")

        if self.producer and self.consumer:
            print(f"{self.name}: Connected to Kafka!")
            print(f"  → Sending queries to: '{self.query_topic}'")
            print(f"  ← Receiving responses from: '{self.response_topic}'")

            # Start consumer thread
            self.running = True
            consumer_thread = threading.Thread(target=self.consume_responses, daemon=True)
            consumer_thread.start()
        else:
            print(f"{self.name}: Running in local mode (no Kafka connection)")

        print(f"{self.name}: Type 'quit' or 'exit' to end the conversation.\n")

        while True:
            try:
                user_input = input("You: ").strip()

                if not user_input:
                    continue

                if user_input.lower() in ['quit', 'exit']:
                    self.running = False
                    if self.producer:
                        self.producer.flush()
                    if self.consumer:
                        self.consumer.close()
                    print(f"\n{self.name}: Goodbye! Thanks for chatting with me!\n")
                    break

                # Generate query ID
                query_id = f"query-{int(datetime.now().timestamp() * 1000)}"

                # Store conversation
                self.conversation_history.append({
                    'query_id': query_id,
                    'user': user_input,
                    'timestamp': datetime.now()
                })

                # Try to send to Kafka
                if self.producer:
                    success = self.publish_query(user_input, query_id)
                    if success:
                        self.pending_responses[query_id] = None
                        print(f"{self.name}: Query sent! Waiting for response from Kafka...")

                        # Wait for response with timeout
                        wait_time = 0
                        max_wait = 5  # seconds
                        while wait_time < max_wait and self.pending_responses.get(query_id) is None:
                            time.sleep(0.1)
                            wait_time += 0.1

                        # If no Kafka response, provide local fallback
                        if self.pending_responses.get(query_id) is None:
                            print(f"{self.name}: (No Kafka response, using local fallback)")
                            response = self.get_local_response(user_input)
                            print(f"{self.name}: {response}\n")
                        else:
                            # Response already printed by consumer thread
                            pass

                        # Clean up
                        if query_id in self.pending_responses:
                            del self.pending_responses[query_id]
                    else:
                        response = self.get_local_response(user_input)
                        print(f"{self.name}: {response}\n")
                else:
                    # Local mode
                    response = self.get_local_response(user_input)
                    print(f"{self.name}: {response}\n")

            except KeyboardInterrupt:
                self.running = False
                if self.producer:
                    self.producer.flush()
                if self.consumer:
                    self.consumer.close()
                print(f"\n\n{self.name}: Goodbye! Thanks for chatting with me!\n")
                break
            except Exception as e:
                print(f"\n{self.name}: Oops! Something went wrong: {e}\n")


def main():
    """Run the chatbot."""
    # Kafka configuration for Confluent Cloud
    # Replace with your actual Confluent Cloud credentials
    kafka_config = {
        'bootstrap.servers': 'YOUR_BOOTSTRAP_SERVER.confluent.cloud:9092',
        'sasl.username': 'YOUR_API_KEY',
        'sasl.password': 'YOUR_API_SECRET',
        'query_topic': 'queries',
        'response_topic': 'search_results_response',
        'group.id': 'chatbot-consumer-group'
    }

    print("=" * 70)
    print("Interactive Kafka Chatbot - Confluent Cloud")
    print("=" * 70)
    print("\nConfiguration:")
    print(f"  Query Topic (Producer):    {kafka_config['query_topic']}")
    print(f"  Response Topic (Consumer): {kafka_config['response_topic']}")
    print(f"  Bootstrap Server:          {kafka_config['bootstrap.servers']}")
    print(f"  Consumer Group:            {kafka_config['group.id']}")
    print("\n⚠  Update kafka_config with your Confluent Cloud credentials")
    print("=" * 70)

    # Create chatbot with Kafka integration
    # Set kafka_config=None to run without Kafka
    bot = InteractiveKafkaChatbot(name="ChatBot", kafka_config=kafka_config)
    bot.chat()


if __name__ == "__main__":
    main()
