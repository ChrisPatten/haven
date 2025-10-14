# Repository Guidelines

## Layout & Ownership
- `services/` houses deployable FastAPI apps and workers: `catalog_api`, `gateway_api`, `embedding_worker`, and the `collector` CLI.
- Shared helpers live in `shared/`; reusable domain code (search pipelines, SDK) is packaged under `src/haven/`.
- Infrastructure assets (`compose.yaml`, `Dockerfile`, `openapi.yaml`) and SQL migrations (`schema/`) sit at the root.
- Tests reside in `tests/`, mirroring service names (e.g., `test_gateway_summary.py`).

## Day-to-Day Development
```bash
export AUTH_TOKEN="changeme"      # required by gateway endpoints
docker compose up --build          # start Postgres, Qdrant, and API stack

# Apply the Postgres schema from the running container (preferred)
docker compose exec -T postgres psql -U postgres -d haven -f - < schema/catalog_mvp.sql

# Optional contacts schema additions
docker compose exec -T postgres psql -U postgres -d haven -f - < schema/contacts.sql

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
- A native Swift helper (`scripts/collectors/imdesc.swift`) plus `scripts/build-imdesc.sh` supports macOS Vision OCR.
- `tests/test_collector_imessage.py` covers enrichment flows and cache behavior.

### Collector: disable image handling

- New CLI flag for the iMessage collector: `--no-images` (or `--disable_images` in the args namespace).
- When set, the collector will skip image enrichment (OCR/captioning/entity extraction) and instead replace image attachments with the text "[image]" in the message content/chunks. This is useful for low-resource environments or when privacy requires skipping binary processing.

Example:

```bash
python scripts/collectors/collector_imessage.py --no-images
```
