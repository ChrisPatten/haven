# Haven PDP MVP

This repository implements the Haven Personal Data Plane (PDP) minimum viable product focused on the macOS iMessage → OpenAPI vertical slice. It ingests local iMessage history, catalogs the normalized messages, indexes semantic embeddings in Qdrant, and exposes hybrid search and summarization endpoints over an authenticated FastAPI gateway.

## Components

- **Collector (host process)** – copies `~/Library/Messages/chat.db` using the SQLite backup API, normalizes new messages, and posts them to the catalog service.
- **Catalog API (`:8081`)** – FastAPI service that stores threads/messages/chunks in Postgres, maintains FTS indexes, and tracks embedding status.
- **Embedding Worker** – polls for chunks marked `pending`, generates `BAAI/bge-m3` embeddings, and upserts them into Qdrant.
- **Gateway API (`:8080`)** – FastAPI service that performs hybrid lexical/vector search, extractive summarization, document retrieval, and context insights.
- **OpenAPI Spec** – `openapi.yaml` describes the public endpoints for Custom GPT integration.

## Prerequisites

- macOS with Python 3.11 (for the collector) and Docker Desktop.
- Access to the local iMessage database at `~/Library/Messages/chat.db`.
- A bearer token stored in `AUTH_TOKEN` for API access.

## Quick Start

```bash
# 1. Start infrastructure and APIs
export AUTH_TOKEN="changeme"
docker compose up --build

# 2. Initialize Postgres schema
psql postgresql://postgres:postgres@localhost:5432/haven -f schema/catalog_mvp.sql

# 3. Run the collector locally
python services/collector/collector_imessage.py
```

## Configuration

Environment variables (with sensible defaults):

- `AUTH_TOKEN` – bearer token required by the gateway.
- `CATALOG_TOKEN` – optional shared secret for collector → catalog ingestion.
- `DATABASE_URL` – Postgres connection string (each service overrides for Docker networking).
- `EMBEDDING_MODEL` – embedding model identifier (`BAAI/bge-m3`).
- `QDRANT_URL`, `QDRANT_COLLECTION` – vector store configuration.
- `COLLECTOR_POLL_INTERVAL`, `COLLECTOR_BATCH_SIZE` – collector tuning knobs.

## Validation

```bash
ruff check .
black --check .
mypy services shared
pytest
```

For end-to-end verification a simulated message can be posted:

```bash
python services/collector/collector_imessage.py --simulate "Hey can you pay MMED today?"

curl -s "http://localhost:8080/v1/search?q=MMED" -H "Authorization: Bearer $AUTH_TOKEN"
```

## Security

- All network services bind to `localhost` only via Docker port publishing.
- Bearer token authentication enforced on ingestion (optional) and all gateway routes.
- Collector maintains local state in `~/.haven/imessage_collector_state.json` and never uploads raw attachments.

