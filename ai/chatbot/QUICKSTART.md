# Quick Start Guide

This guide will help you get the Kafka Chatbot web application up and running quickly.

## What You've Built

A modern web-based chatbot that:
- **Sends** user queries to Confluent Cloud Kafka `queries` topic using **Avro serialization**
- **Receives** search results from `search_results_response` topic using **Avro deserialization**
- Uses Schema Registry for schema management
- Provides a beautiful, responsive chat interface

## Architecture Flow

```
User Input → Web UI → Flask Backend → Avro Serializer → Kafka Producer → 'queries' topic
                                                                              ↓
                                                                    [Your Search Service]
                                                                              ↓
User sees response ← Web UI ← Flask Backend ← Avro Deserializer ← Kafka Consumer ← 'search_results_response' topic
```

## Quick Setup (5 Steps)

### 1. Install Dependencies

```bash
cd /Users/qyang/demo/claude-code/chatbot
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. Configure Confluent Cloud

Create a `.env` file:

```bash
cp .env.example .env
```

Edit `.env` with your credentials:

```env
# Kafka
KAFKA_BOOTSTRAP_SERVERS=pkc-xxxxx.us-east-1.aws.confluent.cloud:9092
KAFKA_API_KEY=YOUR_CLUSTER_API_KEY
KAFKA_API_SECRET=YOUR_CLUSTER_API_SECRET

# Schema Registry
SCHEMA_REGISTRY_URL=https://psrc-xxxxx.us-east-1.aws.confluent.cloud
SCHEMA_REGISTRY_API_KEY=YOUR_SR_API_KEY
SCHEMA_REGISTRY_API_SECRET=YOUR_SR_API_SECRET
```

### 3. Create Topics in Confluent Cloud

Create two topics:
- `queries` - for sending user questions
- `search_results_response` - for receiving answers

### 4. Register Schemas (Optional)

The schemas are embedded in the code, but you may want to register them in Schema Registry:

**For `queries` topic (value schema):**
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

**For `search_results_response` topic (value schema):**
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

### 5. Run the Application

```bash
python app.py
```

Open your browser to: **http://localhost:5000**

## Message Flow Details

### When you send a message:

1. **User types**: "What is machine learning?"
2. **Flask backend** creates Avro message:
   ```json
   {"query": "What is machine learning?"}
   ```
3. **Avro Serializer** converts to binary format
4. **Producer** sends to `queries` topic with key `query-<uuid>`

### When you receive a response:

1. **Consumer** receives Avro message from `search_results_response`
2. **Avro Deserializer** converts to Python dict
3. **Flask backend** extracts:
   - `response` field → main answer
   - `chunk_1`, `chunk_2`, `chunk_3` → search results
   - `score_1`, `score_2`, `score_3` → relevance scores
4. **Web UI** displays the response

## Testing

### Test Producer (sends query)

Send a test message through the web UI, and check Confluent Cloud:
- Go to Topics → `queries`
- Verify message appears with Avro encoding

### Test Consumer (receives response)

To test the consumer, you need a service that:
1. Consumes from `queries` topic
2. Produces to `search_results_response` topic
3. Uses the same `query_id` as the message key

**Example test message you can manually produce to `search_results_response`:**
```json
{
  "query": "test query",
  "document_id_1": "doc1",
  "chunk_1": "This is a test chunk",
  "score_1": 0.95,
  "response": "This is a test response"
}
```
Key: `query-<uuid>` (matching a query you sent)

## Files Overview

```
chatbot/
├── app.py                 # Main Flask application with Avro serialization
├── templates/
│   └── index.html        # Chat UI (HTML/CSS/JavaScript)
├── requirements.txt      # Python dependencies
├── .env.example         # Template for environment variables
├── README.md           # Full documentation
└── QUICKSTART.md      # This file
```

## Troubleshooting

### "Failed to initialize Kafka Producer"
- Check your `.env` file has correct credentials
- Verify KAFKA_BOOTSTRAP_SERVERS is correct
- Test connectivity to Confluent Cloud

### "Failed to initialize Schema Registry"
- Check SCHEMA_REGISTRY_URL is correct
- Verify Schema Registry API credentials
- Ensure Schema Registry is enabled in your cluster

### "No response from Kafka"
- Verify a service is consuming from `queries` and producing to `search_results_response`
- Check that response message key matches the query_id
- Look at Confluent Cloud consumer lag

### Avro serialization errors
- Check schema definitions match between producer and Schema Registry
- Verify all fields are being populated correctly
- Check schema compatibility settings

## Next Steps

1. **Connect your search service** that consumes from `queries` and produces to `search_results_response`
2. **Customize the UI** in `templates/index.html`
3. **Add authentication** for production use
4. **Deploy** using Gunicorn or similar WSGI server
5. **Monitor** using Confluent Cloud metrics

## Support

- Full documentation: See `README.md`
- Confluent Cloud docs: https://docs.confluent.io/cloud/
- Flask docs: https://flask.palletsprojects.com/

Happy chatting! 🎉
