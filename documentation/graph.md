# Haven Architecture Map

## Compose Services & Entry Points
- **postgres** – `postgres:15`, initialized via `schema/init.sql`; volume `pg_data`.
- **qdrant** – `qdrant/qdrant:latest`; volume `qdrant_data` for vectors.
- **search** – builds with `SERVICE=search`; command `search-service --host 0.0.0.0 --port 8080`; depends on `postgres`, `qdrant`.
- **gateway** – builds with `SERVICE=gateway`; command `uvicorn services.gateway_api.app:app --host 0.0.0.0 --port 8080`; publishes `127.0.0.1:8085`.
- **catalog** – builds with `SERVICE=catalog`; command `uvicorn services.catalog_api.app:app --host 0.0.0.0 --port 8081`.
- **embedding_service** – runs `python services/embedding_service/worker.py`; polls for pending chunks and writes to Qdrant.
- **collector** – optional profile `collector`; runs `python scripts/collectors/collector_imessage.py` posting to the gateway ingest endpoint.

## Python Packages per Service
- **gateway** (`services/gateway_api`) – FastAPI app, token guards, catalog proxies, search summarization, contacts endpoints.
- **search** (`src/haven/search`) – FastAPI app with Typer CLI, ingestion pipelines, hybrid ranking over Postgres + Qdrant.
- **catalog** (`services/catalog_api`) – FastAPI app persisting threads/messages/chunks, aggregate context, contacts APIs.
- **collector** (`scripts/collectors`) – CLI for chat database backup, normalization, optional image enrichment, and HTTP ingestion.
- **embedding_service** (`services/embedding_service`) – Worker polling catalog queues, encoding via the configured embedding model, and upserting to Qdrant.
- **shared** (`shared/`) – Logging bootstrap, dependency guards, Postgres helpers, context queries reused by services.

## Cross-Service Calls & Data Flows
- `collector` → `gateway` (`/v1/ingest`) – normalized messages and enrichment metadata.
- `gateway` → `catalog` – proxies `/v1/catalog/documents`, `/v1/catalog/submissions/{id}`, `/v1/context/general`, `/v1/doc/{doc_id}`, and contacts endpoints to `${CATALOG_BASE_URL}` (default `http://catalog:8081`).
- `gateway` → `search` – queries `/v1/search/query` (and similar) via `SearchServiceClient`.
- `catalog` → Postgres – synchronous writes to `threads`, `messages`, `documents`, `chunks`, `embed_jobs`, `contacts`.
- `catalog` → embedding queue – enqueues chunk jobs in `embed_jobs` for the worker.
- `search` ↔ Postgres – async lexical search queries and ingestion metadata.
- `search` ↔ Qdrant – vector inserts and similarity search for the configured collection (`haven_chunks`).
- `embedding_service` ↔ Postgres/Qdrant – reads pending chunks, writes embeddings, marks status `ready`.
- Contacts collector (optional) → gateway/catalog – posts normalized people records; exports via streaming NDJSON.

## Data & Integration Assets
- **Database schema** – `schema/init.sql` (idempotent schema covering catalog, contacts, search, and embedding queues).
- **Volumes** – `pg_data` for Postgres, `qdrant_data` for vector storage.
- **Attachment enrichment helper** – `scripts/collectors/imdesc.swift` compiled via `scripts/build-imdesc.sh`; optional Ollama vision integration documented in README.
- **OpenAPI** – `openapi.yaml` describes public gateway endpoints for external integrations.
- **Tests** – `tests/` includes coverage for gateway summary/catalog proxy, search models, and collector enrichment logic.

## Network & Auth Contracts
- Auth tokens supplied via env: `AUTH_TOKEN` for gateway endpoints, `CATALOG_TOKEN` shared across ingestion path, `SEARCH_TOKEN` optional for gateway→search.
- External dependencies reachable at `postgresql://postgres:postgres@postgres:5432/haven` and `http://qdrant:6333` inside compose.

## Observed Entry Modules
```
services/gateway_api/app.py
services/catalog_api/app.py
src/haven/search/main.py
scripts/collectors/collector_imessage.py
services/embedding_service/worker.py
```
