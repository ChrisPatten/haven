# Haven Architecture Map

## Compose Services & Entry Points
- **postgres**: `postgres:15` image, initialized with `schema/catalog_mvp.sql`; volume `pg_data`.
- **qdrant**: `qdrant/qdrant:latest`; volume `qdrant_data`.
- **search**: builds from repo root with `SERVICE=search`; entry command `search-service --host 0.0.0.0 --port 8080`; depends on `postgres`, `qdrant`.
- **gateway**: builds from repo root with `SERVICE=gateway`; entry command `uvicorn services.gateway_api.app:app --host 0.0.0.0 --port 8080`; publishes `127.0.0.1:8085`.
- **catalog**: builds with `SERVICE=catalog`; entry `uvicorn services.catalog_api.app:app --host 0.0.0.0 --port 8081`.
- **collector**: optional profile `collector`; runs `python services/collector/collector_imessage.py` and posts to the gateway catalog proxy.
- **embedding_worker**: runs `python services/embedding_worker/worker.py`; long-running poller.

## Python Packages per Service
- **gateway** (`services/gateway_api`): FastAPI app in `app.py`; depends on shared logging/db, `haven.search.sdk.SearchServiceClient`; defines auth token guards and catalog proxy routes.
- **search** (`src/haven/search`): FastAPI app from `app.py`; Typer CLI in `main.py`; subpackages `routes`, `models`, `repository`, `pipeline`, `services`, `sdk`; manages Postgres + Qdrant hybrid search.
- **catalog** (`services/catalog_api`): FastAPI app in `app.py`; writes to Postgres tables, emits embed queue state.
- **collector** (`services/collector`): CLI script `collector_imessage.py`; reads macOS Messages DB, posts to gateway/catalog; uses shared logging/db.
- **embedding_worker** (`services/embedding_worker`): Worker polling Postgres `embed_index_state`, encoding with `SentenceTransformer`, writing to Qdrant.
- **shared** (`shared/`): Logging, dependency guard, Postgres connection helpers, context queries reused by services.

## Cross-Service Calls & Data Flows
- `gateway` → `search`: HTTP via `haven.search.sdk.SearchServiceClient` targeting `${SEARCH_URL}/v1/search/query`.
- `gateway` → `catalog`: HTTP proxy of `/v1/catalog/events` and `/v1/context/general` to `${CATALOG_BASE_URL}`; defaults to `http://catalog:8081`.
- `gateway` ↔ Postgres: direct `psycopg` usage for `/v1/doc/{doc_id}` when `DATABASE_URL` configured.
- `search` ↔ Postgres: async queries through `haven.search.db.get_connection()` for lexical search + metadata.
- `search` ↔ Qdrant: `QdrantClient.search` with collection `${QDRANT_COLLECTION}` (default `haven_chunks`).
- `catalog` ↔ Postgres: synchronous ingestion into `threads`, `messages`, `chunks`, `embed_index_state`.
- `catalog` → `embed_index_state`: marks chunks `pending` for embedding worker.
- `collector` → gateway/catalog: posts events to `${CATALOG_ENDPOINT}` (defaults to `http://localhost:8085/v1/catalog/events`; compose profile uses `http://gateway:8080/v1/catalog/events`).
- `embedding_worker` ↔ Postgres + Qdrant: polls `embed_index_state`, generates embeddings via `SentenceTransformer`, upserts into Qdrant collection `${QDRANT_COLLECTION}` (default `haven_chunks`).

## Data & Integration Assets
- **Database schema**: `schema/catalog_mvp.sql` seeded via Postgres service.
- **Volumes**: `pg_data` for Postgres, `qdrant_data` for Qdrant.
- **OpenAPI**: `openapi.yaml` (shared definition, not currently referenced in code).
- **Tests**: `tests/` covering gateway summary/catalog proxy, search models, collector utils/imessage.
- **Docker Entrypoint Logic**: `Dockerfile` ARG `SERVICE` controls which console script/command runs; packages built via optional extras `search`, `gateway`, `collector`, `common`.

## Network & Auth Contracts
- Auth tokens provided via env: `AUTH_TOKEN` for gateway endpoints; `CATALOG_TOKEN` shared between gateway proxy and catalog ingestion; `SEARCH_TOKEN` optional for gateway→search.
- External dependencies: Qdrant accessible at `http://qdrant:6333`; Postgres at `postgresql://postgres:postgres@postgres:5432/haven`.

## Observed Entry Modules
```
services/gateway_api/app.py           # FastAPI gateway ASGI app
services/catalog_api/app.py           # FastAPI catalog ingest/context API
src/haven/search/main.py              # Typer CLI -> uvicorn search service
services/collector/collector_imessage.py  # CLI collector script (optional profile)
services/embedding_worker/worker.py   # Embedding background worker
```
