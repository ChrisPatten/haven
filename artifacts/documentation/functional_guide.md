# Haven Platform Functional Guide

## 1. User-Facing Capabilities
1. **Search & Ask**: End users query the knowledge base through the gateway for relevant documents and summarized answers.
2. **Catalog Browsing**: Context endpoints provide aggregate stats and highlights for conversation threads.
3. **Document Retrieval**: Gateway exposes raw message bodies by document ID for downstream tools.
4. **Ingestion Pipeline**: Collectors (iMessage) push events that catalog and search services persist, chunk, and prepare for embedding.
5. **Embedding Lifecycle**: Background worker keeps Qdrant in sync so hybrid search can combine lexical and vector similarity.

## 2. Primary Workflows
### 2.1 Search Workflow
1. Client authenticates with bearer `AUTH_TOKEN` against the gateway.
2. `GET /v1/search?q=...&k=20`
   - Gateway builds `SearchRequest` and forwards to Search Service (`/v1/search/query`).
   - Search Service performs lexical + vector scoring; returns top hits.
   - Gateway normalizes hits and responds with `SearchResponse` containing document metadata, snippet, and score.
3. `POST /v1/ask` (optional)
   - Gateway repeats search limited to `k`, constructs summary text by taking top 3 hits, and returns citations.

### 2.2 Catalog Context Workflow
1. Client authenticates with `AUTH_TOKEN` (and `CATALOG_TOKEN` if proxying).
2. `GET /v1/context/general`
   - Gateway proxies to catalog service `/v1/context/general`.
   - Catalog aggregates stats (thread counts, message counts, top threads, recent highlights) and returns structured JSON.

### 2.3 Ingestion Workflow
1. Collector runs periodically (local CLI or container profile) and authenticates with `CATALOG_TOKEN` if provided.
2. Collector reads macOS `chat.db`, converts rows to `CatalogEventsRequest` items, and posts to gateway proxy `/v1/catalog/events` (or directly to catalog in secure deployments).
3. Gateway forwards payload to catalog. Catalog:
   - Upserts thread/message/chunk rows in Postgres.
   - Enqueues chunk IDs into `embed_index_state` with `status='pending'`.
4. Search service ingestion endpoint (if used by other sources) normalizes documents and sets `embedding_status='pending'` on `search_chunks`.

### 2.4 Embedding Workflow
1. Embedding worker polls `embed_index_state` or search chunk tables.
2. Generates vectors and upserts into Qdrant.
3. Sets chunk status to `ready`, unlocking high-quality vector search.

## 3. API Surface Summary
### 3.1 Gateway API (Auth Token Optional)
| Method | Path | Description | Auth |
| --- | --- | --- | --- |
| GET | `/v1/search` | Proxy to search service with pagination controls via `k` | Bearer `AUTH_TOKEN` (optional but recommended) |
| POST | `/v1/ask` | Generate summary answer + citations for a query | Bearer `AUTH_TOKEN` |
| GET | `/v1/doc/{doc_id}` | Proxy to Catalog service for message metadata/text; gateway forwards the request to `CATALOG_BASE_URL` and surfaces the same 404/200 behavior | Bearer `AUTH_TOKEN` |
| GET | `/v1/context/general` | Proxy to catalog for aggregate stats | Bearer `AUTH_TOKEN`, forwards `CATALOG_TOKEN` |
| POST | `/v1/catalog/events` | Proxy ingestion events to catalog | Bearer `CATALOG_TOKEN` if configured |
| GET | `/v1/healthz` | Health probe | None |

### 3.2 Search Service
| Method | Path | Request Model | Response | Notes |
| --- | --- | --- | --- | --- |
| POST | `/v1/ingest/documents:batchUpsert` | `[DocumentUpsert]` | `{ingested, pending_embeddings, skipped}` | Validates org_id, chunking |
| POST | `/v1/ingest/delete` | `DeleteSelector` | `{deleted}` | Removes documents by ID/source |
| POST | `/v1/search/query` | `SearchRequest` | `SearchResult` | Hybrid lexical/vector |
| POST | `/v1/search/similar` | `SearchRequest` | `SearchResult` | Requires `vector` payload |
| POST | `/v1/tools/extract` | `DocumentUpsert` | `ExtractResponse` | Utility for chunk preview |
| GET | `/v1/healthz` | — | `{status, service}` | Health probe |

