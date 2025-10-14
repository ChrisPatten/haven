# Haven Platform Technical Reference

## 1. System Overview
Haven is a multi-service platform that ingests personal communication data, normalizes it into Postgres, embeds message chunks into Qdrant, and exposes hybrid search plus summarization through a FastAPI gateway.

Core runtime components:
- **Gateway API** (`services/gateway_api/app.py`) – public HTTP surface for search, ask/summary, catalog proxying, document retrieval, and contact sync.
- **Search Service** (`src/haven/search`) – hybrid lexical/vector engine providing ingestion, query, and admin endpoints.
- **Catalog API** (`services/catalog_api/app.py`) – receives ingestion events, stores normalized threads/messages/chunks, and aggregates context views.
- **Collector** (`scripts/collectors/collector_imessage.py`) – macOS CLI that extracts iMessage data, enriches attachments, and POSTs normalized text to the gateway ingest endpoint.
- **Embedding Service** (`services/embedding_service/worker.py`) – polls pending chunks, generates embeddings, and writes vectors to Qdrant.
- **Shared Library** (`shared/`) – logging bootstrap, dependency checks, Postgres session helpers, and reusable reporting queries.

## 2. Deployment Topology
### 2.1 Container Orchestration
`compose.yaml` defines the stack and optional profiles:
- `postgres` – `postgres:15`, volume `pg_data`, initialized via `schema/init.sql`.
- `qdrant` – `qdrant/qdrant:latest`, volume `qdrant_data`.
- `search` – builds repo root with `SERVICE=search`; exposes port `8080` inside the network.
- `gateway` – builds with `SERVICE=gateway`; publishes `127.0.0.1:8085 -> 8080`.
- `catalog` – builds with `SERVICE=catalog`; listens on `8081` internally.
- `embedding_service` – long-running embedding worker that polls catalog and writes vectors to Qdrant.
- `collector` – optional profile running the iMessage collector against the gateway ingest endpoint.

### 2.2 Dockerfile Build Pipeline
1. **builder** stage installs service-specific optional dependencies declared in `pyproject.toml`.
2. **runtime** stage copies wheels and the source tree.
3. Entrypoint dispatches on `$SERVICE` (gateway, catalog, search, embedding_service, collector).
4. Wheels are prebuilt per-service (`pip wheel .[<service>,common]`) to keep runtime images slim.

### 2.3 Networks & Ports
All services share the default compose network (`haven_default`). Only the gateway publishes a host port (8085). Other services communicate over the internal network using service names (`http://catalog:8081`, `http://search:8080`, `http://qdrant:6333`).

## 3. Service Internals
### 3.1 Gateway API
- **Framework**: FastAPI with dependency-injected settings (`GatewaySettings`).
- **Key Modules**: token enforcement middleware, `SearchServiceClient`, catalog proxy utilities, summarization helpers (`gateway_api/search/ask.py`).
- **Routes**:
  - `GET /v1/search` – forwards to search service and adapts the response into gateway models.
  - `POST /v1/ask` – performs a follow-up search and synthesizes a text answer with citations.
  - `POST /v1/ingest` – normalizes document payloads and forwards them to catalog.
  - `GET /v1/ingest/{submission_id}` – returns ingest + embedding status for a submission.
  - `GET /v1/doc/{doc_id}` – proxies to catalog and relays status codes verbatim.
  - `GET /v1/context/general` – proxies to catalog context endpoint while forwarding `CATALOG_TOKEN`.
  - `GET /catalog/contacts/export` & `POST /catalog/contacts/ingest` – contact sync proxy endpoints.
  - `GET /v1/healthz` – readiness probe.
- **Environment**:
  - `AUTH_TOKEN` (optional development guard), `CATALOG_BASE_URL` (`http://catalog:8081` default), `SEARCH_URL`, `CATALOG_TOKEN`, `SEARCH_TOKEN`.
  - Database parameters used only for health/diagnostics when direct queries are needed.
- **Error Handling**: Raises FastAPI HTTP exceptions on proxy failures; logs enriched request metadata via `shared.logging`.

### 3.2 Search Service
- **Entrypoint**: `haven.search.main:cli` (Typer). `serve` command boots uvicorn with lifespan events.
- **Configuration**: `src/haven/search/config.py` uses `pydantic-settings` to gather Postgres DSN, Qdrant address, embedding metadata, and batching parameters.
- **Persistence Layer**: `src/haven/search/db.py` manages async `psycopg` connections. Repositories under `repository/` encapsulate document/chunk CRUD.
- **Pipelines**: `pipeline/ingestion.py` normalizes documents into chunks via `normalize_document` and `default_chunker`, writes records to Postgres, and marks chunks pending embedding.
- **Search Flow**:
  1. Query requests map to `SearchRequest` models (query text, filters, vector payloads).
  2. Lexical search uses Postgres full-text search functions.
  3. Vector search uses `QdrantClient.search` with configured collection and payload filters.
  4. Results merge lexical and vector scores before returning ranked hits.
- **Admin Operations**: `routes/admin.py` exposes health checks and maintenance utilities (e.g., clearing indexes, warm-up calls).

