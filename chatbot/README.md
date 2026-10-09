# Kafka Chatbot Collection

A collection of chatbot implementations demonstrating various integration patterns with Confluent Cloud Kafka, from simple command-line bots to a full-featured Flask web application with Avro serialization.

## Chatbot Implementations

This project includes four chatbot implementations, each demonstrating different integration patterns:

### 1. **Flask Web Chatbot** (`app.py`) - Recommended
- Modern web-based chat interface with beautiful, responsive UI
- Full Avro serialization/deserialization with Schema Registry
- Sends queries to `chatbot_input` topic, receives from `chatbot_output` topic
- Real-time message streaming via Kafka
- Production-ready with health checks and error handling

### 2. **Interactive CLI Chatbot** (`kafka_interactive_chatbot.py`)
- Command-line interface with bidirectional Kafka communication
- Sends queries to `queries` topic, receives from `search_results_response` topic (configurable)
- Background consumer thread for async message handling
- Local fallback responses when Kafka is unavailable
- Uses JSON serialization (not Avro)

### 3. **Simple Kafka CLI Chatbot** (`kafka_chatbot.py`)
- Basic command-line chatbot that publishes to Kafka
- One-way communication (sends to `queries` topic only)
- Simple pattern-based responses
- Uses JSON serialization

### 4. **Standalone Chatbot** (`chatbot.py`)
- Pure Python rule-based chatbot
- No Kafka dependency - for testing and development
- Pattern matching with conversation history

## Which Implementation Should I Use?

| Use Case | Implementation | File |
|----------|---------------|------|
| **Production web application** | Flask Web Chatbot | `app.py` |
| **Testing Kafka integration** | Interactive CLI Chatbot | `kafka_interactive_chatbot.py` |
| **Publishing events to Kafka** | Simple Kafka CLI | `kafka_chatbot.py` |
| **Local development/testing** | Standalone Chatbot | `chatbot.py` |

### Topic Names

**Important:** Different implementations use different topic names:
- **Flask Web App** (`app.py`): Uses `chatbot_input` and `chatbot_output`
- **CLI Chatbots** (`kafka_*.py`): Use `queries` and `search_results_response` by default (configurable)

Choose topic names that match your backend processing service or configure them accordingly.

**Quick Start:** See [QUICKSTART.md](QUICKSTART.md) for getting started with the Flask web app.

### Feature Comparison

| Feature | `app.py` | `kafka_interactive_chatbot.py` | `kafka_chatbot.py` | `chatbot.py` |
|---------|----------|-------------------------------|-------------------|--------------|
| Web Interface | ✅ | ❌ | ❌ | ❌ |
| CLI Interface | ❌ | ✅ | ✅ | ✅ |
| Kafka Producer | ✅ | ✅ | ✅ | ❌ |
| Kafka Consumer | ✅ | ✅ | ❌ | ❌ |
| Avro Serialization | ✅ | ❌ | ❌ | ❌ |
| Schema Registry | ✅ | ❌ | ❌ | ❌ |
| Real-time Responses | ✅ | ✅ | ❌ | ✅ |
| Local Fallback | ✅ | ✅ | ✅ | N/A |
| Production Ready | ✅ | ⚠️ | ❌ | ❌ |

## Architecture (Flask Web App)

```
User → Web Interface → Flask Backend → Avro Serializer → Kafka Producer → 'chatbot_input' topic
                            ↑                                                      ↓
                            |                                              [Processing Service]
                     Kafka Consumer                                               ↓
                            |                                                      ↓
User ← Web Interface ← Flask Backend ← Avro Deserializer ← Kafka Consumer ← 'chatbot_output' topic
```

## Prerequisites

### All Implementations
- Python 3.8+

### Kafka-Enabled Implementations (`app.py`, `kafka_*.py`)
- Confluent Cloud account with Kafka cluster
- Kafka topics:
  - `chatbot_input` (for Flask web app)
  - `chatbot_output` (for Flask web app)
  - `queries` and `search_results_response` (for CLI chatbots - configurable)
- API keys for Kafka cluster

### Flask Web App Only (`app.py`)
- Schema Registry enabled in Confluent Cloud
- Schema Registry API credentials
- Avro schemas registered for both topics (optional - schemas are embedded in code)

## Installation

1. **Clone or navigate to the project directory:**
   ```bash
   cd /Users/qyang/demo/confluent-flink/ai/chatbot
   ```

