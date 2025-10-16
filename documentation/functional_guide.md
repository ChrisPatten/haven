# Haven Functional Guide (Unified Schema v2)

This guide describes the day-to-day workflows exposed by the Haven platform after the unified schema refactor.

## 1. Core Capabilities

1. **Unified Ingestion** – Collectors and external clients can ingest documents, files, and attachments with full provenance (threads, people, facets) via the gateway.
2. **Document Versioning** – Catalog tracks multiple versions of a document and exposes helpers to create new versions or inspect status.
3. **Hybrid Search & Ask** – Combined lexical/vector search with facet, timeline, people, and thread filters; “ask” summarises top results with citations.
4. **Attachment Enrichment** – OCR, captioning, and entity extraction for images (iMessage and localfs collectors) stored centrally and used in search/ranking.
5. **Embedding Lifecycle** – Background worker keeps chunk embeddings updated; status APIs show progress at submission/document level.
6. **Context & Insights** – Catalog aggregates active documents to provide thread counts, recent highlights, and timeline stats.

## 2. Primary Workflows

### 2.1 Ingesting Text Documents
1. POST to `gateway /v1/ingest` with:
   ```json
   {
     "source_type": "note",
     "source_id": "note:123",
     "content": {"mime_type": "text/plain", "data": "Hello world"},
     "content_timestamp": "2024-06-01T12:00:00Z",
     "content_timestamp_type": "created",
     "people": [{"identifier": "me", "identifier_type": "imessage", "role": "sender"}],
     "metadata": {"source": "notes_app"}
   }
   ```
2. Gateway normalises timestamps, injects idempotency key, and forwards to catalog.
3. Catalog returns `submission_id`, `doc_id`, `external_id`, `version_number`, `status`, `thread_id` (if linked), `file_ids` (if applicable), and `duplicate` flag.
4. Check status via `GET /v1/ingest/{submission_id}` which returns `total_chunks`, `embedded_chunks`, `pending_chunks`, and document status.

### 2.2 Ingesting Files
1. POST multipart to `gateway /v1/ingest/file` with `meta` JSON (path, mtime, optional tags) and binary `upload`.
2. Gateway uploads to MinIO, calculates SHA256, optionally enriches (if image), extracts text, and forwards a unified payload with `attachments` array containing file descriptors.
3. Catalog deduplicates files by SHA, links them to the document (`document_files`), and records facet overrides (`has_attachments`, `attachment_count`).
4. Response includes `file_sha256`, `object_key`, `extraction_status`, plus standard ingestion response fields (`submission_id`, `doc_id`, `external_id`, `version_number`, `thread_id`, `file_ids`, `duplicate`).

### 2.3 Versioning Existing Documents
1. PATCH `catalog /v1/catalog/documents/{doc_id}/version` with fields to change (`text`, `metadata`, `content_timestamp`, new attachments, etc.).
2. Catalog clones the document, increments `version_number`, marks previous version inactive, and rebuilds chunks.
3. Response includes new `doc_id`, `previous_version_id`, `version_number`, updated `file_ids`, and status.
4. Gateway will surface the active version when queried by external ID.

### 2.4 Running Hybrid Search
1. GET `gateway /v1/search?q=dinner&has_attachments=true&source_type=imessage&person=%2B15085551212&start_date=2023-01-01&end_date=2023-12-31`.
2. Gateway forwards the filters to search service (which queries Postgres chunks + Qdrant).
3. Response includes hits with facets (`source_type`, `has_attachments`, `person`), metadata (timeline, people, attachments), and ranking scores.
4. Set `thread_id=<uuid>&context_window=5` to include neighbouring messages for thread context.

### 2.5 Ask / Summarise
1. POST `gateway /v1/ask` with `{ "query": "What invoices did Alex send?", "k": 5 }`.
2. Gateway runs a search, selects top `k` hits, and returns a summary plus citations.
3. Each citation references `document_id`, `chunk_id`, `score`.

### 2.6 Catalog Context Insights
1. GET `gateway /v1/context/general` (requires `CATALOG_TOKEN` if enforced).
2. Catalog responds with `total_threads`, `total_messages` (active documents), `last_message_ts`, top threads, and recent highlights (with people + timeline data).

