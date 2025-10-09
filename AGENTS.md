# Repository Guidelines

## Project Structure & Module Organization
- Core services live under `services/`: `catalog_api`, `gateway_api`, `embedding_worker`, and the `collector` CLI each expose a FastAPI app or worker entrypoint.
- Shared helpers such as database sessions and logging live in `shared/`; reusable domain code (search pipelines, SDK) is packaged in `src/haven/` for import.
- Integration assets sit in `compose.yaml`, `Dockerfile`, and `openapi.yaml`; SQL migrations live in `schema/`.
- Python tests reside in `tests/` and mirror service names (e.g., `test_gateway_summary.py`).

## Build, Test, and Development Commands
```bash
export AUTH_TOKEN="changeme"      # required by gateway endpoints
docker compose up --build          # start Postgres, Qdrant, and API stack
# Apply the Postgres schema from within the running Postgres container so the host doesn't need a local psql client.
# Start the compose stack first (this will create the `postgres` service):
#
#   docker compose up -d postgres
#
# Then apply the SQL from the host by streaming it into the container. Examples:
#
# Using docker compose exec (preferred when the service is healthy):
#
#   docker compose exec -T postgres psql -U postgres -d haven -f - < schema/catalog_mvp.sql
#
# Using docker exec (when you know the container id/name):
#
#   docker exec -i <container_name_or_id> psql -U postgres -d haven -f - < schema/catalog_mvp.sql
#
# Alternatively, copy the file into the container and run psql there:
#
#   docker cp schema/catalog_mvp.sql $(docker compose ps -q postgres):/tmp/catalog_mvp.sql
#   docker compose exec postgres psql -U postgres -d haven -f /tmp/catalog_mvp.sql

# If using contacts support, apply the contacts schema additions as well (inside the container):
docker compose exec -T postgres psql -U postgres -d haven -f - < schema/contacts.sql
# If using contacts support, apply the contacts schema additions as well:
psql postgresql://postgres:postgres@localhost:5432/haven -f schema/contacts.sql
python services/collector/collector_imessage.py [--simulate "Hi"]

# On macOS you can also run the Contacts collector (requires pyobjc):
pip install -r local_requirements.txt
python services/collector/collector_contacts.py
```
Use `requirements.txt` with a Python 3.11 virtualenv when running services outside Docker. To run the collector via Docker, enable the optional profile: `COMPOSE_PROFILES=collector docker compose up --build collector`.

## Coding Style & Naming Conventions
- Python 3.11, 4-space indentation, and type hints are expected across services.
- Keep modules small and align new files with existing package layout under `services/` or `shared/`.
- Run `ruff check .` and `black .` before committing; configure editors to save in UTF-8 without trailing whitespace. Fix existing lint debt opportunistically.
- Prefer `snake_case` for modules/functions, `PascalCase` for classes, and descriptive FastAPI route names.

## Testing Guidelines
- Unit tests belong beside peers in `tests/test_*.py`; mirror module names and cover edge cases.
- Execute `pytest` plus `mypy services shared` for type gating; add fixtures in `tests/conftest.py` when sharing setup.
- For end-to-end smoke tests, run the collector with `--simulate` and query the gateway search endpoint.

## Commit & Pull Request Guidelines
- History is currently empty; use concise, imperative commits such as `feat: add embeddings worker retry`.
- Reference related issues in the body, list validation commands executed, and note schema or API changes explicitly.
- Pull requests should summarize the user impact, link design docs if relevant, and include screenshots or curl transcripts for API-facing changes.

## Environment & Security Notes
- Treat `~/Library/Messages/chat.db` and `~/.haven/*` as sensitive; never commit personal data.
- Store auth tokens in local env vars or `.env` files excluded from version control.
- Services assume localhost networking; avoid exposing ports publicly without additional authentication.

### Recent staged changes

Staged changes introduce image enrichment for the iMessage collector and supporting developer tooling:

- The iMessage collector (`services/collector/collector_imessage.py`) now enriches image attachments: OCR extraction, entity detection, and optional captioning via an Ollama vision model. Extracted captions and OCR text are appended to message chunks and stored in message attrs where applicable.
- A native helper `services/collector/imdesc.swift` was added to perform Vision-based OCR and entity extraction on macOS. A build helper `scripts/build-imdesc.sh` and a test utility `scripts/test_imdesc_ollama.py` were also added.
- Unit tests were extended (`tests/test_collector_imessage.py`) to cover the enrichment code and cache behavior.

These features are implemented to degrade gracefully when native binaries or external captioning services are not present.