### 3.3 Catalog API
| Method | Path | Description |
| --- | --- | --- |
| POST | `/v1/catalog/events` | Upsert threads/messages/chunks and enqueue embeddings |
| GET | `/v1/doc/{doc_id}` | Retrieve catalog document metadata |
| GET | `/v1/context/general` | Return counts, top threads, recent highlights |
| GET | `/v1/healthz` | Health status |

## 4. Authentication Model
- **Gateway**: Enforces optional bearer `AUTH_TOKEN`. If unset, routes are public (development-only).
- **Catalog**: `CATALOG_TOKEN` required when set; gateway proxy passes it via Authorization header.
- **Search**: Optional `SEARCH_TOKEN` supported via `SearchServiceClient`.
- **Collector**: Uses `CATALOG_TOKEN` for ingestion; stores local state under `~/.haven`.

## 5. Configuration Profiles
| Environment | Purpose |
| --- | --- |
| `AUTH_TOKEN` | Gateway bearer token. Must be set in production.
| `CATALOG_BASE_URL` | Gateway → catalog routing. Defaults to `http://catalog:8081` (docker network).
| `CATALOG_TOKEN` | Shared ingest token between gateway, catalog, collector.
| `SEARCH_URL` / `SEARCH_TOKEN` | Gateway → search routing and auth.
| `DATABASE_URL` / `DB_DSN` | Postgres DSN for services and worker.
| `QDRANT_URL`, `QDRANT_COLLECTION`, `EMBEDDING_MODEL`, `EMBEDDING_DIM` | Vector settings for search and worker.
| `WORKER_POLL_INTERVAL`, `WORKER_BATCH_SIZE` | Embedding worker tuning knobs.
| `COLLECTOR_POLL_INTERVAL`, `COLLECTOR_BATCH_SIZE`, `CATALOG_ENDPOINT` | Collector behavior.

## 6. Operational Runbooks
### 6.1 Local Development
1. Export required tokens: `export AUTH_TOKEN=changeme` (plus others as needed).
2. Apply schema: `psql postgresql://postgres:postgres@localhost:5432/haven -f schema/catalog_mvp.sql` (if not using docker init script).
3. Start stack: `docker compose up --build`.
4. Optional: enable collector profile `COMPOSE_PROFILES=collector docker compose up --build`.
5. Run tests: `pytest` (optionally `mypy services shared` and `ruff check .`).

### 6.2 iMessage Collector Standalone Use
1. Create virtualenv (`python3.11 -m venv env && source env/bin/activate`).
2. Install project extras: `pip install -e .[collector,common]` or use `requirements.txt`.
3. Run collector: `python services/collector/collector_imessage.py --simulate "Hello"` (simulation) or without `--simulate` for live ingest.
4. Monitor `~/.haven/imessage_collector_state.json` for progress and `.haven/chat_backup/chat.db` for backups.

### 6.3 Embedding Worker Operations
- Ensure `SentenceTransformer` model configured by `EMBEDDING_MODEL` is available (pulls from Hugging Face on first run).
- Monitor logs for `embedded_chunks` and error events.
- To reprocess failures, reset `embed_index_state.status` to `pending` via SQL.

### 6.4 Troubleshooting Tips
| Symptom | Checks |
| --- | --- |
| Gateway 502 on catalog proxy | Confirm `CATALOG_BASE_URL` = `http://catalog:8081` (docker) and catalog container running. |
| No search results | Verify Qdrant reachable, embedding worker running, `search_chunks.embedding_status` updated. |
| Collector fails to post | Ensure `CATALOG_ENDPOINT` points at gateway or catalog with valid token. |
| Worker stuck pending | Check Qdrant collection existence (`qdrant_client.get_collection`) and embedding model download permissions. |

## 7. Data Retention & Privacy
- Collector handles sensitive local data (`~/Library/Messages/chat.db`). The tool creates backups under `~/.haven/chat_backup` and never commits them.
- `.gitignore` excludes `.haven`, `.env`, and other sensitive directories.
- Tokens should be managed via environment variables or `.env` files outside version control.

## 8. Change Management Notes
- Major structural changes captured in `artifacts/structure/` maps and findings.
- When renaming services or routes, update Dockerfile entrypoints, compose service names, and optional dependencies to avoid drift.
- Keep search and worker embedding defaults in sync to maintain vector compatibility.