2. **Create a virtual environment:**
   ```bash
   python3 -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

3. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

4. **Configure environment variables:**

   Create a `.env` file (copy from `.env.example`):
   ```bash
   cp .env.example .env
   ```

   Edit `.env` with your Confluent Cloud credentials:
   ```env
   KAFKA_BOOTSTRAP_SERVERS=your-cluster.confluent.cloud:9092
   KAFKA_API_KEY=your-api-key
   KAFKA_API_SECRET=your-api-secret

   SCHEMA_REGISTRY_URL=https://your-schema-registry.confluent.cloud
   SCHEMA_REGISTRY_API_KEY=your-sr-api-key
   SCHEMA_REGISTRY_API_SECRET=your-sr-api-secret
   ```

## Configuration

### Confluent Cloud Setup

1. **Create Kafka Cluster:**
   - Log in to Confluent Cloud
   - Create a new Kafka cluster or use an existing one

2. **Create Topics:**
   - Create topic: `chatbot_input` (for user questions)
   - Create topic: `chatbot_output` (for bot responses)

3. **Get API Keys:**
   - Navigate to your cluster settings
   - Create an API key and secret
   - Add these to your `.env` file

4. **Get Bootstrap Server:**
   - Find your cluster's bootstrap server URL
   - Add it to your `.env` file

5. **Enable Schema Registry:**
   - Navigate to Schema Registry in Confluent Cloud
   - Create API credentials for Schema Registry
   - Note the Schema Registry URL
   - Add Schema Registry credentials to your `.env` file

6. **Register Avro Schemas:**
   The application uses Avro schemas for serialization:

   **chatbot_input topic (value schema):**
   ```json
   {
     "type": "record",
     "name": "chatbot_input_value",
     "namespace": "ai.confluent.chatbot",
     "fields": [
       {"name": "query", "type": "string"}
     ]
   }
   ```

   **chatbot_input topic (key schema):**
   ```json
   {
     "type": "record",
     "name": "chatbot_input_key",
     "namespace": "ai.confluent.chatbot",
     "fields": [
       {"name": "query_id", "type": "string"}
     ]
   }
   ```

   **chatbot_output topic (value schema):**
   ```json
   {
     "type": "record",
     "name": "chatbot_output_value",
     "namespace": "ai.confluent.chatbot",
     "fields": [
       {"name": "response", "type": "string"},
       {"name": "timestamp", "type": "string"}
     ]
   }
   ```

   **chatbot_output topic (key schema):**
   ```json
   {
     "type": "record",
     "name": "chatbot_output_key",
     "namespace": "ai.confluent.chatbot",
     "fields": [
       {"name": "query_id", "type": "string"}
     ]
   }
   ```

   Note: The schemas are embedded in the application code and will be automatically registered when the app runs.

## Running the Applications

### Flask Web Chatbot (Recommended)

**Development Mode:**
```bash
python app.py
```
The application will start on `http://localhost:5000`

**Production Mode:**
```bash
pip install gunicorn
gunicorn -w 4 -b 0.0.0.0:5000 app:app
```

### Interactive CLI Chatbot

For a command-line chatbot with bidirectional Kafka:
```bash
python kafka_interactive_chatbot.py
```
Note: Update Kafka credentials in the script before running.

### Simple Kafka CLI Chatbot

For one-way Kafka publishing:
```bash
python kafka_chatbot.py
```
Note: Update Kafka credentials in the script before running.

### Standalone Chatbot (No Kafka)

For local testing without Kafka:
```bash
python chatbot.py
```

## Usage

### Flask Web Chatbot (`app.py`)

1. Open your browser and navigate to `http://localhost:5000`
2. Type a message in the chat input
3. Click "Send" or press Enter
4. The chatbot will:
   - Serialize your query using Avro format
   - Send it to the `chatbot_input` Kafka topic
   - Wait for an Avro-encoded response from the `chatbot_output` topic
   - Display the response in the chat interface

### CLI Chatbots

**Interactive CLI** (`kafka_interactive_chatbot.py`):
- Type messages and press Enter
- Receives responses from Kafka in real-time
- Falls back to local responses if Kafka times out

**Simple Kafka CLI** (`kafka_chatbot.py`):
- Type messages to publish to Kafka
- Provides local pattern-based responses

**Standalone** (`chatbot.py`):
- Pure local chat with pattern matching
- No Kafka required

## API Endpoints

### `GET /`
Renders the chat interface

### `POST /api/chat`
Handles chat messages

**Request:**
```json
{
  "message": "What is the weather today?"
}
```

