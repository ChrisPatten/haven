# Local Development

This guide describes the recommended workflow for running the Haven stack on macOS, iterating on services, and validating end-to-end ingestion. It consolidates the checklist previously maintained in `README.md`, HostAgent docs, and the technical reference.

## Environment Setup
1. **Install tooling**
   - Docker Desktop
   - Python 3.11 (for scripts, collectors, tests)
   - Swift toolchain (optional but required if you build HostAgent locally)
2. **Clone the repo and install dependencies**
   ```bash
   git clone https://github.com/your-org/haven.git
   cd haven
   pip install -r local_requirements.txt
   pip install -r requirements-docs.txt  # optional, needed for docs preview
   ```
3. **Configure environment variables**
   - `AUTH_TOKEN` (Gateway bearer token; default `changeme`)
   - Optional: `OLLAMA_API_URL`, `OLLAMA_BASE_URL`, `MINIO_*`, `DATABASE_URL`, collector-specific overrides
   - Populate a `.env` file if you prefer Compose to load secrets automatically.

## Run the Core Stack
```bash
export AUTH_TOKEN="changeme"
docker compose up --build
```
- `gateway` (8085) exposes ingestion and search APIs.
- `catalog` (8081) and `search` (8080) remain internal to the Docker network.
- Postgres, Qdrant, MinIO, and the embedding worker start alongside the services.

Schema migrations apply automatically. To re-run manually:
```bash
docker compose exec -T postgres psql -U postgres -d haven -f - < schema/init.sql
```

## HostAgent on macOS
HostAgent is optional for development but required for native collectors and OCR.

```bash
make -C hostagent install
make -C hostagent launchd  # installs user LaunchAgent
```

- Grant Full Disk Access to the installed binary or the Terminal you use during development.
- Logs: `tail -f ~/Library/Logs/Haven/hostagent.log`
- Health check: `curl -H "x-auth: change-me" http://localhost:7090/v1/health`
- Development mode: copy `~/Library/Messages/chat.db` to `~/.haven/chat.db` and set `HAVEN_IMESSAGE_CHAT_DB_PATH`.

## Collectors and Scripts
- **iMessage**: `python scripts/collectors/collector_imessage.py --simulate "Ping"`  
  Flags: `--once`, `--no-images`, `--batch-size`, `--lookback-days`.
- **Local Files**: `python scripts/collectors/collector_localfs.py --watch ~/HavenInbox --move-to ~/.haven/localfs/processed`
- **Contacts**: `python scripts/collectors/collector_contacts.py` (requires macOS Contacts permission)
- **Backfill enrichment**: `python scripts/backfill_image_enrichment.py --dry-run`

State files live under `~/.haven/`. Clean them up between experiments if you need a fresh run.

## Verification Checklist
1. **Service health**
   ```bash
   curl http://localhost:8085/v1/healthz
   curl http://localhost:8080/healthz
   ```
2. **Search smoke test**
   ```bash
   curl -H "Authorization: Bearer $AUTH_TOKEN" \
     "http://localhost:8085/v1/search?q=receipt"
   ```
3. **Embedding status**
   - Inspect worker logs for processed batches.
   - Query Postgres: `SELECT embedding_status, count(*) FROM chunks GROUP BY embedding_status;`
4. **MinIO uploads**
   - Access the MinIO console (http://localhost:9001) with the credentials set in `.env`.
   - Confirm attachments from collectors arrive with deduplicated SHA256 keys.

## Troubleshooting Tips
- `409 Conflict` from `/v1/ingest`: the idempotency key already exists; verify collector state.
- Empty search results: embeddings may still be pending; inspect worker logs or reset chunk status.
- HostAgent permission errors: confirm Full Disk Access and Contacts permissions, then re-run `make launchd`.
- Docker resource issues: ensure Docker Desktop has sufficient memory (4 GB+) when running the full stack.

_Adapted from `README.md`, `AGENTS.md`, and `documentation/technical_reference.md`._
