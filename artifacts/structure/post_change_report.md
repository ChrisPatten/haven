# Post-Change Report

## Summary of Changes
- Corrected gateway catalog default to `http://catalog:8081` and aligned catalog/worker embedding defaults with the compose stack (`services/gateway_api/app.py:30`, `services/catalog_api/app.py:25`, `services/embedding_worker/worker.py:23`).
- Renamed the compose collector service, rewired it to use `CATALOG_ENDPOINT`, and dropped the unused `VECTOR_BACKEND` variable (`compose.yaml:20-88`).
- Swapped optional dependency guard rails and removed the broken `gateway-api` console script (`services/gateway_api/app.py:22`, `src/haven/search/app.py:11`, `pyproject.toml:47-49`).
- Pruned cached bytecode directories (`src/haven/__pycache__`, etc.) to keep the workspace clean.

## Validation
- `pytest -q` → **pass** (17 passed, 2 warnings about FastAPI `on_event`).
- `python -m compileall .` → **pass**.
- `docker compose config` → **pass** (collector profile appears when enabled via `COMPOSE_PROFILES=collector`).
- `ruff check .` → **fail** (pre-existing lint issues such as unused imports in collector/search modules and redefinition warnings; see command output above).
- `black --check .` → **fail** (project not yet formatted; 22 files would be reformatted).
- `mypy services shared` → **fail** (existing type issues: untyped third-party stubs, unchecked imports for `haven.search.*`, and loose typing in `shared/context.py`).

No new lint/type regressions were introduced by these changes; failures match the prior baseline and are noted for future cleanup.