### 3.3 Catalog API
- **Entrypoint**: `services/catalog_api/app.py` (FastAPI).
- **Database Access**: Uses synchronous `psycopg` connections via helpers in `shared.database`.
- **Ingestion**: `POST /v1/catalog/documents` accepts normalized payloads, upserts threads/messages/chunks, and enqueues jobs in `embed_jobs`.
- **Submission Status**: `GET /v1/catalog/submissions/{submission_id}` surfaces document + embedding progress to the gateway.
- **Context Endpoints**: `GET /v1/context/general` runs aggregate queries from `shared.context` to produce thread counts, highlights, and top conversations.
- **Document Retrieval**: `GET /v1/doc/{doc_id}` returns normalized message metadata and chunk text.
- **Contacts**: Exposes contact ingest/export surfaces reused by gateway proxies.

### 3.4 Collector
- **CLI**: `collector_imessage.py` orchestrates chat database backup, delta scanning, message normalization, and HTTP posting to the gateway or catalog.
- **Attachment Enrichment**:
  - Invokes the optional Swift helper (`imdesc`) for OCR and entity extraction via macOS Vision.
  - Can call an Ollama vision endpoint for captions when configured.
  - Writes enrichment payloads into chunk text and message attributes; caches results under `~/.haven` to avoid repeat processing.
- **State Tracking**: Stores last processed row IDs in `~/.haven/imessage_collector_state.json` and can simulate messages via `--simulate` flag.

### 3.5 Embedding Service
- **Worker Loop**: `services/embedding_service/worker.py` polls `embed_jobs` for ready rows, fetches chunk bodies, and calls the configured embedding provider (`BAAI/bge-m3` by default).
- **Vector Storage**: Uses `qdrant-client` to upsert embeddings into the configured collection (default `haven_chunks`).
- **Error Handling**: Applies exponential backoff via `embed_jobs.next_attempt_at`, records JSON errors, and leaves jobs queued for retry.

### 3.6 Shared Utilities
- `shared/logging.py` configures structlog + JSON logging.
- `shared/database.py` provides Postgres connection factories and context managers.
- `shared/context.py` bundles aggregate queries for catalog context routes.
- `shared/dependencies.py` guards against missing optional extras.

## 4. Data Model
- **Threads / Messages / Chunks** – Primary catalog tables storing normalized chat structure and chunked message bodies.
- **ingest_submissions / documents** – Track ingestion deduplication, status, and metadata for each document.
- **embed_jobs** – Queue state for embedding attempts, including retry counters and scheduling.
- **search_documents / search_chunks** – Search service schema mirroring ingestion inputs; chunk table stores lexical metadata and embedding status.
- **contacts** – Optional catalog table for normalized people records (populated by contacts collector).

## 5. Configuration & Secrets
| Variable | Scope | Notes |
| --- | --- | --- |
| `DATABASE_URL`, `DB_DSN` | Services & worker | Postgres DSN; search service uses async driver, others sync. |
| `QDRANT_URL`, `QDRANT_COLLECTION`, `EMBEDDING_MODEL`, `EMBEDDING_DIM` | Search & worker | Must stay aligned to avoid embedding mismatches. |
| `AUTH_TOKEN`, `CATALOG_TOKEN`, `SEARCH_TOKEN` | Gateway, catalog, collectors | Enforce ingestion and query auth; collector forwards tokens. |
| `CATALOG_BASE_URL`, `SEARCH_URL` | Gateway | Service discovery for internal proxies. |
| `CATALOG_ENDPOINT`, `COLLECTOR_POLL_INTERVAL`, `COLLECTOR_BATCH_SIZE`, `IMDESC_PATH`, `IMAGE_ENRICHMENT_CACHE`, `OLLAMA_ENABLED`, `OLLAMA_API_URL`, `OLLAMA_VISION_MODEL` | Collector | Control ingestion targets and enrichment behavior. |
| `OLLAMA_BASE_URL`, `WORKER_POLL_INTERVAL`, `WORKER_BATCH_SIZE`, `EMBEDDING_REQUEST_TIMEOUT`, `EMBEDDING_MAX_BACKOFF` | Embedding service | Tuning knobs for throughput vs. load. |

Secrets are supplied via environment variables or `.env` files ignored by git. Sensitive local paths (`~/Library/Messages/chat.db`, `~/.haven/*`) remain on-device.

## 6. Build, Test, and Quality Gates
- **Dependencies**: Managed via `requirements.txt` or optional extras in `pyproject.toml` (`[project.optional-dependencies]`).
- **Lint & Format**: `ruff` and `black` configured; repository still contains baseline violations noted in reports.
- **Type Checking**: `mypy services shared` (search package currently excluded until stubs are updated).
- **Tests**: Pytest suite under `tests/` covers gateway summarization, collector utilities (including image enrichment), and search models.
- **Continuous Validation Suggestion**: `pytest`, `mypy services shared`, `ruff check .`, `docker compose config`.

## 7. Logging & Observability
- All services call `shared.logging.setup_logging()` to emit JSON logs with contextual metadata.
- Key events: `gateway_api_ready`, `ingest_event`, `embedded_chunks`, `collector_enriched_image` (new for attachment enrichment).
- Monitoring strategy relies on Docker logs or central aggregation when deployed beyond local development.

## 8. Extension Points & Future Work
- Replace FastAPI `on_event` startup hooks with lifespan context managers (per FastAPI deprecation notices).
- Consolidate gateway `/v1/doc/{doc_id}` handling entirely within catalog when consumers can follow redirects.
- Expand automated tests for catalog endpoints, embedding service failure scenarios, and collector end-to-end flows.
- Introduce lint/type cleanups to enable strict gating on `ruff`, `black`, and `mypy`.
