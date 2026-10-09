#!/usr/bin/env python3
"""
Kafka-enabled Chatbot
A chatbot that publishes user questions to a Kafka topic in Confluent Cloud.
"""

import re
import random
import json
from datetime import datetime
from confluent_kafka import Producer
import socket


class KafkaChatbot:
    def __init__(self, name="Bot", kafka_config=None):
        self.name = name
        self.conversation_history = []

        # Kafka configuration
        self.kafka_config = kafka_config or {}
        self.producer = None
        self.topic = kafka_config.get('topic', 'queries') if kafka_config else 'queries'

        if kafka_config:
            self._setup_kafka()

        # Define patterns and responses
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
            r'\b(help|what can you do)\b': [
                "I can chat with you, answer simple questions, and have a friendly conversation!",
                "I'm here to chat! Ask me anything or just say hello.",
                "I can help with conversation, answer questions about myself, and more!"
            ],
            r'\b(time|what time)\b': [
                f"The current time is {datetime.now().strftime('%I:%M %p')}",
            ],
            r'\b(date|what date|today)\b': [
                f"Today is {datetime.now().strftime('%B %d, %Y')}",
            ],
            r'\b(joke|funny|make me laugh)\b': [
                "Why don't scientists trust atoms? Because they make up everything!",
                "What do you call a bear with no teeth? A gummy bear!",
                "Why did the scarecrow win an award? He was outstanding in his field!"
            ],
        }

        self.default_responses = [
            "That's interesting! Tell me more.",
            "I see. Can you elaborate on that?",
            "Hmm, I'm not sure I understand completely. Could you rephrase?",
            "That's a good point!",
            "I'm still learning, but I find that fascinating!"
        ]

    def _setup_kafka(self):
        """Initialize Kafka producer."""
        try:
            producer_config = {
                'bootstrap.servers': self.kafka_config.get('bootstrap.servers'),
                'security.protocol': 'SASL_SSL',
                'sasl.mechanisms': 'PLAIN',
                'sasl.username': self.kafka_config.get('sasl.username'),
                'sasl.password': self.kafka_config.get('sasl.password'),
                'client.id': socket.gethostname()
            }
            self.producer = Producer(producer_config)
            print(f"✓ Connected to Kafka cluster")
        except Exception as e:
            print(f"⚠ Warning: Could not connect to Kafka: {e}")
            print("  Continuing without Kafka integration...")

    def _delivery_callback(self, err, msg):
        """Callback for Kafka message delivery."""
        if err:
            print(f"⚠ Message delivery failed: {err}")
        else:
            print(f"✓ Message delivered to {msg.topic()} [{msg.partition()}]")

    def publish_to_kafka(self, user_input, response):
        """Publish user question and response to Kafka topic."""
        if not self.producer:
            return

        try:
            message = {
                'timestamp': datetime.now().isoformat(),
                'user_input': user_input,
                'bot_response': response,
                'bot_name': self.name
            }

            self.producer.produce(
                topic=self.topic,
                key=str(datetime.now().timestamp()),
                value=json.dumps(message),
                callback=self._delivery_callback
            )

            # Trigger delivery reports
            self.producer.poll(0)

        except Exception as e:
            print(f"⚠ Failed to publish to Kafka: {e}")

    def get_response(self, user_input):
        """Generate a response based on user input."""
        user_input_lower = user_input.lower()

        # Store conversation
        self.conversation_history.append({
            'user': user_input,
            'timestamp': datetime.now()
        })

        # Check patterns
        for pattern, responses in self.patterns.items():
            if re.search(pattern, user_input_lower):
                response = random.choice(responses)
                self.conversation_history[-1]['bot'] = response
                return response

        # Default response if no pattern matches
        response = random.choice(self.default_responses)
        self.conversation_history[-1]['bot'] = response
        return response

    def chat(self):
        """Main chat loop."""
        print(f"\n{self.name}: Hello! I'm {self.name}, your chatbot. Type 'quit' or 'exit' to end the conversation.")
        if self.producer:
            print(f"{self.name}: All conversations will be published to Kafka topic '{self.topic}'\n")
        else:
            print(f"{self.name}: Running in local mode (no Kafka connection)\n")

        while True:
            try:
                user_input = input("You: ").strip()

                if not user_input:
                    continue

                if user_input.lower() in ['quit', 'exit']:
                    if self.producer:
                        self.producer.flush()  # Ensure all messages are sent
                    print(f"\n{self.name}: Goodbye! Thanks for chatting with me!\n")
                    break

                response = self.get_response(user_input)
                print(f"{self.name}: {response}\n")

                # Publish to Kafka
                self.publish_to_kafka(user_input, response)

            except KeyboardInterrupt:
                if self.producer:
                    self.producer.flush()
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
        'topic': 'queries'
    }

    print("=" * 60)
    print("Kafka Chatbot - Confluent Cloud Integration")
    print("=" * 60)
    print("\nConfiguration:")
    print(f"  Topic: {kafka_config['topic']}")
    print(f"  Bootstrap Server: {kafka_config['bootstrap.servers']}")
    print("\nNote: Update kafka_config with your Confluent Cloud credentials")
    print("=" * 60)

    # Create chatbot with Kafka integration
    # Comment out kafka_config parameter to run without Kafka
    bot = KafkaChatbot(name="ChatBot", kafka_config=kafka_config)
    bot.chat()


if __name__ == "__main__":
    main()
