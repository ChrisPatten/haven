# Services

Each Haven service plays a specific role in the ingestion → enrichment → search pipeline. The table below summarises the runtime footprint before diving into per-service details.

| Service | Port | Tech | Responsibilities |
| --- | --- | --- | --- |
| Gateway API | 8085 | FastAPI | Public ingestion/search surface, auth, orchestration |
| Catalog API | 8081 | FastAPI | Document + thread persistence, versioning, ingest status |
| Search Service | 8080 | FastAPI + Typer | Hybrid lexical/vector queries backed by Qdrant |
| Embedding Worker | n/a | Python worker | Generates embeddings for pending chunks |
| Haven.app | n/a | Swift | macOS-native collectors, OCR, FS watch (runs collectors directly) |

## Gateway API
- **Responsibilities**: Validate v2 envelopes (`/v2/ingest/document`, `/v2/ingest/person`, optional `/v2/ingest:batch`), compute idempotency keys, normalize timestamps, forward payloads unchanged to Catalog v2, broker access to search, and expose `ask` summarisation.
- **Authentication**: Bearer tokens via `Authorization: Bearer <token>`.
- **Integrations**: Proxies requests to Catalog and Search. Binary file uploads are not used; images/files are represented in `metadata.attachments` and transmitted as metadata only.
- **Observability**: `/v1/healthz`, structured logs keyed by `submission_id`, metrics covering request timings.
- **Compatibility**: Continues to accept legacy v1 ingestion (`/v1/ingest`, `/v1/ingest:batch`) and internally adapts to v2 envelopes during migration. The legacy `/v1/ingest/file` route is deprecated.

## Catalog API
- **Responsibilities**: Persist documents, threads, and chunk metadata. Track ingest submissions, state transitions, and expose document lifecycle endpoints. Normalize people (`/v2/catalog/people`), resolve identifiers, and maintain relationships. Files are no longer first-class rows; attachment/file data lives in `documents.metadata.attachments`.
- **Database**: Postgres schema defined in `schema/init.sql` with GIN indexes for intent JSONB and partial indexes for relevance.
- **APIs**: `/v2/catalog/documents`, `/v2/catalog/people`, `/v1/catalog/embeddings`, status endpoints for ingestion, and people resolution endpoints.
- **Reliability**: Transactions wrap ingestion so documents, files, threads, and people remain consistent. Savepoints protect per-person operations in batch contact imports.

## Search Service
- **Responsibilities**: Expose `GET /v1/search` with filters, facets, and timeline aggregations; support ingestion routes for custom clients; provide people search via `/search/people`.
- **Data Stores**: Qdrant for vectors, Postgres views for metadata joins, `people` table for contact search.
- **Features**: Hybrid scoring across text and vector similarities, optional summarisation, timeline queries, context windows, and full-text people search.
- **Operations**: Runs inside Docker with environment-configurable Qdrant hosts and embedding dimensions. Relationship scoring jobs can run as scheduled tasks.

## Embedding Worker
- **Responsibilities**: Poll `chunks` with `embedding_status='pending'`, generate vectors (default `BAAI/bge-m3`), and push results via `/v1/catalog/embeddings`.
- **Batching**: Controlled via `WORKER_BATCH_SIZE` and `WORKER_POLL_INTERVAL` environment variables.
- **Failure Handling**: Marks chunks as `failed` with error context; operators can reset to `pending` for retries.
- **Integration**: Optional Ollama proxy for local embeddings; respects `OLLAMA_BASE_URL` and related settings.

## Haven.app
- **Responsibilities**: Unified macOS application that runs collectors directly:
  - iMessage collection via direct database access
  - Contacts collection from macOS Contacts.app
  - Local filesystem watching and ingestion
  - Email collection (IMAP and Mail.app)
  - Vision OCR and image enrichment via `EnrichmentOrchestrator`
- **Architecture**: Collectors run directly within the app via Swift APIs (no HTTP server required). Uses `EnrichmentOrchestrator` to coordinate enrichment services (OCR, face detection, entity extraction, captioning).
- **Enrichment**: 
  - `ImageExtractor` and `TextExtractor` modules extract content from HTML/rich text
  - `EnrichmentOrchestrator` coordinates OCR, face detection, entity extraction, and captioning
  - Per-collector enrichment control via `~/.haven/collector_enrichment.plist`
  - Module-level configuration (OCR quality, entity types, etc.) via `hostagent.yaml` advanced settings
- **Security**: Requires Full Disk Access (Messages database), Contacts permission (for contacts collector), Reminders permission (for reminders collector).
- **Deployment**: Built as macOS app bundle; configuration at `~/.haven/hostagent.yaml` and `~/.haven/collector_enrichment.plist`.
- **Extensibility**: Modular collector configuration; native macOS integration for best performance.

## Collectors and Utilities
- **Haven.app Collectors**: Swift-native collectors provide best performance and system integration.
- **Python Collectors**: CLI collectors (`scripts/collectors/`) available for environments without Haven.app. They mirror the same ingestion contracts.
- **Backfill Scripts**: `scripts/backfill_image_enrichment.py` reprocesses historical attachments with OCR/captioning.
- **Docs Hooks**: `scripts/docs_hooks.py` ensures OpenAPI specs are available during MkDocs builds.
- **Relationship Jobs**: `services/search_service/relationship_features.py` computes relationship scores from message history.

_Adapted from `documentation/technical_reference.md` and `README.md`._
