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

### 2.2 Batch Ingestion
1. POST `gateway /v1/ingest:batch` with `{ "documents": [ ... ] }`. The gateway reuses the same preparation pipeline as the single-document route but derives a deterministic batch idempotency key so retries remain safe.
2. Gateway forwards the payload to `catalog /v1/catalog/documents:batch`, which creates an `ingest_batches` record, processes each document (continuing on partial failure), and forwards all successful documents to search in a single `abatch_upsert` call.
3. Response includes `batch_id`, `batch_status` (`submitted`, `processing`, `completed`, `partial`, `failed`), aggregate counts, and per-document results (`status_code`, ingestion response, or error envelope).
4. Collectors can continue to call `/v1/ingest` for single documents; the gateway only switches to the batch endpoint when more than one document is supplied.

### 2.3 Ingesting Files
1. POST multipart to `gateway /v1/ingest/file` with `meta` JSON (path, mtime, optional tags) and binary `upload`.
2. Gateway uploads to MinIO, calculates SHA256, optionally enriches (if image), extracts text, and forwards a unified payload with `attachments` array containing file descriptors.
3. Catalog deduplicates files by SHA, links them to the document (`document_files`), and records facet overrides (`has_attachments`, `attachment_count`).
4. Response includes `file_sha256`, `object_key`, `extraction_status`, plus standard ingestion response fields (`submission_id`, `doc_id`, `external_id`, `version_number`, `thread_id`, `file_ids`, `duplicate`).

### 2.4 Versioning Existing Documents
1. PATCH `catalog /v1/catalog/documents/{doc_id}/version` with fields to change (`text`, `metadata`, `content_timestamp`, new attachments, etc.).
2. Catalog clones the document, increments `version_number`, marks previous version inactive, and rebuilds chunks.
3. Response includes new `doc_id`, `previous_version_id`, `version_number`, updated `file_ids`, and status.
4. Gateway will surface the active version when queried by external ID.

### 2.5 Running Hybrid Search
1. GET `gateway /v1/search?q=dinner&has_attachments=true&source_type=imessage&person=%2B15085551212&start_date=2023-01-01&end_date=2023-12-31`.
2. Gateway forwards the filters to search service (which queries Postgres chunks + Qdrant).
3. Response includes hits with facets (`source_type`, `has_attachments`, `person`), metadata (timeline, people, attachments), and ranking scores.
4. Set `thread_id=<uuid>&context_window=5` to include neighbouring messages for thread context.

### 2.6 Ask / Summarise
1. POST `gateway /v1/ask` with `{ "query": "What invoices did Alex send?", "k": 5 }`.
2. Gateway runs a search, selects top `k` hits, and returns a summary plus citations.
3. Each citation references `document_id`, `chunk_id`, `score`.

### 2.7 Catalog Context Insights
1. GET `gateway /v1/context/general` (requires `CATALOG_TOKEN` if enforced).
2. Catalog responds with `total_threads`, `total_messages` (active documents), `last_message_ts`, top threads, and recent highlights (with people + timeline data).

### 2.8 Monitoring Embeddings
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
1. The macOS Contacts collector runs as part of Haven.app.
2. **Haven.app Method (Recommended)**: Use the Collectors window (`⌘2`) in Haven.app, select Contacts collector, and click "Run".
3. **VCF Import**: Configure VCF import directory in Settings (`⌘,`) under Contacts settings.
4. Contacts are transformed into unified person records in the `people` table with normalized identifiers.
5. The PeopleRepository handles deduplication and merging based on phone/email overlap.
6. Change tokens persist in `source_change_tokens` for incremental sync.

**Python CLI Collector**: `scripts/collectors/collector_contacts.py` is available for environments without Haven.app.

### 3.4 People Normalization
1. All contacts and message participants are normalized into the `people` table.
2. Phone numbers normalized to E.164 format, emails to lowercase.
3. `PeopleResolver` enables lookup of person records by identifier:
   ```python
   from shared.people_repository import PeopleResolver, IdentifierKind
   resolver = PeopleResolver(conn, default_region="US")
   person = resolver.resolve(IdentifierKind.PHONE, "+1 555 123 4567")
   ```
4. `document_people` junction table links documents to people with roles (sender, recipient, participant, mentioned, contact).
5. Gateway `/search/people` endpoint enables full-text search across normalized contacts.

