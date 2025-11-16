# Local Development

This guide describes the recommended workflow for running the Haven stack on macOS, iterating on services, and validating end-to-end ingestion. It consolidates the checklist previously maintained in `README.md`, HostAgent docs, and the technical reference.

## Environment Setup
1. **Install tooling**
   - Docker Desktop
   - Python 3.11 (for scripts, collectors, tests)
   - Xcode 15.0+ or Swift 5.9+ toolchain (recommended for building the unified Haven macOS app)
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

## Haven.app
Haven.app is recommended for development as it provides native collectors and OCR capabilities.

**Build and run:**
```bash
cd Haven
open Haven.xcodeproj
# Build and run from Xcode (⌘R)
```

Or build from command line:
```bash
cd Haven
xcodebuild -scheme Haven -configuration Debug
open build/Debug/Haven.app
```

**Setup:**
- Grant Full Disk Access to Haven.app (System Settings → Privacy & Security → Full Disk Access)
- Grant Contacts permission if collecting contacts
- Configure Gateway URL in Settings (`⌘,`) or edit `~/.haven/hostagent.yaml`
- Logs: View in Console.app (filter for "Haven") or use `log stream --predicate 'process == "Haven"'`

**Development mode:** Copy `~/Library/Messages/chat.db` to `~/.haven/chat.db` and set `HAVEN_IMESSAGE_CHAT_DB_PATH` in your environment if you want to use a copy instead of the live database.

**Note:** Haven.app runs collectors directly via Swift APIs. No HTTP server is required.

## Collectors and Scripts

**Using Haven.app (Recommended):**
- Launch Haven.app and use the Collectors window (`⌘2`) to run collectors
- Configure collectors via Settings (`⌘,`)
- View results in the Dashboard (`⌘1`)

**Using CLI Collectors (Alternative):**
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
- Haven.app permission errors: confirm Full Disk Access and Contacts permissions in System Settings, then restart the app.
- Collector runtime won't start: check Gateway connectivity and configuration in Settings (`⌘,`).
- Docker resource issues: ensure Docker Desktop has sufficient memory (4 GB+) when running the full stack.

_Adapted from `README.md` and `documentation/technical_reference.md`._
