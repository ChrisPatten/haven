# Haven Architecture Map

## Compose Services & Entry Points
- **postgres** – `postgres:15`, initialized via `schema/init.sql` (unified schema v2); volume `pg_data`.
- **qdrant** – `qdrant/qdrant:latest`; volume `qdrant_data` for vectors.
- **minio** – MinIO object storage for file attachments; optional, can use alternatives.
- **search** – builds with `SERVICE=search`; command `search-service --host 0.0.0.0 --port 8080`; depends on `postgres`, `qdrant`.
- **gateway** – builds with `SERVICE=gateway`; command `uvicorn services.gateway_api.app:app --host 0.0.0.0 --port 8080`; publishes `127.0.0.1:8085`.
- **catalog** – builds with `SERVICE=catalog`; command `uvicorn services.catalog_api.app:app --host 0.0.0.0 --port 8081`.
- **embedding_service** – runs `python services/embedding_service/worker.py`; polls `chunks` table for `embedding_status='pending'` and posts results to catalog.
- **collector** – optional profile `collector`; runs `python scripts/collectors/collector_imessage.py` posting to the gateway ingest endpoint.

## Python Packages per Service
- **gateway** (`services/gateway_api`) – FastAPI app, token guards, catalog proxies, search summarization, contacts endpoints, file upload handling.
- **search** (`src/haven/search`) – FastAPI app with Typer CLI, ingestion pipelines, hybrid ranking over Postgres + Qdrant with unified schema support.
- **catalog** (`services/catalog_api`) – FastAPI app persisting unified documents, threads, files, chunks with versioning and idempotency tracking.
- **collector** (`scripts/collectors`) – CLIs for iMessage (chat.db), localfs, and contacts; normalization, optional image enrichment, HTTP ingestion.
- **embedding_service** (`services/embedding_service`) – Worker polling chunks table, encoding via configured model (Ollama), posting to catalog `/v1/catalog/embeddings`.
- **shared** (`shared/`) – Logging, dependency guards, Postgres helpers, unified schema models (`models_v2.py`), context queries, image enrichment.

## Cross-Service Calls & Data Flows
- `collector` → `gateway` (`/v1/ingest`, `/v1/ingest/file`) – normalized documents with threads, people, enrichment metadata.
- `gateway` → `catalog` – proxies `/v1/catalog/documents`, `/v1/catalog/submissions/{id}`, `/v1/catalog/documents/{id}/version`, `/v1/context/general`, and contacts endpoints to `${CATALOG_BASE_URL}` (default `http://catalog:8081`).
- `gateway` → `search` – queries via `SearchServiceClient` for hybrid search.
- `gateway` → MinIO – uploads file attachments to object storage.
- `catalog` → Postgres – synchronous writes to unified schema tables: `documents`, `threads`, `files`, `document_files`, `chunks`, `chunk_documents`, `ingest_submissions`.
- `catalog` → no queue – chunks created with `embedding_status='pending'` directly in `chunks` table (no separate `embed_jobs`).
- `search` ↔ Postgres – async queries on `documents`, `chunks`, `chunk_documents` with full-text and timeline filters.
- `search` ↔ Qdrant – vector similarity search on embedded chunks.
- `embedding_service` ↔ Postgres – polls `chunks` where `embedding_status='pending'`, posts results to catalog `/v1/catalog/embeddings`.
- `embedding_service` → Ollama (or embedding provider) – generates vector embeddings for chunk text.
- Contacts collector → gateway/catalog – posts contact documents as unified records; gateway transforms to `contact` source type with structured metadata.

## Data & Integration Assets
- **Database schema** – `schema/init.sql` (unified schema v2 with versioning, threads, files, chunks, and idempotency tracking).
- **Volumes** – `pg_data` for Postgres (`haven_v2` database), `qdrant_data` for vector storage, `minio_data` for file attachments.
- **Attachment enrichment helper** – `scripts/collectors/imdesc.swift` compiled via `scripts/build-imdesc.sh`; optional Ollama vision integration.
- **Shared models** – `shared/models_v2.py` defines Document, Thread, File, Chunk data models used across services.
- **OpenAPI** – `openapi/gateway.yaml` describes public gateway endpoints for external integrations (may need updates for v2).
- **Tests** – `tests/` includes coverage for gateway, catalog, search, and collectors with unified schema validation.

## Network & Auth Contracts
- Auth tokens supplied via env: `AUTH_TOKEN` for gateway endpoints, `CATALOG_TOKEN` shared across ingestion path, `SEARCH_TOKEN` optional for gateway→search.
- External dependencies reachable at `postgresql://postgres:postgres@postgres:5432/haven_v2` and `http://qdrant:6333` inside compose.
- MinIO accessible at `minio:9000` for file storage operations.

## Observed Entry Modules
```
services/gateway_api/app.py
services/catalog_api/app.py
src/haven/search/main.py
scripts/collectors/collector_imessage.py
services/embedding_service/worker.py
```
