# Haven Platform Technical Reference

## 1. System Overview
Haven is a multi-service platform for ingesting personal communication data, cataloging it in Postgres, embedding message chunks into Qdrant, and exposing search and summary capabilities through a FastAPI gateway.

Core runtime components:
- **Gateway API** (`services/gateway_api/app.py`): Public HTTP surface for search, ask/summary, catalog proxying, and document retrieval.
- **Search Service** (`src/haven/search`): Hybrid lexical/vector search service providing ingestion, search queries, and admin tooling.
- **Catalog API** (`services/catalog_api/app.py`): Receives ingestion events and exposes context aggregation over cataloged messages.
- **Collector** (`services/collector/collector_imessage.py`): CLI worker that extracts iMessage data and forwards it to the catalog pipeline.
- **Embedding Worker** (`services/embedding_worker/worker.py`): Polls pending chunks, generates sentence-transformer embeddings, and stores vectors in Qdrant.
- **Shared Library** (`shared/`): Logging, dependency verification, Postgres helpers, and reusable reporting queries.

## 2. Deployment Topology
### 2.1 Container Orchestration
The stack is defined in `compose.yaml` and assumes Docker Compose with optional profiles:
- `postgres`: `postgres:15` with volume `pg_data` and schema bootstrap (`schema/catalog_mvp.sql`).
- `qdrant`: `qdrant/qdrant:latest` for vector similarity search (`qdrant_data` volume).
- `search`: Builds the Python project with `SERVICE=search`; exposes port 8080.
- `gateway`: Builds with `SERVICE=gateway`; binds host port 8085 → 8080.
- `catalog`: Builds with `SERVICE=catalog`.
- `collector` (optional profile `collector`): Runs the iMessage collector against the gateway.
- `embedding_worker`: Long-running embedding poller.

Build pipeline (Dockerfile):
1. **builder** stage installs project extras per service (`pyproject.toml` optional dependencies).
2. **runtime** stage installs wheels and copies source tree.
3. Entrypoint dispatches based on `$SERVICE` via Bash case statement.

### 2.2 Networks & Ports
All services share the default Docker network (`haven_default`). Gateway maps port `127.0.0.1:8085` → `8080`. Catalog uses `8081` internally and is accessed by gateway via `http://catalog:8081`.

## 3. Service Internals
### 3.1 Gateway API
- **Framework**: FastAPI.
- **Key Modules**: `GatewaySettings`, `SearchServiceClient` dependency wrapper, token enforcement, search summarization utilities.
- **Startup**: Configures logging, sets `DATABASE_URL`, and instantiates `SearchServiceClient` against `settings.search_url`.
- **Routes**:
  - `GET /v1/search`: Async search proxy converting search service hits to gateway models.
  - `POST /v1/ask`: Fetches top-k search results and synthesizes a natural language summary.
  - `GET /v1/doc/{doc_id}`: Direct Postgres lookup for a single message.
  - `GET /v1/context/general`: Proxies to catalog context endpoint, forwarding catalog token.
  - `POST /v1/catalog/events`: Streams ingestion payloads to catalog API.
  - `GET /v1/healthz`: Health status.
- **Environment**:
  - `AUTH_TOKEN`: Bearer token required for gateway endpoints (optional).
  - `CATALOG_BASE_URL`: Default `http://catalog:8081`.
  - `CATALOG_TOKEN`, `SEARCH_URL`, `SEARCH_TOKEN` for downstream auth.
  - `DATABASE_URL`, `QDRANT_URL`, `QDRANT_COLLECTION`, `EMBEDDING_MODEL` for alignment with search metadata.

### 3.2 Search Service
- **Entry**: `haven.search.main:cli` (Typer). `serve` command runs uvicorn `create_app` (FastAPI) with `lifespan="on"`.
- **Configuration** (`src/haven/search/config.py`): Pydantic settings covering Postgres DSN, Qdrant config, embedding metadata, service naming, and ingestion batch sizing.
- **Database Access** (`src/haven/search/db.py`): Async `psycopg` connections with transactional wrapper `run_in_transaction`.
- **Routes** (`src/haven/search/routes`):
  - `/v1/ingest/documents:batchUpsert`: Uses `IngestionPipeline` to normalize, chunk, and store documents.
  - `/v1/ingest/delete`: Deletes by document/source selectors.
  - `/v1/search/query` & `/v1/search/similar`: Hybrid search endpoints.
  - `/v1/tools/extract`: Returns chunk preview for debugging.
  - Admin/Index routes provide maintenance hooks.
- **Pipeline**:
  - `normalize_document` & `default_chunker` convert inputs into chunk lists with metadata.
  - `PostgresDocumentRepository` persists documents and chunk metadata, tracks idempotency, and writes search_chunks rows with `embedding_status='pending'`.
