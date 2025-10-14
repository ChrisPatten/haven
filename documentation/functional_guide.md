# Haven Platform Functional Guide

## 1. Core Capabilities
1. **Hybrid Search & Ask** – Gateway exposes lexical/vector search and answer synthesis over cataloged threads.
2. **Catalog Insights** – Context endpoints surface thread statistics, highlights, and document metadata.
3. **Document Retrieval** – Clients can fetch full message payloads by document ID.
4. **Ingestion Pipeline** – Collectors stream normalized iMessage events (and optional contacts) into the catalog.
5. **Embedding Lifecycle** – Background worker keeps Qdrant synchronized so hybrid search remains high quality.
6. **Attachment Enrichment** – Optional OCR, entity, and caption enrichment makes image content searchable.

## 2. Primary Workflows
### 2.1 Search & Ask
1. Client authenticates against the gateway with bearer `AUTH_TOKEN`.
2. `GET /v1/search?q=...&k=20`
   - Gateway builds a `SearchRequest` and forwards it to the Search Service `/v1/search/query` endpoint.
   - Search service performs lexical + vector scoring and returns scored hits.
   - Gateway normalizes hits into `SearchResponse` with document metadata, snippets, and ranking score.
3. `POST /v1/ask`
   - Gateway performs a secondary search limited to `k` hits, summarizes the top results, and returns an answer with citations.

### 2.2 Catalog Context
1. Client authenticates with `AUTH_TOKEN` (and `CATALOG_TOKEN` if required downstream).
2. `GET /v1/context/general`
   - Gateway proxies the call to catalog `/v1/context/general`.
   - Catalog aggregates thread counts, message counts, top conversations, and recent highlights.

### 2.3 Ingestion Pipeline
1. Collector runs locally (CLI or Docker profile) and authenticates with `CATALOG_TOKEN` when configured.
2. Collector reads macOS `chat.db`, converts rows into `CatalogEventsRequest` payloads, and posts them to `POST /v1/catalog/events` on the gateway.
3. Gateway streams the request to the catalog service, which:
   - Upserts threads/messages/chunks in Postgres.
   - Emits chunk IDs into `embed_index_state` with `status='pending'`.
   - Stores attachment metadata, OCR output, and optional captions on message attributes for downstream search.
4. Other ingestion surfaces (e.g., search service batch upsert) follow a similar normalization + enqueue pattern.

### 2.4 Embedding Worker
1. Embedding worker polls for pending chunk IDs.
2. Generates embeddings via `SentenceTransformer` (`BAAI/bge-m3`).
3. Upserts vectors into Qdrant and marks chunks `ready`.
4. Hybrid search results combine lexical signals with vector similarity.

### 2.5 Attachment Enrichment
1. When the collector encounters image attachments it invokes the optional native helper (`imdesc`) to extract OCR text and entities via macOS Vision.
2. If an Ollama vision model is configured, the collector requests captions to augment the message body.
3. Enrichment artifacts are cached locally and appended to the chunk text plus message attributes so that search and context endpoints surface image-derived content.
4. Missing helpers or caption endpoints trigger warnings; ingestion continues with base message text.

### 2.6 Contacts Sync (Optional)
1. `collector_contacts.py` reads the macOS Contacts store using pyobjc.
2. Contacts are batched and POSTed to the gateway contact ingest proxy (`POST /catalog/contacts/ingest`).
3. Catalog stores normalized person records; `GET /catalog/contacts/export` streams them back as NDJSON for downstream consumers.

## 3. API Surface Summary
### 3.1 Gateway API
| Method | Path | Description | Auth |
| --- | --- | --- | --- |
| GET | `/v1/search` | Hybrid search proxy with lexical/vector ranking | Bearer `AUTH_TOKEN` (recommended) |
| POST | `/v1/ask` | Summarize top search hits with citations | Bearer `AUTH_TOKEN` |
| GET | `/v1/doc/{doc_id}` | Proxy to catalog for message metadata | Bearer `AUTH_TOKEN` |
| GET | `/v1/context/general` | Aggregate conversation insights | Bearer `AUTH_TOKEN`, forwards `CATALOG_TOKEN` |
| POST | `/v1/catalog/events` | Stream collector events into catalog | Bearer `CATALOG_TOKEN` when configured |
| GET | `/catalog/contacts/export` | Stream contacts as NDJSON | Bearer `AUTH_TOKEN` |
| POST | `/catalog/contacts/ingest` | Ingest normalized contacts | Bearer `AUTH_TOKEN` + `CATALOG_TOKEN` if required |
| GET | `/v1/healthz` | Service health probe | None |

### 3.2 Search Service
| Method | Path | Request Model | Response | Notes |
| --- | --- | --- | --- | --- |
| POST | `/v1/ingest/documents:batchUpsert` | `[DocumentUpsert]` | `{ingested, pending_embeddings, skipped}` | Validates org_id, chunking |
| POST | `/v1/ingest/delete` | `DeleteSelector` | `{deleted}` | Removes documents by ID/source |
| POST | `/v1/search/query` | `SearchRequest` | `SearchResult` | Hybrid lexical/vector |
| POST | `/v1/search/similar` | `SearchRequest` | `SearchResult` | Requires vector payload |
| POST | `/v1/tools/extract` | `DocumentUpsert` | `ExtractResponse` | Chunk preview utility |
| GET | `/v1/healthz` | — | `{status, service}` | Health probe |

