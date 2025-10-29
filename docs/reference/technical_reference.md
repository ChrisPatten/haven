# Haven Platform Technical Reference (Unified Schema v2)

## 1. System Overview

Haven ingests heterogeneous personal content (messages, local files, notes) into a unified Postgres schema, enriches binary artefacts, generates semantic embeddings, and exposes hybrid search plus summarisation through a FastAPI gateway. The core services are:

| Service | Responsibility | Entry Point |
| --- | --- | --- |
| **Gateway API** | Public HTTP surface for ingestion, search, ask/summarise, document retrieval/updates, contact sync | `services/gateway_api/app.py` |
| **Catalog API** | Persists unified schema entities, manages document versioning, threads, file dedupe, chunk creation, and search forwarding | `services/catalog_api/app.py` |
| **Search Service** | Hybrid lexical/vector search over `documents` + `chunks`; exposes ingestion/query/admin endpoints | `src/haven/search` |
| **Embedding Worker** | Polls pending chunks, produces vectors, records embedding status, posts results to catalog | `services/embedding_service/worker.py` |
| **Collectors** | Stream source-specific payloads into the gateway (`collector_imessage.py`, `collector_localfs.py`, plus optional contacts collector) | `scripts/collectors/` |

Support components include Qdrant for vector storage and MinIO for raw binary attachments.

## 2. Data Model Summary

The unified schema is defined in `schema/init.sql` and documented in `documentation/SCHEMA_unified_v2.md`. Key tables:

| Table | Purpose | Highlights |
| --- | --- | --- |
| `documents` | Atomic content with versioning | `external_id`, `version_number`, `previous_version_id`, timeline fields, `people` JSONB, facet flags, workflow status |
| `threads` | Conversation metadata | `external_id`, participants array, `first_message_at`, `last_message_at` |
| `files` | Deduplicated binary objects | `content_sha256`, storage backend, enrichment payload (`ocr`, `caption`, `entities`) |
| `document_files` | Document ↔ file mapping | Role (`attachment`, `extracted_from`), order, caption, filename override |
| `chunks` | Text segments for lexical/vector search | `embedding_status` (`pending`, `processing`, `embedded`, `failed`), optional vector |
| `chunk_documents` | Many-to-many chunk mapping | Supports multi-document chunks, stores ordinal & weight |
| `ingest_submissions` | Idempotency tracker | Stores submission metadata, result doc ID, failure details |
| `source_change_tokens` | Collector sync state | Stores last change token per source/device (used by contacts collector) |

Active-document views (`active_documents`, `documents_with_files`, `thread_summary`) simplify read queries.

## 3. Ingestion Pipeline

1. **Collectors** generate source-specific payloads:
   * iMessage collector normalises chat.db rows, enriches attachments, builds people/thread metadata, deduplicates via SHA256, and tracks per-message versions to avoid duplicates.
   * Localfs collector uploads binaries to MinIO, extracts text, attaches image enrichment, and forwards v2 document payloads.
   * Contacts collector converts address book entries into `contact` documents (metadata stored under `metadata.contact`, phone/email identifiers in the `people` array) and tracks change tokens.
2. **Gateway** validates/normalises payloads (`/v1/ingest`, `/v1/ingest/file`), computes idempotency keys, adds timestamps and facet overrides, then forwards them to catalog.
3. **Catalog** inserts into `ingest_submissions`, `documents`, `document_files`, `chunks`, `chunk_documents`, updates thread metadata, and returns `DocumentIngestResponse` with submission & version info.
4. **Embedding worker** polls `chunks` with `embedding_status='pending'`, marks them `processing`, generates vectors, posts to `/v1/catalog/embeddings`, which sets `embedding_status='embedded'` and updates document workflow status.
5. **Search service** queries `documents` / `chunks` for combined lexical/vector search and exposes timeline/facet filters.

Versioning: `PATCH /v1/catalog/documents/{doc_id}/version` clones document state with incremental `version_number`, marks prior version inactive, and rebuilds chunks/file links.

## 4. Gateway API Reference

