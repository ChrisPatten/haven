# Haven Platform Functional Guide

## 1. Core Capabilities
1. **Hybrid Search & Ask** – Gateway exposes lexical/vector search and answer synthesis over cataloged t### 6.5 Contact### 6.7 Troubleshooting
| Symptom | Checks |
| --- | --- |
| Gateway 502 on catalog proxy | Verify `CATALOG_BASE_URL` and catalog container health. |
| Empty search results | Confirm Qdrant is reachable, the embedding service is running, and chunks marked `ready`. |
| Collector fails to post | Ensure `CATALOG_ENDPOINT` is correct and `CATALOG_TOKEN` matches gateway configuration. |
| Attachment enrichment skipped | Check helper binary path (`IMDESC_CLI_PATH`), Ollama availability, and permissions for `~/.haven` cache directory. |
| Worker stuck pending | Validate Qdrant collection existence and embedding model downloads. |
| Backfill script fails | Verify `AUTH_TOKEN` is set, gateway is reachable, and image files still exist on disk. Use `--dry-run` first. |tor
1. Install macOS-specific dependencies: `pip install -r local_requirements.txt`.
2. Run `python scripts/collectors/collector_contacts.py` (requires GUI permission prompt).
3. Confirm contacts appear in catalog via `/catalog/contacts/export` or gateway proxy.

### 6.6 Embedding Service Operations.
2. **Catalog Insights** – Context endpoints surface thread statistics, highlights, and document metadata.
3. **Document Retrieval & Management** – Clients can fetch, list, and update document payloads by document ID.
4. **Ingestion Pipeline** – Collectors stream normalized iMessage events (and optional contacts) into the catalog.
5. **Embedding Lifecycle** – Background worker keeps Qdrant synchronized so hybrid search remains high quality.
6. **Attachment Enrichment** – Optional OCR, entity, and caption enrichment (via `shared/image_enrichment.py`) makes image content searchable.
7. **Backfill Operations** – Script to enrich images for already-ingested messages and trigger re-embedding.

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
1. Collector runs locally (CLI or Docker profile) and authenticates with `AUTH_TOKEN` (falls back to `CATALOG_TOKEN` for legacy deployments).
2. Collector reads macOS `chat.db`, converts rows into ingest payloads, and posts them to the gateway `POST /v1/ingest` endpoint.
3. Gateway normalizes document text, enforces idempotency, and forwards the request to catalog `POST /v1/catalog/documents`.
4. Catalog upserts submission metadata, documents, and chunks; new chunk IDs land in the `embed_jobs` queue with `status='queued'`.
5. Optional attachment enrichment metadata (OCR, captions) rides along in chunk text and message attributes for downstream search.

### 2.4 Embedding Worker
1. Embedding service polls `embed_jobs` for chunks ready to embed.
2. Generates embeddings via the configured provider/model (`BAAI/bge-m3` by default).
3. Upserts vectors into Qdrant and marks chunks `ready`, clearing the job record.
4. Hybrid search results combine lexical signals with vector similarity.

### 2.5 Attachment Enrichment
1. When the collector encounters image attachments it invokes the shared enrichment module (`shared/image_enrichment.py`).
2. The module runs the optional native helper (`imdesc`) to extract OCR text and entities via macOS Vision.
3. If an Ollama vision model is configured, the module requests captions to augment the message body.
4. Enrichment artifacts are cached locally in `~/.haven/imessage_image_cache.json` and appended to chunk text plus message attributes.
5. Search and context endpoints surface image-derived content (captions, OCR text, entities).
6. Missing helpers or caption endpoints trigger warnings; ingestion continues with configurable placeholder text.
7. Configurable placeholders: `IMAGE_PLACEHOLDER_TEXT` (default `"[image]"`) and `IMAGE_MISSING_PLACEHOLDER_TEXT` (default `"[image not available]"`).

### 2.6 Document Update & Re-embedding
1. Client can update a document's metadata and text via `PATCH /v1/documents/{doc_id}`.
2. Gateway validates the doc_id and forwards the request to catalog.
3. Catalog updates the document record and optionally requeues all associated chunks for re-embedding.
4. The embedding worker picks up requeued chunks and generates new embeddings with the updated content.
5. Use case: backfilling image enrichment data after initial ingestion.