### 3.5 Relationship Intelligence
1. The `crm_relationships` table stores directional relationship strength scores.
2. Background job computes features from message history:
   - Message frequency (30d, 90d)
   - Recency (days since last contact)
   - Thread diversity
   - Reply latency
   - Attachment exchange
3. Scores computed using weighted combination of recency, frequency, and engagement signals.
4. Self-person detection identifies the user's person record for relationship calculations.
5. Query top relationships:
   ```sql
   SELECT person_id, display_name, score, last_contact_at
   FROM crm_relationships cr
   JOIN people p ON cr.person_id = p.person_id
   WHERE cr.self_person_id = $1
   ORDER BY score DESC LIMIT 10;
   ```

## 4. People and Relationship Workflows

### 4.1 Searching for People
1. GET `gateway /search/people?q=john&limit=20` to search across display names, emails, phone numbers.
2. Response includes person records with identifiers, addresses, and metadata.
3. Use `offset` parameter for pagination.

### 4.2 Viewing Relationship Strength
1. Relationship scores updated periodically by background job.
2. Query `crm_relationships` to see top contacts ranked by score.
3. `edge_features` JSONB field contains raw metrics for analysis.
4. Filter by `decay_bucket` for time-windowed queries (recent contacts, active relationships).

### 4.3 Self-Person Configuration
1. System detects self-person automatically based on message patterns.
2. Manual override via `system_settings` table: `UPDATE system_settings SET value = '{"self_person_id": "<uuid>"}' WHERE key = 'self_person'`.
3. Self-person ID used as subject for all relationship scoring calculations.

## 5. Backfill & Enrichment

* `python scripts/backfill_image_enrichment.py --use-chat-db --limit 50` reprocesses image attachments, writing updated enrichment to `files.enrichment` and requeuing chunks.
* Requires gateway (`GATEWAY_URL`) and `AUTH_TOKEN`. For missing files, script records placeholder statistics.

## 6. Operational Tips

| Task | Command / Notes |
| --- | --- |
| Reset schema | `docker compose exec -T postgres psql -U postgres -d haven_v2 -f - < schema/init.sql` |
| Start full stack | `docker compose up --build` (add `COMPOSE_PROFILES=collector` for in-container collector) |
| Inspect ingestion status | `curl -H "Authorization: Bearer $AUTH_TOKEN" http://localhost:8085/v1/ingest/<submission_id>` |
| Check search filters | Use `--simulate` collector runs, query `GET /v1/search` with matching filters |
| Update document version | `curl -X PATCH http://catalog:8081/v1/catalog/documents/<doc_id>/version` with JSON body |
| Retry failed embeddings | Update `chunks` row `embedding_status='pending'` and watch worker logs |
| Search people | `curl "http://localhost:8085/search/people?q=john"` |
| View top relationships | Query `crm_relationships` joined with `people` table, order by `score DESC` |

## 7. Troubleshooting

| Issue | Resolution |
| --- | --- |
| Collector posts 409 / duplicate | Message already ingested; version tracker prevents duplicate writes. Clear `imessage_versions.json` if forced re-ingest desired. |
| Attachments missing SHA | Ensure attachments still exist on disk; collectors compute SHA from source path. |
| Search missing facets | Confirm gateway forwards `facets` list and search service logs processed filters. |
| Embedding worker idle | Check for `chunks.embedding_status='pending'`; if none, ingestion finished or errors flagged. |
| Catalog context empty | Ensure collectors ran successfully and gateway forwarded data with `content_timestamp`. |
| People not resolving | Check `person_identifiers` table for canonical format; phone numbers must be E.164, emails lowercase. |
| Relationship scores stale | Run relationship feature aggregation job manually or check scheduled job logs. |

## 8. Reference Links

* **Schema:** `documentation/SCHEMA_unified_v2.md`
* **Migration Summary:** `documentation/unified_schema_v2_overview.md`
* **Technical Details:** `documentation/technical_reference.md`
* **Collectors:** `scripts/collectors/collector_imessage.py`, `scripts/collectors/collector_localfs.py`, `scripts/collectors/collector_contacts.py`
* **Embedding Worker:** `services/embedding_service/worker.py`

Use this guide alongside the technical reference for detailed API contracts and configuration guidance.