| Endpoint | Description |
| --- | --- |
| `POST /v1/ingest` | Accepts text documents; forwards v2 payload with timestamps, people, thread info, facet overrides |
| `POST /v1/ingest:batch` | Batch ingest endpoint; accepts multiple documents in one request, returns per-item results with batch tracking |
| `POST /v1/ingest/file` | Handles multipart uploads; stores in MinIO, extracts text, populates file descriptors (`content_sha256`, `object_key`, enrichment) |
| `GET /v1/ingest/{submission_id}` | Returns catalog submission status: chunk counts, document status, errors |
| `GET /v1/search` | Hybrid search; supports filters `has_attachments`, `source_type`, `person`, `thread_id`, `start_date`, `end_date`, `context_window` |
| `POST /v1/ask` | Executes search & builds summarised answer with citations |
| `GET /v1/doc/{doc_id}` / `PATCH /v1/documents/{doc_id}` | Document retrieval and metadata/text updates |
| `GET /v1/context/general` | Returns aggregated timeline highlights & top threads (via catalog proxy) |
| `GET /catalog/contacts/export` / `POST /catalog/contacts/ingest` | Contact synchronisation proxy (gateway now posts unified contact documents and handles deletions) |
| `GET /v1/documents` | Simple listing (legacy) |
| `GET /v1/healthz` | Gateway health probe |

### Gateway Settings
* `AUTH_TOKEN` – optional ingest/search guard.
* `CATALOG_BASE_URL`, `CATALOG_TOKEN` – downstream credentials.
* `SEARCH_URL`, `SEARCH_TOKEN` – search service proxy.
* `MINIO_*` – object store for file uploads.

## 5. Catalog API Reference

| Endpoint | Purpose |
| --- | --- |
| `POST /v1/catalog/documents` | Idempotent document insertion; handles threads, files, chunks, facet flags |
| `POST /v1/catalog/documents/batch` | Batch document insertion; processes multiple documents atomically, tracks batch status in `ingest_batches` table |
| `PATCH /v1/catalog/documents/{doc_id}/version` | Creates a new version, copies/updates file links, rebuilds chunks |
| `GET /v1/catalog/submissions/{submission_id}` | Submission state (catalog + embedding progress) |
| `GET /v1/catalog/documents/{doc_id}/status` | Per-document chunk counts and status |
| `POST /v1/catalog/embeddings` | Accepts embedding vectors, updates chunk + document workflow status |
| `DELETE /v1/catalog/documents/{doc_id}` | Soft delete: removes file links, chunk associations, sets `is_active_version=false` |
| `GET /v1/context/general` | Thread/document summary derived from unified schema |
| `GET /v1/healthz` | Health probe |

Logging binds `doc_id`, `external_id`, `source_type`, `version_number` for traceability.

## 6. Search Service

* **Config:** `SearchSettings` (defaults `postgresql://.../haven_v2`, `QDRANT_URL`, `EMBEDDING_MODEL`).
* **Hybrid Logic:** `_build_where_clauses` translates request filters to SQL; downstream filters also run post-load (people, due dates). Thread context windows fetch neighbouring documents for thread queries.
* **Ranking:** Recency boost (`content_timestamp`), attachment boost, source weighting (email > imessage > sms > others).
* **Metadata:** Each `SearchHit` includes facets (`source_type`, `has_attachments`, `person`), timeline (UTC ISO), people array, and thread ID.
* **Vector Search:** Uses Qdrant `Filter` with payload fields; fallback to lexical only when vector text absent.

## 7. Embedding Worker

* Polls `chunks` where `embedding_status = 'pending'`.
* Marks chunk `processing`, loads text, skips empty chunks (sets `embedded` with no vector).
* Calls Ollama (or configured provider) to generate embeddings then posts to catalog `/v1/catalog/embeddings` with chunk ID, model, dimensions.
* Failures mark chunk `failed` (logs doc associations via `chunk_documents` table) – no automatic retry; manual intervention can reset `embedding_status` to `pending` if retry required.
* Configuration via `WORKER_POLL_INTERVAL`, `WORKER_BATCH_SIZE`, `EMBEDDING_REQUEST_TIMEOUT`.
* Note: The worker no longer uses an `embed_jobs` table or exponential backoff retry logic; it processes chunks directly from the `chunks` table.

