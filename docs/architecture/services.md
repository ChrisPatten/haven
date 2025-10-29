# Services

Each Haven service plays a specific role in the ingestion → enrichment → search pipeline. The table below summarises the runtime footprint before diving into per-service details.

| Service | Port | Tech | Responsibilities |
| --- | --- | --- | --- |
| Gateway API | 8085 | FastAPI | Public ingestion/search surface, auth, orchestration |
| Catalog API | 8081 | FastAPI | Document + thread persistence, versioning, ingest status |
| Search Service | 8080 | FastAPI + Typer | Hybrid lexical/vector queries backed by Qdrant |
| Embedding Worker | n/a | Python worker | Generates embeddings for pending chunks |
| HostAgent | 7090 (localhost) | Swift | macOS-native collectors, OCR, FS watch, link resolver |

## Gateway API
- **Responsibilities**: Validate payloads (`/v1/ingest`, `/v1/ingest:batch`, `/v1/ingest/file`), compute idempotency keys, forward documents to Catalog, broker access to search, and expose `ask` summarisation.
- **Authentication**: Bearer tokens via `Authorization: Bearer <token>`.
- **Integrations**: Reads MinIO credentials for file uploads, proxies requests to Catalog and Search, communicates with HostAgent (`host.docker.internal:7090`).
- **Observability**: `/v1/healthz`, structured logs keyed by `submission_id`, metrics covering request timings.

## Catalog API
- **Responsibilities**: Persist documents, threads, files, and chunk metadata. Track ingest submissions, state transitions, and expose document lifecycle endpoints.
- **Database**: Postgres schema defined in `schema/init.sql` with GIN indexes for intent JSONB and partial indexes for relevance.
- **APIs**: `/v1/catalog/documents`, `/v1/catalog/embeddings`, status endpoints for ingestion, and contacts import/export routes.
- **Reliability**: Transactions wrap ingestion so documents, files, and threads remain consistent.

## Search Service
- **Responsibilities**: Expose `GET /v1/search` with filters, facets, and timeline aggregations; support ingestion routes for custom clients.
- **Data Stores**: Qdrant for vectors, Postgres views for metadata joins.
- **Features**: Hybrid scoring across text and vector similarities, optional summarisation, timeline queries, and context windows.
- **Operations**: Runs inside Docker with environment-configurable Qdrant hosts and embedding dimensions.

## Embedding Worker
- **Responsibilities**: Poll `chunks` with `embedding_status='pending'`, generate vectors (default `BAAI/bge-m3`), and push results via `/v1/catalog/embeddings`.
- **Batching**: Controlled via `WORKER_BATCH_SIZE` and `WORKER_POLL_INTERVAL` environment variables.
- **Failure Handling**: Marks chunks as `failed` with error context; operators can reset to `pending` for retries.
- **Integration**: Optional Ollama proxy for local embeddings; respects `OLLAMA_BASE_URL` and related settings.

## HostAgent
- **Responsibilities**: macOS-native API for:
  - `POST /v1/collectors/imessage:run` and future collectors
  - Vision OCR (`/v1/ocr`) and face detection
  - Filesystem watches with presigned upload support
- **Security**: Requires Full Disk Access (Messages database) and Contacts permission. Authenticated via `x-auth` header.
- **Deployment**: Installed via `make install` / `make launchd`; logs at `~/Library/Logs/Haven/hostagent.log`.
- **Extensibility**: Modular configuration enables/disable collectors; includes LinkResolver CLI for “View Online” links.

## Collectors and Utilities
- **Python Collectors**: iMessage, LocalFS, and Contacts scripts remain for environments without HostAgent. They mirror the same ingestion contracts.
- **Backfill Scripts**: `scripts/backfill_image_enrichment.py` reprocesses historical attachments with OCR/captioning.
- **Docs Hooks**: `scripts/docs_hooks.py` ensures OpenAPI specs are available during MkDocs builds.

_Adapted from `documentation/technical_reference.md`, `README.md`, and `AGENTS.md`._
