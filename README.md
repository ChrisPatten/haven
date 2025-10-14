# Haven PDP MVP

Haven is a personal data plane that turns local iMessage history into a searchable knowledge base. The minimum viable product ingests conversations, catalogs normalized threads/messages in Postgres, generates semantic embeddings in Qdrant, and exposes hybrid search plus summarization through a FastAPI gateway.

## Documentation Map
- [`documentation/technical_reference.md`](documentation/technical_reference.md) – deep dive on architecture, services, and configuration.
- [`documentation/functional_guide.md`](documentation/functional_guide.md) – user workflows, API behavior, operating runbooks, and troubleshooting.

## Components
- **Collector (CLI / optional compose profile)** – `scripts/collectors/collector_imessage.py` copies `~/Library/Messages/chat.db`, normalizes new messages, enriches image attachments, and posts catalog events to the gateway.
- **Catalog API** – internal FastAPI service that persists threads/messages/chunks, maintains FTS indexes, and tracks embedding status.
- **Embedding Service** – background worker (`services/embedding_service/worker.py`) that polls pending chunks, calls the embedding provider, and upserts vectors into Qdrant.
- **Gateway API (`:8085`)** – public FastAPI surface for hybrid search, summarization, document retrieval, and catalog proxying.
- **Search Service** – FastAPI + Typer service that powers hybrid lexical/vector search and ingestion utilities.
- **OpenAPI Spec** – `openapi.yaml` documents the public gateway surface for external integrations.

## Repository Layout
- `services/` – Deployable FastAPI apps and workers (gateway, catalog, embedding service).
- `scripts/collectors/` – iMessage and Contacts collectors plus the native image description helper.
- `src/haven/` – Installable Python package with search pipelines, SDK, and reusable domain logic.
- `shared/` – Cross-service helpers (logging, Postgres utilities, dependency guards).
- `schema/` – SQL migrations and initialization scripts.
- `documentation/` – Architecture findings, runbooks, and reference guides.
- `tests/` – Pytest suite covering gateway, collector, and search behaviors.

## Prerequisites
- macOS with Python 3.11 (collector) and Docker Desktop (services).
- Access to `~/Library/Messages/chat.db`.
- A bearer token exported as `AUTH_TOKEN` for gateway access.

## Quick Start
```bash
# 1. Start infrastructure and APIs (gateway exposed on :8085)
export AUTH_TOKEN="changeme"
docker compose up --build
# Optional: run the collector container
# COMPOSE_PROFILES=collector docker compose up --build collector
```

```bash
# 2. Initialize the Postgres schema (choose one)
# The postgres service automatically applies schema/init.sql on first boot.
# Re-run manually if you need to reset the database:
docker compose exec -T postgres psql -U postgres -d haven -f - < schema/init.sql
# Alternative: apply from host (requires local psql client)
psql postgresql://postgres:postgres@localhost:5432/haven -f schema/init.sql
```

```bash
# 3. Run the iMessage collector locally
python scripts/collectors/collector_imessage.py
# Simulate a message for end-to-end smoke testing
python scripts/collectors/collector_imessage.py --simulate "Hey can you pay MMED today?"
```

Disable image handling
----------------------

If you'd like to skip image enrichment (OCR, captioning, entity extraction) for performance or privacy reasons, pass the `--no-images` flag. When enabled the collector replaces image attachments with the literal text "[image]" in the message content so the message remains searchable without uploading or processing binaries.

```bash
# Run the collector without processing images
python scripts/collectors/collector_imessage.py --no-images

# Single-run, no images
python scripts/collectors/collector_imessage.py --no-images --once
```

### Contacts Collector (macOS)
```bash
pip install -r local_requirements.txt
export CATALOG_TOKEN="changeme"
python scripts/collectors/collector_contacts.py
```
- Grants Contacts.app permission on first run, exports contacts via pyobjc, and POSTs batches to the gateway ingest proxy.
- Run manually or via cron/launchd to keep entries synced; the collector stores no local cache beyond `~/.haven` progress files.

### Optional Image Enrichment
Image attachments can be enriched with OCR, entity extraction, and captions.

1. Build the native helper (macOS vision OCR + entity detection):
   ```bash
   scripts/build-imdesc.sh
   ```
2. (Optional) Enable captioning via an Ollama vision model:
   - Ensure an Ollama server with a vision-capable model (e.g., `llava`) is running.
   - Export `OLLAMA_API_URL` for the collector and `OLLAMA_BASE_URL` for the embedding service when using a remote server or custom port.
3. The collector falls back gracefully when the helper binary or caption endpoint is unavailable—it logs a warning and continues ingesting messages.

## Configuration Reference
- `AUTH_TOKEN` – bearer token enforced on gateway routes (optional in development).
- `CATALOG_TOKEN` – optional shared secret forwarded by the gateway for catalog ingest/status calls.
- `CATALOG_BASE_URL` – internal URL the gateway uses to reach the catalog (defaults to `http://catalog:8081`).
- `DATABASE_URL` – Postgres DSN; each service overrides this for Docker networking.
- `EMBEDDING_MODEL` – embedding identifier (`BAAI/bge-m3`).
- `QDRANT_URL`, `QDRANT_COLLECTION` – vector store configuration.
- `OLLAMA_ENABLED`, `OLLAMA_API_URL`, `OLLAMA_VISION_MODEL` – configure optional vision captioning for image enrichment.
- `OLLAMA_BASE_URL` – base URL the embedding service uses when calling the embedding provider.
- `WORKER_POLL_INTERVAL`, `WORKER_BATCH_SIZE` – embedding service tuning knobs.
- `COLLECTOR_POLL_INTERVAL`, `COLLECTOR_BATCH_SIZE` – collector scheduling controls for incremental sync.

### Using a .env file

For convenient local development you can create a `.env` in the repository root containing environment variables used by `docker compose` and services. Copy `.env.example` to `.env` and edit values as needed. Example usage:

```bash
# Use the values in .env automatically when running docker compose (docker-compose v2 reads .env by default)
docker compose up --build
```

Notes:
- Keep secrets out of source control for production; `.env` is ignored by the repository's `.gitignore`.
- For macOS local development the Ollama host is often `http://host.docker.internal:11434` to reach a host service from containers.

## Validation
```bash
ruff check .
black --check .
mypy services shared
pytest
```

For end-to-end verification after seeding messages:
```bash
curl -s "http://localhost:8085/v1/search?q=MMED" -H "Authorization: Bearer $AUTH_TOKEN"
```

## Security Notes
- Only the gateway publishes a host port; other services remain on the Docker network.
- Collector stores state in `~/.haven/imessage_collector_state.json` and never uploads raw attachments.
- Treat `~/Library/Messages/chat.db` and `~/.haven/*` as sensitive; they are ignored by git.
- Manage tokens through environment variables or `.env` files excluded from version control.

## Maintenance Tips
- Keep search and embedding service defaults aligned so vector dimensions remain consistent.
- Update Dockerfile entrypoints and compose service settings whenever new services or optional profiles are introduced.
- Refer to the `documentation/` folder for architectural reports and change history.
