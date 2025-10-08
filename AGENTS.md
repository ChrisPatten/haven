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
psql postgresql://postgres:postgres@localhost:5432/haven -f schema/catalog_mvp.sql
python services/collector/collector_imessage.py [--simulate "Hi"]
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