### 3.3 Catalog API
| Method | Path | Description |
| --- | --- | --- |
| POST | `/v1/catalog/events` | Upsert threads/messages/chunks and enqueue embeddings |
| GET | `/v1/doc/{doc_id}` | Retrieve catalog document metadata |
| GET | `/v1/context/general` | Return counts, top threads, recent highlights |
| GET | `/catalog/contacts/export` | Stream contacts as NDJSON |
| POST | `/catalog/contacts/ingest` | Ingest normalized contacts |
| GET | `/v1/healthz` | Health status |

## 4. Authentication Model
- **Gateway** – Enforces optional bearer `AUTH_TOKEN`. If unset, routes are open (development-only).
- **Catalog** – Honors `CATALOG_TOKEN` on ingestion routes; gateway proxies the header when configured.
- **Search** – Optional `SEARCH_TOKEN` supported by `SearchServiceClient`.
- **Collectors** – Use `CATALOG_TOKEN` for ingestion and store progress under `~/.haven`.

## 5. Configuration Profiles
| Variable | Purpose |
| --- | --- |
| `AUTH_TOKEN` | Gateway bearer token; must be set in production.
| `CATALOG_BASE_URL` | Gateway → catalog routing. Defaults to `http://catalog:8081` in Docker.
| `CATALOG_TOKEN` | Shared ingest secret for collector → gateway → catalog.
| `SEARCH_URL` / `SEARCH_TOKEN` | Gateway → search routing and auth.
| `DATABASE_URL` / `DB_DSN` | Postgres DSN for services and worker.
| `QDRANT_URL`, `QDRANT_COLLECTION`, `EMBEDDING_MODEL`, `EMBEDDING_DIM` | Vector configuration shared by search + worker.
| `WORKER_POLL_INTERVAL`, `WORKER_BATCH_SIZE` | Embedding worker tuning knobs.
| `COLLECTOR_POLL_INTERVAL`, `COLLECTOR_BATCH_SIZE`, `CATALOG_ENDPOINT` | Collector behavior.
| `OLLAMA_HOST`, `IMDESC_PATH`, `IMAGE_ENRICHMENT_CACHE` | Optional attachment enrichment configuration.

## 6. Operational Runbooks
### 6.1 Local Development
1. Export required tokens (`AUTH_TOKEN`, optionally `CATALOG_TOKEN`).
2. Start stack: `docker compose up --build` (add `COMPOSE_PROFILES=collector` to include the collector container).
3. Apply schema from a healthy postgres container: `docker compose exec -T postgres psql -U postgres -d haven -f - < schema/catalog_mvp.sql`.
4. Run tests: `pytest`, optionally `mypy services shared` and `ruff check .`.
5. Tail logs with `docker compose logs -f gateway catalog search` when debugging.

### 6.2 iMessage Collector
1. Create a Python 3.11 virtualenv (`python3.11 -m venv env && source env/bin/activate`) or reuse Docker profile.
2. Install dependencies (`pip install -e .[collector,common]` or `pip install -r requirements.txt`).
3. Run `python scripts/collectors/collector_imessage.py --simulate "Hello"` for dry runs or omit `--simulate` for live ingest.
4. Monitor `~/.haven/imessage_collector_state.json` and `.haven/chat_backup/chat.db` for progress.

### 6.3 Attachment Enrichment
1. Build `scripts/collectors/imdesc.swift` via `scripts/build-imdesc.sh` (places the helper binary under `scripts/collectors/bin/imdesc`).
2. Confirm the collector locates the helper (`IMDESC_PATH` override available) and that `IMAGE_ENRICHMENT_CACHE` is writable.
3. Optional: configure an Ollama vision endpoint (set `OLLAMA_HOST` if not `http://localhost:11434`).
4. Review collector logs for enrichment warnings; ingestion proceeds even without helpers.

### 6.4 Contacts Collector
1. Install macOS-specific dependencies: `pip install -r local_requirements.txt`.
2. Run `python scripts/collectors/collector_contacts.py` (requires GUI permission prompt).
3. Confirm contacts appear in catalog via `/catalog/contacts/export` or gateway proxy.

### 6.5 Embedding Worker Operations
- Ensure the embedding model referenced by `EMBEDDING_MODEL` is available (downloads on first run).
- Monitor logs for successful `embedded_chunks` events and handle failures by resetting `embed_index_state.status` to `pending`.

### 6.6 Troubleshooting
| Symptom | Checks |
| --- | --- |
| Gateway 502 on catalog proxy | Verify `CATALOG_BASE_URL` and catalog container health. |
| Empty search results | Confirm Qdrant is reachable, embedding worker running, and chunks marked `ready`. |
| Collector fails to post | Ensure `CATALOG_ENDPOINT` is correct and `CATALOG_TOKEN` matches gateway configuration. |
| Attachment enrichment skipped | Check helper binary path, Ollama availability, and permissions for the cache directory. |
| Worker stuck pending | Validate Qdrant collection existence and embedding model downloads. |

## 7. Data Retention & Privacy
- Collector handles sensitive data from `~/Library/Messages/chat.db`; backups are stored under `~/.haven/chat_backup` and excluded from git.
- `.gitignore` excludes `.haven`, `.env`, and other sensitive directories.
- Manage tokens via environment variables or secrets management tooling.
- Attachment content is used only for enrichment metadata; raw image bytes are not uploaded.

## 8. Change Management Notes
- Architectural maps, findings, and previous change reports live in `artifacts/structure/`.
- When adjusting routes or service names, update Dockerfile entrypoints and compose service definitions to avoid drift.
- Keep search service configuration in sync with the embedding worker to maintain vector compatibility.
