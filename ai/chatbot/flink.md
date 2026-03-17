- create flink table chatbot_input
```
create table if not exists chatbot_input (
	query_id STRING PRIMARY KEY NOT ENFORCED,
        query STRING NOT NULL)
WITH (
'changelog.mode' = 'append',
key.format='avro-registry'
);





- Query MongoDB 
```
create table  chatbot_search_results as 
with queries_embed as (
SELECT query_id, query, embedding
FROM chatbot_input,
        LATERAL TABLE(ML_PREDICT('llm_embedding_model', query))
)
SELECT qe.query_id, qe.query,
        vs.search_results[1].document_id AS document_id_1,
        vs.search_results[1].chunk AS chunk_1,
        vs.search_results[1].score AS score_1,
        vs.search_results[2].document_id AS document_id_2,
        vs.search_results[2].chunk AS chunk_2,
        vs.search_results[2].score AS score_2,
        vs.search_results[3].document_id AS document_id_3,
        vs.search_results[3].chunk AS chunk_3, vs.search_results[3].score AS score_3
FROM queries_embed AS qe,
        LATERAL TABLE(VECTOR_SEARCH_AGG( documents_vectordb_lab2,
        DESCRIPTOR(embedding),
        qe.embedding, 3 )) AS vs;

```

-- Generate response using LLM
```
CREATE TABLE IF NOT EXISTS chatbot_output (
    query_id STRING PRIMARY KEY NOT ENFORCED,
    query STRING,
    document_id_1 STRING,
    chunk_1 STRING,
    score_1 DOUBLE,
    document_id_2 STRING,
    chunk_2 STRING,
    score_2 DOUBLE,
    document_id_3 STRING,
    chunk_3 STRING,
    score_3 DOUBLE,
    response STRING
)
WITH (
   'changelog.mode' = 'append',
    'key.format'='avro-registry'
);

INSERT INTO chatbot_output
SELECT
    sr.query_id,
    sr.query,
    sr.document_id_1,
    sr.chunk_1,
    sr.score_1,
    sr.document_id_2,
    sr.chunk_2,
    sr.score_2,
    sr.document_id_3,
    sr.chunk_3,
    sr.score_3,
    pred.response
FROM chatbot_search_results sr,
LATERAL TABLE (
    ml_predict(
        'llm_textgen_model',
        CONCAT(
            'Based on the following search results, provide a helpful and comprehensive response to the user query based upon the relevant retrieved documents. Cite the exact parts of the retrieved documents whenever possible.\n\n',
            'USER QUERY: ',
            sr.query,
            '\n\n',
            'SEARCH RESULTS:\n\n',
            'Document 1 (Similarity Score: ',
            CAST(sr.score_1 AS STRING),
            '):\n',
            'Source: ',
            sr.document_id_1,
            '\n',
            'Content: ',
            sr.chunk_1,
            '\n\n',
            'Document 2 (Similarity Score: ',
            CAST(sr.score_2 AS STRING),
            '):\n',
            'Source: ',
            sr.document_id_2,
            '\n',
            'Content: ',
            sr.chunk_2,
            '\n\n',
            'Document 3 (Similarity Score: ',
            CAST(sr.score_3 AS STRING),
            '):\n',
            'Source: ',
            sr.document_id_3,
            '\n',
            'Content: ',
            sr.chunk_3,
            '\n\n',
            'INSTRUCTIONS:\n',
            '- Synthesize information from the most relevant documents above\n',
            '- Provide specific, actionable guidance when possible\n',
            '- Reference document sources in your response\n',
            '- If the search results don''t contain relevant information, say so clearly\n\n',
            'RESPONSE:'
        )
    )
) AS pred;
```

