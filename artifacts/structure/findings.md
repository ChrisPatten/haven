# Structural Findings

## Executive Summary
- **Key risks mitigated**: Gateway now defaults to the correct catalog port, collector profile points at the gateway proxy, dependency guards align with extras, and embedding defaults match across services.
- **High-ROI fixes applied**: Removed unused compose variables, consolidated collector service naming/env, corrected dependency assertions, pruned cached bytecode, and dropped the broken `gateway-api` console script.
- **Deferred items**: Gateway still exposes a bespoke `/v1/doc/{doc_id}` instead of relying on the catalog API; consider consolidating after downstream consumers are ready.

## Resolved Items
- Gateway catalog base URL default updated to `http://catalog:8081`, matching compose (`services/gateway_api/app.py:23`, `compose.yaml:42`).
- Collector compose profile renamed to `collector` and now exports `CATALOG_ENDPOINT` pointing at the gateway proxy (`compose.yaml:63-71`, `services/collector/collector_imessage.py:31`).
- Catalog, gateway, and embedding worker share the `BAAI/bge-m3` default and `haven_chunks` collection, ensuring consistent metadata (`services/catalog_api/app.py:25`, `services/embedding_worker/worker.py:23`, `compose.yaml:45-84`).
- Dependency guards now warn about the correct optional extras for each service (`services/gateway_api/app.py:22`, `src/haven/search/app.py:11`).
- Removed the unused `VECTOR_BACKEND` environment variable and the dead `gateway-api` console script (`compose.yaml:25`, `pyproject.toml:47-49`).
- Deleted tracked `__pycache__` directories to keep the tree clean.

## Remaining Observations
- Gateway’s `/v1/doc/{doc_id}` duplicates catalog functionality without caching; align the surface area when clients can rely on catalog (`services/gateway_api/app.py:162`).
- Add `docker compose config` (and optional lint) to validation pipelines for infra regressions.
- Catalog and embedding worker lack automated test coverage; add targeted tests under `tests/`.

