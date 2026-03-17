# Kafka Chatbot Web Application

A Flask-based web chatbot that integrates with Confluent Cloud Kafka for real-time query and response handling.

## Features

- 🌐 Modern web-based chat interface
- ☁️ Integration with Confluent Cloud Kafka
- 📤 Sends user queries to `queries` topic using Avro serialization
- 📥 Receives responses from `search_results_response` topic with Avro deserialization
- ⚡ Real-time message streaming
- 🎨 Beautiful, responsive UI
- 📋 Schema Registry integration for Avro schema management

## Architecture

```
User → Web Interface → Flask Backend → Kafka (queries topic)
                            ↑
                            |
                     Kafka Consumer
                            |
                            ↓
User ← Web Interface ← Flask Backend ← Kafka (search_results_response topic)
```

## Prerequisites

- Python 3.8+
- Confluent Cloud account with Kafka cluster
- Kafka topics: `queries` and `search_results_response`
- Schema Registry enabled in Confluent Cloud
- Avro schemas registered for both topics

## Installation

1. **Clone or navigate to the project directory:**
   ```bash
   cd /Users/qyang/demo/claude-code/chatbot
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
   - Create topic: `queries` (for user questions)
   - Create topic: `search_results_response` (for bot responses)

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

   **queries topic schema:**
   ```json
   {
     "type": "record",
     "name": "queries_value",
     "namespace": "org.apache.flink.avro.generated.record",
     "fields": [
       {"name": "query", "type": ["null", "string"], "default": null}
     ]
   }
   ```

   **search_results_response topic schema:**
   ```json
   {
     "type": "record",
     "name": "search_results_response_value",
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
   }
   ```

   Note: The schemas are embedded in the application code, but they should also be registered in your Schema Registry if you're using schema validation.

## Running the Application

### Development Mode

```bash
python app.py
```

The application will start on `http://localhost:5000`

### Production Mode

For production, use a WSGI server like Gunicorn:

```bash
pip install gunicorn
gunicorn -w 4 -b 0.0.0.0:5000 app:app
```

## Usage

1. Open your browser and navigate to `http://localhost:5000`
2. Type a message in the chat input
3. Click "Send" or press Enter
4. The chatbot will:
   - Serialize your query using Avro format
   - Send it to the `queries` Kafka topic
   - Wait for an Avro-encoded response from the `search_results_response` topic
   - Display the response and any search results in the chat interface

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

## Message Format

### Query Message (to `queries` topic)
Sent as **Avro-serialized** message with the following structure:
```json
{
  "query": "User's question"
}
```
- Message key: `query_id` (string, e.g., "query-uuid-1234")
- Message value: Avro-serialized with `queries_value` schema

### Response Message (from `search_results_response` topic)
Received as **Avro-serialized** message with the following structure:
```json
{
  "query": "Original user query",
  "document_id_1": "doc-123",
  "chunk_1": "Relevant text chunk 1",
  "score_1": 0.95,
  "document_id_2": "doc-456",
  "chunk_2": "Relevant text chunk 2",
  "score_2": 0.87,
  "document_id_3": "doc-789",
  "chunk_3": "Relevant text chunk 3",
  "score_3": 0.82,
  "response": "The generated response based on search results"
}
```
- Message key: `query_id` (string, matching the original query)
- Message value: Avro-serialized with `search_results_response_value` schema
- The `response` field contains the main answer
- Search results include up to 3 document chunks with relevance scores

## Project Structure

```
chatbot/
├── app.py                      # Flask application
├── templates/
│   └── index.html             # Chat interface
├── requirements.txt           # Python dependencies
├── .env.example              # Environment variables template
└── README.md                 # This file
```

## Troubleshooting

### Kafka Connection Issues

1. **Check credentials:**
   - Verify your API key and secret are correct
   - Ensure bootstrap server URL is correct

2. **Check topic names:**
   - Verify topics `queries` and `search_results_response` exist
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

Edit the `chat()` function in `app.py` to add fallback logic when Kafka is unavailable.

### Customizing the UI

Edit `templates/index.html` to customize the chat interface appearance and behavior.

### Extending Kafka Integration

Modify the Kafka producer/consumer logic in `app.py` to add features like:
- Message acknowledgments
- Error handling
- Retry logic
- Message persistence

## License

MIT License

## Support

For issues or questions, please check:
- Confluent Cloud documentation: https://docs.confluent.io/cloud/
- Flask documentation: https://flask.palletsprojects.com/