### 2.7 Backfill Image Enrichment
1. Run `scripts/backfill_image_enrichment.py` with `AUTH_TOKEN` and `GATEWAY_URL` configured.
2. Script queries gateway `GET /v1/documents?has_attachments=true` for messages with images.
3. For messages collected without attachment metadata, use `--use-chat-db` to query the chat.db backup.
4. Script resolves image file paths, enriches images via `shared/image_enrichment.py`, and updates documents via `PATCH /v1/documents/{doc_id}`.
5. Updated documents are automatically requeued for embedding with enriched content.
6. Script outputs statistics: documents scanned, images found/missing/enriched, chunks requeued, errors.

### 2.8 Contacts Sync (Optional)
1. `collector_contacts.py` reads the macOS Contacts store using pyobjc.
2. Contacts are batched and POSTed to the gateway contact ingest proxy (`POST /catalog/contacts/ingest`).
3. Catalog stores normalized person records; `GET /catalog/contacts/export` streams them back as NDJSON for downstream consumers.

## 3. API Surface Summary
### 3.1 Gateway API
| Method | Path | Description | Auth |
| --- | --- | --- | --- |
| GET | `/v1/search` | Hybrid search proxy with lexical/vector ranking | Bearer `AUTH_TOKEN` |
| POST | `/v1/ask` | Summarize top search hits with citations | Bearer `AUTH_TOKEN` |
| POST | `/v1/ingest` | Normalize and forward documents to catalog | Bearer `AUTH_TOKEN` |
| GET | `/v1/ingest/{submission_id}` | Fetch submission + embedding status | Bearer `AUTH_TOKEN` |
| GET | `/v1/doc/{doc_id}` | Proxy to catalog for message metadata | Bearer `AUTH_TOKEN` |
| PATCH | `/v1/documents/{doc_id}` | Update document metadata/text and requeue for embedding | Bearer `AUTH_TOKEN` |
| GET | `/v1/documents` | List documents with optional filtering (source_type, has_attachments) | Bearer `AUTH_TOKEN` |
| GET | `/v1/context/general` | Aggregate conversation insights | Bearer `AUTH_TOKEN`, forwards `CATALOG_TOKEN` when set |
| GET | `/catalog/contacts/export` | Stream contacts as NDJSON | Bearer `AUTH_TOKEN` |
| POST | `/catalog/contacts/ingest` | Ingest normalized contacts | Bearer `AUTH_TOKEN` (+ `CATALOG_TOKEN` if enforced downstream) |
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
| PATCH | `/v1/catalog/documents/{doc_id}` | Update document metadata/text and requeue chunks for embedding |
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
| `CATALOG_TOKEN` | Optional shared secret forwarded to catalog ingest/status routes.
| `SEARCH_URL` / `SEARCH_TOKEN` | Gateway → search routing and auth.
| `DATABASE_URL` / `DB_DSN` | Postgres DSN for services and worker.
| `QDRANT_URL`, `QDRANT_COLLECTION`, `EMBEDDING_MODEL`, `EMBEDDING_DIM` | Vector configuration shared by search + worker.
| `WORKER_POLL_INTERVAL`, `WORKER_BATCH_SIZE` | Embedding service tuning knobs.
| `COLLECTOR_POLL_INTERVAL`, `COLLECTOR_BATCH_SIZE`, `CATALOG_ENDPOINT` | Collector behavior (`CATALOG_ENDPOINT` defaults to gateway `/v1/ingest`).
| `OLLAMA_ENABLED`, `OLLAMA_API_URL`, `OLLAMA_VISION_MODEL`, `OLLAMA_CAPTION_PROMPT`, `OLLAMA_TIMEOUT_SECONDS`, `OLLAMA_MAX_RETRIES` | Optional Ollama vision captioning configuration (shared enrichment module).
| `IMDESC_CLI_PATH`, `IMDESC_TIMEOUT_SECONDS` | macOS Vision OCR helper configuration.
| `IMAGE_PLACEHOLDER_TEXT`, `IMAGE_MISSING_PLACEHOLDER_TEXT` | Configurable placeholder text for disabled/missing images.
| `GATEWAY_URL` | Used by backfill script to communicate with the gateway API (default: `http://localhost:8085`).

## 6. Operational Runbooks
### 6.1 Local Development
1. Export required tokens (`AUTH_TOKEN`, optionally `CATALOG_TOKEN`).
2. Start stack: `docker compose up --build` (add `COMPOSE_PROFILES=collector` to include the collector container).
3. Apply schema (if you need to reset Postgres) via `docker compose exec -T postgres psql -U postgres -d haven -f - < schema/init.sql`.
4. Run tests: `pytest`, optionally `mypy services shared` and `ruff check .`.
5. Tail logs with `docker compose logs -f gateway catalog search` when debugging.

