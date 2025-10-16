# Repository Guidelines

## Architecture: Host vs. Container Execution

**IMPORTANT**: Haven uses a hybrid architecture:

### **Services (Containerized)**
The following run inside Docker containers via `docker compose`:
- **gateway_api** (`:8085`) – Public HTTP API for ingestion, search, and retrieval
- **catalog_api** (`:8081`) – Internal API for document/thread persistence (not exposed to host)
- **search_service** (`:8080`) – Internal hybrid search engine (not exposed to host)
- **embedding_service** – Background worker processing chunks (no HTTP interface)
- **postgres** (`:5432`) – Database server
- **qdrant** (`:6333`) – Vector database
- **minio** (`:9000/:9001`) – Object storage for file attachments

### **Collectors (Host Python Environment)**
The following run on your **host machine** (macOS) using a local Python 3.11+ virtualenv:
- `scripts/collectors/collector_imessage.py` – Reads `~/Library/Messages/chat.db`, posts to gateway API
- `scripts/collectors/collector_localfs.py` – Watches filesystem, uploads files via gateway API
- `scripts/collectors/collector_contacts.py` – Reads macOS Contacts.app, posts to gateway API
- `scripts/backfill_image_enrichment.py` – Backfill utility, calls gateway API

**Why this split?**
- Collectors need **host filesystem access** (`~/Library/Messages/`, `~/Documents/`, etc.)
- Collectors need **macOS-specific APIs** (Contacts.app via pyobjc, native Vision framework)
- Services need **network isolation** and **reproducible deployment** (Docker)

### **Interacting with Services**

There are **only two ways** to interact with containerized services:

#### Option 1: Via Gateway API (Recommended)
All external interactions should go through the gateway on `http://localhost:8085`:
```bash
# Collectors automatically use this
export AUTH_TOKEN="changeme"
export GATEWAY_URL="http://localhost:8085"
python scripts/collectors/collector_imessage.py

# Manual API calls
curl -H "Authorization: Bearer $AUTH_TOKEN" \
  "http://localhost:8085/v1/search?q=dinner"
```

#### Option 2: Exec into Container (Debugging/Admin)
For direct service interaction or database queries:
```bash
# Run commands inside the postgres container
docker compose exec -T postgres psql -U postgres -d haven_v2 -f - < schema/init.sql
docker compose exec postgres psql -U postgres -d haven_v2 -c "SELECT COUNT(*) FROM documents;"

# Run Python commands inside the gateway container
docker compose exec gateway python -c "from shared.db import get_connection; print('ok')"

# View embedding worker logs
docker compose logs -f embedding_service

# Restart a specific service
docker compose restart catalog
```

**Never** try to run service code directly on your host machine for production workflows – dependencies, database connections, and network assumptions differ.

## Layout & Ownership
- `services/` houses deployable FastAPI apps and workers: `catalog_api`, `gateway_api`, and `embedding_service`.
- Shared helpers live in `shared/`; reusable domain code (search pipelines, SDK) is packaged under `src/haven/`.
- Infrastructure assets (`compose.yaml`, `Dockerfile`, `openapi.yaml`) and SQL migrations (`schema/`) sit at the root.
- Tests reside in `tests/`, mirroring service names (e.g., `test_gateway_summary.py`).

## Day-to-Day Development

### Starting Services (Containerized)
```bash
export AUTH_TOKEN="changeme"      # required by gateway endpoints
docker compose up --build          # start all services (Postgres, Qdrant, APIs)

# Postgres applies schema/init.sql on first boot; rerun manually if needed
docker compose exec -T postgres psql -U postgres -d haven_v2 -f - < schema/init.sql

# Optional: run collector inside Docker (not recommended, use host-based instead)
COMPOSE_PROFILES=collector docker compose up --build collector
```

### Running Collectors (Host Machine)
Collectors run on your **host macOS system** with a local Python environment:

```bash
# Create and activate a Python 3.11+ virtualenv
python3.11 -m venv env
source env/bin/activate
pip install -r requirements.txt

# Run iMessage collector (reads ~/Library/Messages/chat.db)
export AUTH_TOKEN="changeme"
export GATEWAY_URL="http://localhost:8085"  # gateway running in Docker
python scripts/collectors/collector_imessage.py [--simulate "Hi"]

# Run macOS Contacts collector (requires pyobjc and Contacts.app permission)
pip install -r local_requirements.txt
python scripts/collectors/collector_contacts.py

# Run local filesystem collector
python scripts/collectors/collector_localfs.py --watch ~/Documents
```

