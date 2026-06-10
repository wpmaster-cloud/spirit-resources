---
name: qdrant
requires: python3
description: "Build RAG pipelines and semantic search with Qdrant. Use when the mission involves storing or querying vector embeddings, retrieval-augmented generation, semantic similarity search, or payload-filtered vector lookup."
---

# Qdrant

Qdrant is a vector database for similarity search. The Python client (`qdrant-client`) handles collections, upserts, and search. FastEmbed is bundled for local embedding without PyTorch.

- Docs: https://qdrant.tech/documentation/
- Python client: https://python-client.qdrant.tech/
- PyPI: https://pypi.org/project/qdrant-client/ (current: v1.18.0)

## Installation

```bash
pip install "qdrant-client[fastembed]"   # includes local embedding via ONNX
pip install qdrant-client                 # vector ops only, bring your own embeddings
```

Need a server (beyond `:memory:`/local-path mode)? Get the static binary with
the **install-runtimes** skill (`bash skills/install-runtimes/scripts/get.sh
qdrant`, REST on :6333), or run the `qdrant/qdrant` image with podman/docker.

## Client initialization

```python
from qdrant_client import QdrantClient

# In-memory — dev/testing, ephemeral
client = QdrantClient(":memory:")  # needs no server at all

# Persistent local disk
client = QdrantClient(path="/data/qdrant")

# Remote server
client = QdrantClient(host="localhost", port=6333)

# Qdrant Cloud
client = QdrantClient(
    url="https://<cluster>.cloud.qdrant.io:6333",
    api_key="<QDRANT_API_KEY>",
)
```

## Create a collection

```python
from qdrant_client.models import VectorParams, Distance

client.create_collection(
    collection_name="docs",
    vectors_config=VectorParams(
        size=384,             # must match embedding model output dim
        distance=Distance.COSINE,
    ),
)
```

**Distance options:** `COSINE` (text, normalized), `DOT` (recommendation), `EUCLID` (clustering).

**Common embedding sizes:**
| Model | Size |
|---|---|
| FastEmbed default (`BAAI/bge-small-en-v1.5`) | 384 |
| `all-MiniLM-L6-v2` | 384 |
| `all-mpnet-base-v2` | 768 |
| OpenAI `text-embedding-3-small` | 1536 |
| OpenAI `text-embedding-3-large` | 3072 |

## Two paths: auto-embed vs manual

### Path A — auto-embed with `add()` (FastEmbed required)

`add()` embeds documents internally then upserts them. Simplest for RAG.

```python
client.add(
    collection_name="docs",
    documents=[
        "Podman is a daemonless container engine.",
        "Qdrant is a vector similarity search engine.",
    ],
    metadata=[                          # optional per-document payload
        {"source": "podman-docs"},
        {"source": "qdrant-docs"},
    ],
    ids=[1, 2],                         # omit to auto-generate UUIDs
)
```

Query with text — also auto-embedded:

```python
results = client.query_points(
    collection_name="docs",
    query="how do I run containers without root?",
    limit=5,
    with_payload=True,
)
for p in results.points:
    print(p.score, p.payload)
```

### Path B — manual embed + upsert

Use when you control the embedding model (OpenAI, sentence-transformers, etc.).

```python
from qdrant_client.models import PointStruct

# Generate embeddings yourself
vectors = embedding_model.encode(texts)   # list[list[float]]

client.upsert(
    collection_name="docs",
    points=[
        PointStruct(id=i, vector=vec.tolist(), payload={"text": text, "source": src})
        for i, (vec, text, src) in enumerate(zip(vectors, texts, sources))
    ],
    wait=True,    # block until indexed; use False for fire-and-forget bulk loads
)
```

Search with a raw vector:

```python
results = client.query_points(
    collection_name="docs",
    query=query_vector,    # list[float]
    limit=5,
    with_payload=True,
)
```

## Filtered search

```python
from qdrant_client.models import Filter, FieldCondition, MatchValue, Range

results = client.query_points(
    collection_name="docs",
    query=query_vector,
    query_filter=Filter(
        must=[FieldCondition(key="source", match=MatchValue(value="qdrant-docs"))],
        must_not=[FieldCondition(key="deleted", match=MatchValue(value=True))],
    ),
    limit=5,
    with_payload=True,
)
```

`must` = AND, `should` = OR, `must_not` = NOT. For numeric fields use `Range(gte=..., lte=...)`.

Index frequently-filtered fields for performance:

```python
from qdrant_client.models import PayloadSchemaType

client.create_payload_index(
    collection_name="docs",
    field_name="source",
    field_schema=PayloadSchemaType.KEYWORD,
)
```

## Async client

```python
from qdrant_client import AsyncQdrantClient

client = AsyncQdrantClient(":memory:")
await client.create_collection(...)
await client.upsert(...)
results = await client.query_points(...)
```

## Guardrails

- `size` in `VectorParams` must exactly match your embedding model's output dimension — mismatches raise errors at upsert time.
- Use `wait=True` on `upsert()` in any flow where you immediately query; without it, points may not yet be indexed.
- `query_points()` is the current unified search endpoint; prefer it over the older `search()`.
- Without a payload index, filtered search performs a full scan — always index fields used in filters for production workloads.
- On arm64, FastEmbed uses ONNX Runtime which is natively supported; no special flags needed.