### 6.2 iMessage Collector
1. Create a Python 3.11 virtualenv (`python3.11 -m venv env && source env/bin/activate`) or reuse Docker profile.
2. Install dependencies (`pip install -e .[collector,common]` or `pip install -r requirements.txt`).
3. Run `python scripts/collectors/collector_imessage.py --simulate "Hello"` for dry runs or omit `--simulate` for live ingest.
4. Monitor `~/.haven/imessage_collector_state.json` and `.haven/chat_backup/chat.db` for progress.

### 6.3 Attachment Enrichment
1. Build `scripts/collectors/imdesc.swift` via `scripts/build-imdesc.sh` (places the helper binary under `scripts/collectors/bin/imdesc`).
2. Confirm the collector locates the helper (`IMDESC_CLI_PATH` override available) and that `~/.haven/imessage_image_cache.json` is writable.
3. Optional: configure an Ollama vision endpoint (set `OLLAMA_API_URL` and `OLLAMA_VISION_MODEL`; update `OLLAMA_BASE_URL` for the embedding service if it calls a remote provider).
4. The shared enrichment module (`shared/image_enrichment.py`) handles OCR, captioning, caching, and graceful fallbacks.
5. Review collector logs for enrichment warnings; ingestion proceeds with configurable placeholders when enrichment fails.

### 6.4 Backfilling Image Enrichment
1. Ensure gateway API is running at `GATEWAY_URL` (default: `http://localhost:8085`).
2. Set `AUTH_TOKEN` environment variable for authentication.
3. Run dry-run first to preview changes:
   ```bash
   python scripts/backfill_image_enrichment.py --dry-run --limit 10 --use-chat-db
   ```
4. Process documents with `--use-chat-db` flag to query chat.db backup for attachment paths:
   ```bash
   python scripts/backfill_image_enrichment.py --use-chat-db
   ```
5. Monitor output for statistics: documents scanned, images enriched, chunks requeued, errors.
6. The embedding service will automatically pick up requeued chunks and generate new embeddings.

### 6.5 Contacts Collector
1. Install macOS-specific dependencies: `pip install -r local_requirements.txt`.
2. Run `python scripts/collectors/collector_contacts.py` (requires GUI permission prompt).
3. Confirm contacts appear in catalog via `/catalog/contacts/export` or gateway proxy.

### 6.6 Embedding Service Operations
1. Ensure the embedding model referenced by `EMBEDDING_MODEL` is available (downloads on first run).
2. Monitor `embedding.service` logs for successful job completion events; failures leave rows in `embed_jobs` for retry.
3. If a job stalls, reset `chunks.status` to `queued` or adjust `embed_jobs.next_attempt_at` to trigger immediate retries.

### 6.7 Troubleshooting
| Symptom | Checks |
| --- | --- |
| Gateway 502 on catalog proxy | Verify `CATALOG_BASE_URL` and catalog container health. |
| Empty search results | Confirm Qdrant is reachable, the embedding service is running, and chunks marked `ready`. |
| Collector fails to post | Ensure `CATALOG_ENDPOINT` is correct and `CATALOG_TOKEN` matches gateway configuration. |
| Attachment enrichment skipped | Check helper binary path, Ollama availability, and permissions for the cache directory. |
| Worker stuck pending | Validate Qdrant collection existence and embedding model downloads. |

## 7. Data Retention & Privacy
- Collector handles sensitive data from `~/Library/Messages/chat.db`; backups are stored under `~/.haven/chat_backup` and excluded from git.
- Image enrichment cache is stored in `~/.haven/imessage_image_cache.json` (keyed by image blob hash, contains OCR/captions but not raw images).
- `.gitignore` excludes `.haven`, `.env`, and other sensitive directories.
- Manage tokens via environment variables or secrets management tooling.
- Attachment content is used only for enrichment metadata; raw image bytes are not uploaded to services.

## 8. Change Management Notes
- Architectural maps, findings, and change reports live in `documentation/`.
- When adjusting routes or service names, update Dockerfile entrypoints and compose service definitions to avoid drift.
- Keep search service configuration in sync with the embedding service to maintain vector compatibility.
