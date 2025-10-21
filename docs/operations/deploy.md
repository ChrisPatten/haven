# Deployment

Haven’s production footprint mirrors the local topology: Gateway is the only externally reachable service, while Catalog, Search, Postgres, Qdrant, and MinIO live on an internal network. This guide captures the operational steps for promoting a release and validating it in staging or production.

## Pre-Deployment Checklist
- ✅ Tests pass (`ruff`, `black --check`, `mypy`, `pytest`)
- ✅ `mkdocs build` succeeds (ensures documentation stays in sync)
- ✅ Container images built and pushed to your registry
- ✅ Application secrets stored in your deployment environment (bearer tokens, database URLs, MinIO credentials, Ollama endpoints)
- ✅ Database backup taken (`pg_dump` or snapshot)

## Build and Publish Images
```bash
# From repo root
docker compose build gateway catalog search embedding

# Tag and push (example)
docker tag haven-gateway:latest ghcr.io/your-org/haven-gateway:$(git rev-parse --short HEAD)
docker push ghcr.io/your-org/haven-gateway:$(git rev-parse --short HEAD)
```

Recommended images:
- `gateway`: FastAPI ingress + orchestration
- `catalog`: FastAPI persistence API
- `search`: Hybrid search service
- `embedding`: Worker container (often shares base image with services)
- Optional: `docs` image for MkDocs if you publish docs via CI

## Configuration and Secrets
- **Gateway**
  - `AUTH_TOKEN`, `CATALOG_TOKEN`, `GATEWAY_PUBLIC_URL`
  - Database DSN (if not using Compose defaults)
  - MinIO credentials (`MINIO_ENDPOINT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `MINIO_BUCKET`)
- **Catalog**
  - `DATABASE_URL`
  - Search service URL (for proxy features)
- **Search**
  - `QDRANT_URL`, `QDRANT_COLLECTION`
  - Optional: `OLLAMA_BASE_URL` if vector generation is proxied
- **Embedding Worker**
  - Same Qdrant/Ollama settings as Search
  - Poll/batch interval overrides
- **HostAgent**
  - `x-auth` secret distributed to trusted clients only

Use your platform’s secret manager (GitHub Actions secrets, AWS SSM, etc.) and inject them at runtime. Avoid shipping plaintext `.env` files with production credentials.

## Database Migrations
Catalog applies migrations automatically on startup, but you should still plan for controlled execution:

```bash
# Run once per deployment after scaling down workers
docker compose run --rm catalog python -m services.catalog_api.migrate

# Verify schema version
psql "$DATABASE_URL" -c "select version();"
```

If a manual reset is required:
```bash
psql "$DATABASE_URL" -f schema/init.sql
```
Ensure backups are in place before running ad-hoc resets.

## Deployment Workflow
1. **Prepare environment**: update Compose/Helm manifests or infrastructure templates with new image tags and secrets.
2. **Scale down workers** (optional but recommended): prevents new ingestion during migration.
3. **Deploy Catalog**: allows migrations to complete before other services reconnect.
4. **Deploy Gateway and Search**: redeploy sequentially to keep API availability high.
5. **Deploy Embedding Worker**: resumes embedding for any backlog created during the upgrade.
6. **Smoke test**:
   ```bash
   curl -H "Authorization: Bearer $AUTH_TOKEN" "$GATEWAY_URL/v1/healthz"
   curl -H "Authorization: Bearer $AUTH_TOKEN" "$GATEWAY_URL/v1/search?q=hello"
   ```
7. **Monitor logs**: Gateway ingestion logs (look for `submission_id`), Catalog migrations, Search query latencies, worker embedding counts.

## Observability and Alerts
- Capture structured logs for Gateway (`submission_id`, `status_code`), Catalog (ingest outcomes), and Embedding Worker (batch metrics).
- Qdrant exposes metrics on port `6333`; integrate with Prometheus/Grafana if available.
- MinIO provides an admin console for verifying uploaded objects.
- Add alerts on:
  - High 5xx rates in Gateway
  - Stalled chunks (`embedding_status='pending'` for extended periods)
  - MinIO or Postgres storage utilisation

## Rollback Strategy
1. Redeploy previous image tags for Gateway, Catalog, Search, and Embedding.
2. Restore Postgres from snapshot if schema changes are incompatible.
3. Flush chunk statuses if embeddings were mid-flight:  
   `UPDATE chunks SET embedding_status='pending' WHERE embedding_status='processing';`
4. Confirm MinIO objects remain intact; no rollback usually required since uploads are idempotent.

Document any manual steps in the [Changelog](../changelog.md) after stabilising production so future releases have clear guidance.

_Adapted from `documentation/technical_reference.md`, `schema/SCHEMA_V2_REFERENCE.md`, and operational runbooks in `README.md`._