- **Hybrid Search** (`services/hybrid.py`): Combines lexical (Postgres full-text) and vector (Qdrant) scoring, merging results by chunk ID.

### 3.3 Catalog API
- **Routes**:
  - `POST /v1/catalog/events`: Ingests threads, messages, and chunk metadata; refreshes `embed_index_state` for worker pickup.
  - `GET /v1/doc/{doc_id}`: Returns message fields from Postgres.
  - `GET /v1/context/general`: Uses `shared.context.fetch_context_overview` to compute aggregate statistics (thread counts, highlights).
  - `GET /v1/healthz`: Status.
- **Database**: Uses `shared.db.get_connection` and SQL statements defined inline. Stores denormalized JSON in `messages.attrs` and chunk metadata.
- **Authentication**: Optional ingestion bearer token.

### 3.4 Collector (iMessage)
- **Purpose**: Sync local macOS `chat.db` into Haven.
- **Workflow**:
  1. Determine last processed row IDs from `~/.haven/imessage_collector_state.json`.
  2. Use SQLite backup API to copy `chat.db` into `~/.haven/chat_backup/chat.db` for safe reads.
  3. Query messages, participants, attachments, and convert Apple epoch timestamps to UTC.
  4. Generate deterministic chunk IDs, truncate message text, and export payload via `requests.post` to `CATALOG_ENDPOINT`.
  5. Persist collector state.
- **CLI**: `collector-run` entrypoint exposes `main()`; CLI options defined with `argparse` allow simulation mode (`--simulate`).

### 3.5 Embedding Worker
- **Workflow**:
  1. Connect to Postgres and fetch `embed_index_state` rows with `status='pending'`.
  2. Mark them `processing`, encode chunk text with `SentenceTransformer(settings.embedding_model)`.
  3. Upsert vectors into Qdrant via `QdrantClient.upsert`, storing metadata payloads (document IDs).
  4. Update state to `ready` or mark as `error` on failure.
- **Key Settings**: `poll_interval`, `batch_size`, `embedding_dim`, `QDRANT_COLLECTION` align with search configuration.

## 4. Data Layer
### 4.1 Postgres Schema
Defined in `schema/catalog_mvp.sql`:
- `threads`, `messages`, `chunks` capture cataloged conversation data.
- `embed_index_state` tracks embedding workflow state.
- `search_documents`, `search_chunks`, `search_ingest_log`, `search_deletes` support search ingestion and cleanup.
- Triggers maintain updated timestamps and tsvector columns for full-text search.

### 4.2 Vector Store
- Qdrant collection defaults to `haven_chunks` with cosine distance.
- Each point stores chunk vectors keyed by chunk UUID or deterministic ID plus metadata payload (`doc_id`, `org_id`).

## 5. Configuration & Secrets
Environment variables used across services:
- **Database**: `DATABASE_URL`, `DB_DSN`.
- **Search/Qdrant**: `QDRANT_URL`, `QDRANT_COLLECTION`, `EMBEDDING_MODEL`, `EMBEDDING_DIM`.
- **Auth**: `AUTH_TOKEN`, `CATALOG_TOKEN`, `SEARCH_TOKEN`.
- **Collector**: `CATALOG_ENDPOINT`, `COLLECTOR_POLL_INTERVAL`, `COLLECTOR_BATCH_SIZE`.
- **Worker**: `WORKER_POLL_INTERVAL`, `WORKER_BATCH_SIZE`.

Secrets are expected via environment variables or `.env` files excluded by `.gitignore`. macOS-specific path `~/Library/Messages/chat.db` is treated as sensitive input.

## 6. Build, Test, and Quality Gates
- **Dependencies**: Manage via `requirements.txt` or optional extras in `pyproject.toml`.
- **Formatting & Lint**: `black`, `ruff` (setup but baseline contains legacy issues).
- **Type Checking**: `mypy services shared` (requires stub setup for third-party packages).
- **Tests**: Pytest suite in `tests/`, covering gateway summarization/catalog proxy, collector utilities, search models.
- **Continuous Validation**: Recommended commands per repo guidelines: `pytest`, `mypy services shared`, `ruff check .`, `docker compose config`.

## 7. Runtime Logging & Observability
- Uses `shared.logging` (structlog + python-json-logger) to emit structured logs.
- Services typically call `setup_logging()` during startup before interacting with external systems.
- Logs annotate key events (`gateway_api_ready`, `ingest_event`, `embedded_chunks`, etc.) for monitoring.

## 8. Extension Points & Future Work
- Replace FastAPI `on_event` startup hooks with lifespan context managers (FastAPI deprecation notice).
- Consolidate gateway `/v1/doc/{doc_id}` onto catalog API to remove duplication.
- Add dedicated tests for catalog endpoints, embedding worker, and collector integration flows.
- Introduce lint/type cleanups to enable gating on `ruff`, `black`, and `mypy`.