## 8. Collectors

### iMessage
* Backs up `chat.db`, tracks state in `~/.haven/imessage_collector_state.json`.
* Version tracker (`imessage_versions.json`) stores message signatures (text hash, attachment hashes) to skip re-ingestion of unchanged events.
* Enrichment includes OCR, caption, entities; attachments include SHA256, path, enrichment status.
* Payload fields: `source_type="imessage"`, `source_provider="apple_messages"`, `people` array, thread metadata, facet overrides.
* Supports `--disable-images` to skip enrichment and insert placeholders (`IMAGE_PLACEHOLDER_TEXT`, `IMAGE_MISSING_PLACEHOLDER_TEXT`).

### Localfs
* Watches configured directory, respects include/exclude patterns, dedupes by SHA256.
* Uploads file to MinIO, extracts text (pdfminer for PDF, raw decode for text), attaches enrichment data for images.
* Metadata includes mtime (`content_timestamp`), ctime (`content_created_at`), and tags; attachments use `content_sha256`, `object_key`, `storage_backend="minio"`.

## 9. Backfill & Enrichment

`python scripts/backfill_image_enrichment.py --use-chat-db` enriches historical images by fetching document metadata from gateway, locating files on disk, re-running OCR/captioning, and posting updates. Catalog updates file enrichment JSONB and requeues affected chunks, triggering new embeddings.

## 10. Environment & Secrets

| Variable | Used By | Description |
| --- | --- | --- |
| `DATABASE_URL` | Catalog, gateway, embedding worker | Postgres DSN (`haven_v2` by default) |
| `DB_DSN` | Search service (async) | Alternative DSN override (also defaults to `haven_v2`) |
| `QDRANT_URL`, `QDRANT_COLLECTION` | Search service, embedding worker | Vector storage endpoint & collection |
| `EMBEDDING_MODEL`, `EMBEDDING_DIM` | Search service, embedding worker | Model identifier and vector dimensionality |
| `AUTH_TOKEN` | Gateway, collectors | Bearer auth for public endpoints |
| `CATALOG_TOKEN` | Gateway, collectors | Downstream auth for catalog |
| `MINIO_ENDPOINT` / `MINIO_*` | Gateway | Attachment object store configuration |
| `CATALOG_ENDPOINT` | iMessage collector | Gateway ingest endpoint |
| `GATEWAY_URL` | Localfs collector, backfill script | Gateway base URL |
| `IMAGE_PLACEHOLDER_TEXT`, `IMAGE_MISSING_PLACEHOLDER_TEXT` | Collectors | Placeholder strings for disabled/missing images |
| `IMDESC_CLI_PATH`, `OLLAMA_*` | Image enrichment | Optional OCR/caption settings |

Secrets should be provided via `.env` files (gitignored), shell exports, or secret management tooling. Sensitive local files (`~/.haven`, chat.db backups) remain outside version control.

## 11. Testing & Quality Gates

* **Linting:** `ruff check .` (progressively enforce), `black .`.
* **Typing:** `mypy services shared` (search service pending strict coverage).
* **Testing:** `pytest` (gateway + shared modules) — extend coverage for catalog/search/worker flows.
* **Smoke:** `docker compose up --build`, ingest sample data via collectors (`--simulate` for iMessage), verify `GET /v1/search` and embedding logs.

## 12. Troubleshooting

| Symptom | Diagnosis |
| --- | --- |
| `POST /v1/ingest` returns 409 | Submission idempotency – payload matches existing text hash/version; check version tracker for collector |
| Chunks stuck `processing` | Embedding worker crash; reset `chunks.embedding_status` to `pending` |
| Vector search returns zero results | Ensure `chunks.embedding_vector` populated (embedding worker running, `EMBEDDING_MODEL` aligned) |
| Attachments missing enrichment | Validate local files still exist, OCR helper configured, Ollama reachable |
| Search facet mismatch | Verify gateway forwards filters and search service logs processed filters |

Refer to `documentation/unified_schema_v2_overview.md` for a high-level migration summary and to the functional guide for user-facing workflows.