**Response:**
```json
{
  "response": "The weather response from Kafka...",
  "query_id": "query-uuid-here",
  "source": "kafka",
  "timestamp": "2026-03-16T10:30:00"
}
```

### `GET /api/health`
Health check endpoint

**Response:**
```json
{
  "status": "healthy",
  "kafka_producer": true,
  "kafka_consumer": true,
  "consumer_running": true
}
```

## Message Format (Flask Web App)

### Query Message (to `chatbot_input` topic)
Sent as **Avro-serialized** message with the following structure:

**Key:**
```json
{
  "query_id": "query-1234567890123"
}
```

**Value:**
```json
{
  "query": "User's question here"
}
```
- Message key: Avro-serialized with `chatbot_input_key` schema
- Message value: Avro-serialized with `chatbot_input_value` schema

### Response Message (from `chatbot_output` topic)
Received as **Avro-serialized** message with the following structure:

**Key:**
```json
{
  "query_id": "query-1234567890123"
}
```

**Value:**
```json
{
  "response": "The bot's answer to the user's question",
  "timestamp": "2026-03-16T10:30:00"
}
```
- Message key: Avro-serialized with `chatbot_output_key` schema (matching the original query_id)
- Message value: Avro-serialized with `chatbot_output_value` schema

## Project Structure

```
chatbot/
├── app.py                              # Flask web chatbot with Avro (RECOMMENDED)
├── kafka_interactive_chatbot.py        # CLI chatbot with bidirectional Kafka
├── kafka_chatbot.py                    # CLI chatbot with one-way Kafka
├── chatbot.py                          # Standalone chatbot (no Kafka)
├── templates/
│   └── index.html                     # Web chat interface (for app.py)
├── requirements.txt                    # Python dependencies
├── .env.example                       # Environment variables template
├── README.md                          # This file (full documentation)
├── QUICKSTART.md                      # Quick start guide
└── flink.md                           # Flink integration notes
```

## Troubleshooting

### Kafka Connection Issues

1. **Check credentials:**
   - Verify your API key and secret are correct
   - Ensure bootstrap server URL is correct

2. **Check topic names:**
   - For Flask app: Verify topics `chatbot_input` and `chatbot_output` exist
   - For CLI chatbots: Check configured topic names (default: `queries` and `search_results_response`)
   - Check topic permissions

3. **Network issues:**
   - Ensure your firewall allows connections to port 9092
   - Check if your network allows SASL_SSL connections

### No Response from Kafka

1. **Check consumer group:**
   - Verify the consumer is subscribed to the correct topic
   - Check consumer group offset status in Confluent Cloud

2. **Check message format:**
   - Ensure the response messages include `query_id` in the message key
   - Verify Avro serialization is working correctly
   - Check that message schemas match the registered schemas in Schema Registry

3. **Timeout issues:**
   - Default timeout is 10 seconds
   - Adjust timeout in `app.py` if needed

### Schema Registry Issues

1. **Connection errors:**
   - Verify Schema Registry URL is correct
   - Check Schema Registry API credentials
   - Ensure Schema Registry is enabled in your Confluent Cloud cluster

2. **Serialization errors:**
   - Verify Avro schemas are correctly defined
   - Check that schema compatibility settings allow your schema versions
   - Ensure all required fields in the schema are being populated

3. **Schema version conflicts:**
   - Check Schema Registry for registered schema versions
   - Verify schema compatibility mode (BACKWARD, FORWARD, FULL, NONE)
   - Update schema definitions if needed

## Development

### Adding Local Fallback Responses

**Flask Web App:** Edit the `chat()` function in `app.py` to add fallback logic when Kafka is unavailable.

**CLI Chatbots:** Pattern-based responses are in the `patterns` dictionary in each chatbot class.

### Customizing the UI

Edit `templates/index.html` to customize the chat interface appearance and behavior (Flask app only).

### Extending Kafka Integration

Modify the Kafka producer/consumer logic in your chosen implementation to add features like:
- Message acknowledgments
- Error handling
- Retry logic
- Message persistence
- Custom serialization formats

### Creating Your Own Implementation

1. Start with `chatbot.py` for the basic structure
2. Add Kafka producer logic from `kafka_chatbot.py`
3. Add consumer logic from `kafka_interactive_chatbot.py`
4. Or use Avro serialization from `app.py`

## License

MIT License

## Support

For issues or questions, please check:
- Confluent Cloud documentation: https://docs.confluent.io/cloud/
- Flask documentation: https://flask.palletsprojects.com/
