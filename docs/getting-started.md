# Getting Started

Follow these steps to bring up Haven locally, preview the documentation site, and ingest your first test data. The workflow mirrors the process described in the repo `README.md` and the functional guide.

## Prerequisites
- macOS with Python 3.11+
- Docker Desktop (required for Gateway, Catalog, Search, Postgres, Qdrant, and MinIO)
- Access to `~/Library/Messages/chat.db` if you plan to run the iMessage collector
- A bearer token exported as `AUTH_TOKEN` for Gateway authentication (development default is `changeme`)

Optional:
- Swift toolchain (for HostAgent builds)
- Ollama with a vision-capable model if you want local captioning

## Clone and Install Tooling
```bash
git clone https://github.com/your-org/haven.git
cd haven

# Python dependencies for docs and scripts
pip install -r local_requirements.txt
pip install -r requirements-docs.txt
```

If you use `uv` or another package manager, mirror the steps above with your preferred tooling. The collectors rely on the packages in `local_requirements.txt`, while MkDocs uses the extras in `requirements-docs.txt`.

## Start Core Services
```bash
export AUTH_TOKEN="changeme"  # override in production
docker compose up --build
```

The compose stack launches Gateway (`:8085`), Catalog (`:8081`), Search (`:8080`), Postgres, Qdrant, MinIO, and the embedding worker. Schema migrations run automatically on boot. To reapply the schema manually:

```bash
docker compose exec -T postgres psql -U postgres -d haven -f - < schema/init.sql
# or from the host if you have psql installed:
psql postgresql://postgres:postgres@localhost:5432/haven -f schema/init.sql
```

## Ingest Sample Data

### iMessage Collector
```bash
python scripts/collectors/collector_imessage.py --simulate "Hello from Haven!"
```
- `--no-images` skips OCR/captioning
- `--once` processes the current backlog and exits
- State files live under `~/.haven/`

### Local Files Collector
```bash
python scripts/collectors/collector_localfs.py \
  --watch ~/HavenInbox \
  --move-to ~/.haven/localfs/processed
```
- Supports `--include` / `--exclude` glob filters
- Uses `AUTH_TOKEN` and `GATEWAY_URL` to reach the gateway

### Verify Ingestion
```bash
curl -H "Authorization: Bearer $AUTH_TOKEN" \
  "http://localhost:8085/v1/search?q=Haven"
```
You should see documents returned from your simulated collector runs.

## Preview the Documentation Site
```bash
mkdocs serve
```
Visit `http://127.0.0.1:8000/` to browse the site. The `mkdocs-simple-hooks` plugin copies `openapi/gateway.yaml` into the build so the Gateway API page always reflects the latest spec.

## Next Steps
- Consult the [Architecture Overview](architecture/overview.md) for data flow details.
- Review [Local Development](operations/local-dev.md) for deeper environment guidance.
- Use `ruff`, `black`, and `pytest` to validate changes before submitting a PR.

_Adapted from `README.md`, `documentation/functional_guide.md`, and `docs/guides/README.md`._
