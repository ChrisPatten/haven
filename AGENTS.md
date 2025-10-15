# Repository Guidelines

## Layout & Ownership
- `services/` houses deployable FastAPI apps and workers: `catalog_api`, `gateway_api`, and `embedding_service`.
- Shared helpers live in `shared/`; reusable domain code (search pipelines, SDK) is packaged under `src/haven/`.
- Infrastructure assets (`compose.yaml`, `Dockerfile`, `openapi.yaml`) and SQL migrations (`schema/`) sit at the root.
- Tests reside in `tests/`, mirroring service names (e.g., `test_gateway_summary.py`).

## Day-to-Day Development
```bash
export AUTH_TOKEN="changeme"      # required by gateway endpoints
docker compose up --build          # start Postgres, Qdrant, and API stack

# Postgres applies schema/init.sql on first boot; rerun manually if needed
docker compose exec -T postgres psql -U postgres -d haven -f - < schema/init.sql

python scripts/collectors/collector_imessage.py [--simulate "Hi"]

# macOS Contacts collector (pyobjc requirement)
pip install -r local_requirements.txt
python scripts/collectors/collector_contacts.py
```
- Use `requirements.txt` with a Python 3.11 virtualenv when running services outside Docker.
- To run the collector in Docker, enable the optional profile: `COMPOSE_PROFILES=collector docker compose up --build collector`.

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