**Key Points:**
- Collectors communicate with services **only via the gateway API** on `localhost:8085`
- Collectors have direct filesystem access to your macOS home directory
- Use `requirements.txt` for host Python dependencies (includes API clients, not service code)
- Services run in Docker and are accessed via HTTP APIs or container exec commands

## Coding Style & Naming
- Python 3.11, 4-space indentation, and type hints across services.
- Prefer `snake_case` for modules/functions, `PascalCase` for classes.
- Run `ruff check .` and `black .` before committing; fix existing lint debt opportunistically.
- Keep modules scoped and align new files with existing package layout.

## Testing & Quality Gates
- Place unit tests beside peers in `tests/test_*.py`; mirror module names and cover edge cases.
- Execute `pytest` plus `mypy services shared` before shipping; add fixtures in `tests/conftest.py` for shared setup.
- For end-to-end smoke tests, run the collector with `--simulate` and query the gateway search endpoint.

## Environment & Security
- Treat `~/Library/Messages/chat.db` and `~/.haven/*` as sensitive; never commit personal data.
- Store auth tokens in env vars or `.env` files excluded from version control.
- Services assume localhost networking; avoid exposing ports publicly without additional authentication.

## Recent Updates
- iMessage collector enriches image attachments with OCR, entity detection, and optional Ollama-powered captioning.
- Image enrichment logic is now in `shared/image_enrichment.py` for reusability across collectors.
- A native Swift helper (`scripts/collectors/imdesc.swift`) plus `scripts/build-imdesc.sh` supports macOS Vision OCR.
- `tests/test_collector_imessage.py` covers enrichment flows and cache behavior.

### Collector: Image Handling Configuration

**Disable image handling:**
- CLI flag: `--no-images` (or `--disable_images` in the args namespace)
- When set, the collector will skip image enrichment (OCR/captioning/entity extraction) and replace image attachments with placeholder text

**Configurable placeholder text:**
- `IMAGE_PLACEHOLDER_TEXT`: Text to use when image enrichment is disabled or fails (default: `"[image]"`)
- `IMAGE_MISSING_PLACEHOLDER_TEXT`: Text to use when image file is not found on disk (default: `"[image not available]"`)

**Image enrichment only happens if:**
1. `--no-images` flag is NOT set
2. Image file exists on disk at the resolved path
3. Image file can be successfully copied to temp directory
4. Enrichment process completes without exceptions

Example:

```bash
# Disable image handling entirely
python scripts/collectors/collector_imessage.py --no-images

# Customize placeholder text
export IMAGE_PLACEHOLDER_TEXT="📷"
export IMAGE_MISSING_PLACEHOLDER_TEXT="[attachment deleted]"
python scripts/collectors/collector_imessage.py
```

## Backfilling Image Enrichment

If you've already ingested messages before image enrichment was enabled, you can backfill enrichment data for existing messages using the backfill script. This script:

1. Queries the gateway API for documents with attachments
2. Checks if image files still exist on disk
3. Enriches images with OCR, captions, and entity detection
4. Updates documents via the gateway API
5. Automatically triggers re-embedding with the new enriched content

**Prerequisites:**
- Gateway API must be running at `GATEWAY_URL` (default: `http://localhost:8085`)
- `AUTH_TOKEN` environment variable must be set
- Image attachment files must still exist at their original paths in `~/Library/Messages/Attachments/`

**Usage:**

```bash
export AUTH_TOKEN="changeme"
export GATEWAY_URL="http://localhost:8085"  # optional, defaults to localhost:8085

# Dry run to see what would be updated (recommended first step)
python scripts/backfill_image_enrichment.py --dry-run --limit 10

# For messages collected without attachment metadata, use --use-chat-db
# This queries the chat.db backup to get attachment file paths
python scripts/backfill_image_enrichment.py --dry-run --limit 10 --use-chat-db

# Process the first 50 documents with images
python scripts/backfill_image_enrichment.py --limit 50 --use-chat-db

# Process all documents with images (batch size 50)
python scripts/backfill_image_enrichment.py --use-chat-db

# Custom batch size for processing
python scripts/backfill_image_enrichment.py --batch-size 25 --use-chat-db
```

**Output:**
The script outputs statistics at completion including:
- Documents scanned and updated
- Images found vs missing on disk
- Images already enriched vs newly enriched
- Chunks re-queued for embedding
- Any errors encountered during processing

**Note:** The embedding service will automatically pick up re-queued chunks and generate new embeddings that include the enriched image content (captions, OCR text, entities).