### 2.7 Monitoring Embeddings
1. Embedding worker logs `embedding_job_completed` for each chunk.
2. Query `GET /v1/catalog/submissions/{submission_id}` or `/v1/catalog/documents/{doc_id}/status` to inspect chunk counts and status (`pending`, `processing`, `embedded`).
3. If `embedding_status='failed'`, reset to `pending` manually or re-run version creation.

## 3. Collector Workflows

### 3.1 iMessage Collector
1. Install dependencies (`pip install -r local_requirements.txt`), ensure `AUTH_TOKEN` or `CATALOG_TOKEN` is set.
2. Run `python scripts/collectors/collector_imessage.py --simulate "hi"` for dry run or omit `--simulate` for live ingest.
3. Collector backs up chat.db, reads new messages, enriches attachments, and posts events to gateway:
   * Payload includes `people` array (sender/recipients with identifier types), thread descriptor, attachments with SHA/enrichment.
   * Version tracker (`~/.haven/imessage_versions.json`) prevents resubmitting identical content.
   * Flags `--disable-images` or environment placeholders tune enrichment behaviour.
4. Logs `skipping_unchanged_version` when dedupe prevents re-ingest.

### 3.2 Local Files Collector
1. Configure watch directory: `python scripts/collectors/collector_localfs.py --watch ~/Documents --move-to ~/Processed`.
2. Collector hashes files, skips duplicates, enriches images, and sends metadata to `/v1/ingest/file`.
3. Metadata contains mtime/ctime, tags, enrichment output; attachments stored in MinIO with SHA keys.

### 3.3 Contacts Collector
1. Install macOS-specific dependencies: `pip install -r local_requirements.txt`.
2. Run `python scripts/collectors/collector_contacts.py --once` (requires GUI permission for Contacts).
3. Collector posts batches to `catalog/contacts/ingest`; gateway transforms each entry into a `contact` document with structured metadata (`metadata.contact`) and phone/email identifiers in the `people` array.
4. Deletions trigger catalog document removal; change tokens persist in `source_change_tokens` so incremental sync resumes gracefully.

## 4. Backfill & Enrichment

* `python scripts/backfill_image_enrichment.py --use-chat-db --limit 50` reprocesses image attachments, writing updated enrichment to `files.enrichment` and requeuing chunks.
* Requires gateway (`GATEWAY_URL`) and `AUTH_TOKEN`. For missing files, script records placeholder statistics.

## 5. Operational Tips

| Task | Command / Notes |
| --- | --- |
| Reset schema | `docker compose exec -T postgres psql -U postgres -d haven_v2 -f - < schema/init.sql` |
| Start full stack | `docker compose up --build` (add `COMPOSE_PROFILES=collector` for in-container collector) |
| Inspect ingestion status | `curl -H "Authorization: Bearer $AUTH_TOKEN" http://localhost:8085/v1/ingest/<submission_id>` |
| Check search filters | Use `--simulate` collector runs, query `GET /v1/search` with matching filters |
| Update document version | `curl -X PATCH http://catalog:8081/v1/catalog/documents/<doc_id>/version` with JSON body |
| Retry failed embeddings | Update `chunks` row `embedding_status='pending'` and watch worker logs |

## 6. Troubleshooting

| Issue | Resolution |
| --- | --- |
| Collector posts 409 / duplicate | Message already ingested; version tracker prevents duplicate writes. Clear `imessage_versions.json` if forced re-ingest desired. |
| Attachments missing SHA | Ensure attachments still exist on disk; collectors compute SHA from source path. |
| Search missing facets | Confirm gateway forwards `facets` list and search service logs processed filters. |
| Embedding worker idle | Check for `chunks.embedding_status='pending'`; if none, ingestion finished or errors flagged. |
| Catalog context empty | Ensure collectors ran successfully and gateway forwarded data with `content_timestamp`. |

## 7. Reference Links

* **Schema:** `documentation/SCHEMA_unified_v2.md`
* **Migration Summary:** `documentation/unified_schema_v2_overview.md`
* **Technical Details:** `documentation/technical_reference.md`
* **Collectors:** `scripts/collectors/collector_imessage.py`, `scripts/collectors/collector_localfs.py`, `scripts/collectors/collector_contacts.py`
* **Embedding Worker:** `services/embedding_service/worker.py`

Use this guide alongside the technical reference for detailed API contracts and configuration guidance.
