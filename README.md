# Haven PDP MVP

This repository implements the Haven Personal Data Plane (PDP) minimum viable product focused on the macOS iMessage → OpenAPI vertical slice. It ingests local iMessage history, catalogs the normalized messages, indexes semantic embeddings in Qdrant, and exposes hybrid search and summarization endpoints over an authenticated FastAPI gateway.

See the detailed documentation under `artifacts/documentation/`:
- [`technical_reference.md`](artifacts/documentation/technical_reference.md) — architecture, service internals, data stores, deployment topology, and configuration.
- [`functional_guide.md`](artifacts/documentation/functional_guide.md) — user workflows, API behavior, authentication model, runbooks, and troubleshooting tips.

## Components

- **Collector (host process/optional compose profile)** – copies `~/Library/Messages/chat.db` using the SQLite backup API, normalizes new messages, and posts them to the gateway for ingestion.
- **Catalog API (internal)** – FastAPI service that stores threads/messages/chunks in Postgres, maintains FTS indexes, and tracks embedding status. It is reachable only on the Docker network.
- **Embedding Worker** – polls for chunks marked `pending`, generates `BAAI/bge-m3` embeddings, and upserts them into Qdrant.
- **Gateway API (`:8085`)** – FastAPI service that performs hybrid lexical/vector search, extractive summarization, document retrieval, context insights, and proxies ingestion/context calls to the catalog.
- **Search Service** – Hybrid lexical/vector search backend with ingestion routes and Typer CLI entrypoint.
- **OpenAPI Spec** – `openapi.yaml` describes the public endpoints for Custom GPT integration.

## Repository Layout

- `services/` – Deployable FastAPI apps and workers (gateway, catalog, embedding worker) plus the iMessage collector CLI.
- `src/haven/` – Installable Python package with search pipelines, SDK, and shared domain logic consumed by services.
- `shared/` – Cross-service helpers (logging, Postgres utilities, dependency guards).
- `schema/` – SQL migrations / initialization scripts.
- `artifacts/` – Generated architecture maps, findings, and documentation.

## Prerequisites

- macOS with Python 3.11 (for the collector) and Docker Desktop.
- Access to the local iMessage database at `~/Library/Messages/chat.db`.
- A bearer token stored in `AUTH_TOKEN` for API access.

## Quick Start

```bash
# 1. Start infrastructure and APIs
export AUTH_TOKEN="changeme"
docker compose up --build
# (optional) run the collector container
# COMPOSE_PROFILES=collector docker compose up --build collector

# 2. Initialize Postgres schema
psql postgresql://postgres:postgres@localhost:5432/haven -f schema/catalog_mvp.sql

# 3. Run the collector locally
python services/collector/collector_imessage.py
```

## Configuration

Environment variables (with sensible defaults):

- `AUTH_TOKEN` – bearer token required by the gateway.
- `CATALOG_TOKEN` – optional shared secret for collector → gateway → catalog ingestion.
- `CATALOG_BASE_URL` – internal URL the gateway uses to reach the catalog service (defaults to `http://catalog:8081`).
- `DATABASE_URL` – Postgres connection string (each service overrides for Docker networking).
- `EMBEDDING_MODEL` – embedding model identifier (`BAAI/bge-m3`).
- `QDRANT_URL`, `QDRANT_COLLECTION` – vector store configuration.
- `COLLECTOR_POLL_INTERVAL`, `COLLECTOR_BATCH_SIZE` – collector tuning knobs.

Developer notes:
- The Gateway now proxies document lookups (`GET /v1/doc/{doc_id}`) to the Catalog service and surfaces the same 404/200 responses. The gateway no longer performs a direct Postgres read for that endpoint; it forwards requests to the catalog at `CATALOG_BASE_URL` (default `http://catalog:8081`).
- A workspace VS Code settings file (`.vscode/settings.json`) is staged to add `./src` to Python analysis paths to improve local editing and linting.

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

curl -s "http://localhost:8085/v1/search?q=MMED" -H "Authorization: Bearer $AUTH_TOKEN"
```

## Security

- Only the gateway service publishes a host port; other services remain on the internal Docker network.
- Bearer token authentication enforced on ingestion (optional) and all gateway routes.
- Collector maintains local state in `~/.haven/imessage_collector_state.json` and never uploads raw attachments.
