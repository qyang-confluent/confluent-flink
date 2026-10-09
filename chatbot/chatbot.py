#!/usr/bin/env python3
"""
Simple Python Chatbot
A rule-based chatbot with pattern matching and responses.
"""

import re
import random
from datetime import datetime


class Chatbot:
    def __init__(self, name="Bot"):
        self.name = name
        self.conversation_history = []

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
        print(f"\n{self.name}: Hello! I'm {self.name}, your chatbot. Type 'quit' or 'exit' to end the conversation.\n")

        while True:
            try:
                user_input = input("You: ").strip()

                if not user_input:
                    continue

                if user_input.lower() in ['quit', 'exit']:
                    print(f"\n{self.name}: Goodbye! Thanks for chatting with me!\n")
                    break

                response = self.get_response(user_input)
                print(f"{self.name}: {response}\n")

            except KeyboardInterrupt:
                print(f"\n\n{self.name}: Goodbye! Thanks for chatting with me!\n")
                break
            except Exception as e:
                print(f"\n{self.name}: Oops! Something went wrong: {e}\n")


def main():
    """Run the chatbot."""
    bot = Chatbot(name="ChatBot")
    bot.chat()


if __name__ == "__main__":
    main()
