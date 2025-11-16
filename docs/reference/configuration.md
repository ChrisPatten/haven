# Configuration Reference

Complete guide to environment variables, configuration files, and settings for Haven services and collectors.

## Overview

Haven uses environment variables for configuration. In Docker Compose, these are set in `compose.yaml` or a `.env` file. For local development, export variables in your shell or use a `.env` file.

## Configuration Files

### `.env` File

Create a `.env` file in the repository root for local development:

```bash
# Copy example if available
cp .env.example .env

# Edit values
nano .env
```

Docker Compose automatically reads `.env` files. Keep secrets out of version control—`.env` is gitignored.

### Haven.app Configuration

Haven.app uses a YAML configuration file at `~/.haven/hostagent.yaml`. Configure via:
- **Settings UI**: Open Haven.app → Settings (`⌘,`)
- **Config File**: Edit `~/.haven/hostagent.yaml` directly

## Service Configuration

### Gateway API

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_TOKEN` | `changeme` | Bearer token for Gateway API authentication. Required for all Gateway endpoints. |
| `CATALOG_BASE_URL` | `http://catalog:8081` | Internal URL Gateway uses to reach Catalog API. |
| `CATALOG_TOKEN` | _(none)_ | Optional shared secret for Catalog API calls. |
| `SEARCH_URL` | `http://search:8080` | Internal URL Gateway uses to reach Search Service. |
| `SEARCH_TOKEN` | _(none)_ | Optional bearer token for Search Service calls. |
| `SEARCH_TIMEOUT` | `60.0` | Timeout in seconds for Search Service requests. |
| `DATABASE_URL` | _(auto)_ | Postgres connection string. Defaults to Docker network URL. |
| `CONTACTS_DEFAULT_REGION` | `US` | Default region for phone number normalization. |
| `CONTACTS_HELPER_URL` | `http://catalog:8081` | URL for contacts export helper service. |
| `CONTACTS_HELPER_TOKEN` | _(none)_ | Optional token for contacts helper. |
| `MINIO_ENDPOINT` | `minio:9000` | MinIO object storage endpoint. |
| `MINIO_ACCESS_KEY` | `minioadmin` | MinIO access key. |
| `MINIO_SECRET_KEY` | `minioadmin` | MinIO secret key. |
| `MINIO_BUCKET` | `haven-files` | MinIO bucket name for file storage. |
| `MINIO_SECURE` | `false` | Use HTTPS for MinIO connections. |
| `IMAGE_PLACEHOLDER_TEXT` | `[image]` | Placeholder text when images are disabled. |
| `FILE_PLACEHOLDER_TEXT` | `[file]` | Placeholder text for file attachments. |

### Catalog API

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgresql://postgres:postgres@postgres:5432/haven_v2` | Postgres connection string. |
| `CATALOG_TOKEN` | _(none)_ | Optional authentication token for Catalog API. |
| `SEARCH_URL` | `http://search:8080` | URL for Search Service integration. |
| `SEARCH_TOKEN` | _(none)_ | Optional bearer token for Search Service. |
| `CATALOG_FORWARD_TO_SEARCH` | `true` | Automatically forward ingested documents to Search Service. |
| `QDRANT_URL` | `http://qdrant:6333` | Qdrant vector database URL. |
| `QDRANT_COLLECTION` | `haven_chunks` | Qdrant collection name for vectors. |

### Search Service

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_DSN` | _(auto)_ | Postgres connection string (alternative to `DATABASE_URL`). |
| `DATABASE_URL` | `postgresql://postgres:postgres@localhost:5432/haven_v2` | Postgres connection string. |
| `QDRANT_URL` | `http://qdrant:6333` | Qdrant vector database URL. |
| `QDRANT_COLLECTION` | `haven_chunks` | Qdrant collection name. |
| `EMBEDDING_MODEL` | `BAAI/bge-m3` | Embedding model identifier. |
| `EMBEDDING_DIM` | `1024` | Vector dimension (must match model). |
| `SERVICE_NAME` | `search-service` | Service identifier for logging. |
| `SEARCH_INGEST_BATCH` | `32` | Batch size for search ingestion. |
| `ENABLE_DLQ` | `false` | Enable dead letter queue for failed operations. |
| `OLLAMA_BASE_URL` | `http://host.docker.internal:11434` | Ollama base URL for local embeddings. |

### Embedding Worker

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | _(auto)_ | Postgres connection string. |
| `CATALOG_BASE_URL` | `http://catalog:8081` | Catalog API URL for posting embeddings. |
| `CATALOG_TOKEN` | _(none)_ | Optional authentication token for Catalog API. |
| `OLLAMA_BASE_URL` | `http://localhost:11434` | Ollama base URL for embedding generation. |
| `EMBEDDING_MODEL` | `bge-m3` | Embedding model identifier. |
| `WORKER_POLL_INTERVAL` | `2.0` | Seconds between polling for pending chunks. |
| `WORKER_BATCH_SIZE` | `8` | Number of chunks to process per batch. |
| `EMBEDDING_REQUEST_TIMEOUT` | `15.0` | Timeout in seconds for embedding API requests. |

## Collector Configuration

### iMessage Collector

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_TOKEN` | _(required)_ | Gateway API bearer token. |
| `GATEWAY_URL` | `http://localhost:8085` | Gateway API base URL. |
| `CATALOG_ENDPOINT` | _(auto)_ | Gateway ingest endpoint (derived from `GATEWAY_URL`). |
| `IMAGE_PLACEHOLDER_TEXT` | `[image]` | Placeholder when images are disabled. |
| `IMAGE_MISSING_PLACEHOLDER_TEXT` | `[image missing]` | Placeholder when image file is missing. |
| `IMDESC_CLI_PATH` | _(auto)_ | Path to native macOS Vision OCR helper. |
| `IMDESC_TIMEOUT_SECONDS` | `30.0` | Timeout for OCR helper. |
| `OLLAMA_ENABLED` | `false` | Enable Ollama vision captioning. |
| `OLLAMA_API_URL` | `http://localhost:11434` | Ollama API URL. |
| `OLLAMA_VISION_MODEL` | `llava:7b` | Vision model for captioning. |
| `OLLAMA_CAPTION_PROMPT` | _(default)_ | Prompt template for captions. |
| `OLLAMA_TIMEOUT_SECONDS` | `60.0` | Timeout for Ollama requests. |
| `OLLAMA_MAX_RETRIES` | `3` | Maximum retries for Ollama requests. |
| `COLLECTOR_POLL_INTERVAL` | `300` | Seconds between collector runs. |
| `COLLECTOR_BATCH_SIZE` | `100` | Messages per batch. |

**Haven.app Configuration:**

Configure via Settings (`⌘,`) → iMessage Collector:
- Enable/disable collector
- Simulate mode
- Batch size
- Lookback days
- Image handling options

**State Files:**
- `~/.haven/imessage_collector_state.json` - Last processed message ID
- `~/.haven/imessage_versions.json` - Version tracking for deduplication
- `~/.haven/chat.db` - Backup of Messages database

### Local Files Collector

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_TOKEN` | _(required)_ | Gateway API bearer token. |
| `GATEWAY_URL` | `http://localhost:8085` | Gateway API base URL. |
| `LOCALFS_MAX_FILE_MB` | `100` | Maximum file size in MB. |
| `LOCALFS_REQUEST_TIMEOUT` | `300.0` | HTTP request timeout in seconds. |

**Haven.app Configuration:**

Configure via Settings (`⌘,`) → Local Files Collector:
- Watch directory
- Include/exclude patterns (glob)
- Move/delete after processing
- Tags

**State Files:**
- `~/.haven/localfs_collector_state.json` - Processed file tracking

### Contacts Collector

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_TOKEN` | _(required)_ | Gateway API bearer token. |
| `GATEWAY_URL` | `http://localhost:8085` | Gateway API base URL. |
| `CATALOG_TOKEN` | _(none)_ | Optional Catalog API token. |

**Haven.app Configuration:**

Configure via Settings (`⌘,`) → Contacts Collector:
- Enable/disable collector
- VCF import directory
- Sync mode (full/incremental)

**State Files:**
- `~/.haven/contacts_collector_state.json` - Last sync token

### Email Collectors

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_TOKEN` | _(required)_ | Gateway API bearer token. |
| `GATEWAY_URL` | `http://localhost:8085` | Gateway API base URL. |

**Haven.app Configuration:**

Configure via Settings (`⌘,`) → Email Collector:
- **IMAP**: Server, port, username, password, folders
- **Local Mail.app**: Mail data directory, account selection

## Enrichment Configuration

Haven's enrichment system adds OCR, captions, face detection, and entity extraction to documents and images. Enrichment is controlled at two levels:

1. **Per-Collector Settings**: Enable/disable enrichment per collector (Email, Files, iMessage, Contacts)
2. **Module Settings**: Configure enrichment service parameters (OCR quality, entity types, face detection, captioning)

### Per-Collector Enrichment Control

Haven.app stores per-collector enrichment settings in `~/.haven/collector_enrichment.plist`. Configure via:

- **Haven.app Settings UI**: Settings (`⌘,`) → Enrichment Settings
- **Config File**: Edit `~/.haven/collector_enrichment.plist` directly

**Collector IDs:**
- `email_imap` - Email (IMAP) collector
- `localfs` - Local Files collector
- `imessage` - iMessage collector
- `contacts` - Contacts collector (always skips enrichment)

**Configuration Format:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>email_imap</key>
    <dict>
        <key>skipEnrichment</key>
        <false/>
    </dict>
    <key>localfs</key>
    <dict>
        <key>skipEnrichment</key>
        <false/>
    </dict>
    <key>imessage</key>
    <dict>
        <key>skipEnrichment</key>
        <false/>
    </dict>
</dict>
</plist>
```

When `skipEnrichment` is `true` for a collector, documents from that collector are submitted without any enrichment processing (OCR, face detection, entity extraction, captioning).

### Enrichment Architecture

Haven uses an `EnrichmentOrchestrator` that coordinates multiple enrichment services:

- **ImageExtractor**: Extracts images from HTML content (email, documents)
- **TextExtractor**: Extracts and cleans text from HTML/rich text content
- **OCR Service**: macOS Vision framework OCR
- **Face Service**: Face detection in images
- **Entity Service**: Named entity extraction (people, organizations, places, etc.)
- **Caption Service**: Image captioning via Ollama or Vision API

The orchestrator processes each image attachment independently, then enriches the document text with OCR results for entity extraction.

## Image Enrichment Configuration

Image enrichment adds OCR, captions, and entity detection to image attachments.

### Native macOS Vision OCR

The native OCR helper uses macOS Vision framework:

| Variable | Default | Description |
|----------|---------|-------------|
| `IMDESC_CLI_PATH` | _(auto)_ | Path to compiled `imdesc` binary. |
| `IMDESC_TIMEOUT_SECONDS` | `30.0` | Timeout for OCR operations. |

**Building the Helper:**

```bash
scripts/build-imdesc.sh
```

The binary is typically located at `scripts/collectors/imdesc` or `~/.haven/bin/imdesc`.

### Ollama Vision Captioning

Optional captioning via Ollama vision models:

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_ENABLED` | `false` | Enable Ollama captioning. |
| `OLLAMA_API_URL` | `http://localhost:11434` | Ollama API URL. |
| `OLLAMA_BASE_URL` | `http://host.docker.internal:11434` | Base URL for embedding service. |
| `OLLAMA_VISION_MODEL` | `llava:7b` | Vision model identifier. |
| `OLLAMA_CAPTION_PROMPT` | _(default)_ | Prompt template for captions. |
| `OLLAMA_TIMEOUT_SECONDS` | `60.0` | Request timeout. |
| `OLLAMA_MAX_RETRIES` | `3` | Maximum retry attempts. |

**Recommended Models:**
- `llava:7b` - Good balance of quality and speed
- `qwen2.5vl:3b` - Smaller, faster alternative
- `llava:13b` - Higher quality, slower

**macOS Docker Note:** Use `http://host.docker.internal:11434` to reach host Ollama from containers.

## Database Configuration

### Postgres

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_DB` | `haven` | Database name. |
| `POSTGRES_USER` | `postgres` | Database user. |
| `POSTGRES_PASSWORD` | `postgres` | Database password. |
| `DATABASE_URL` | _(auto)_ | Full connection string. |

**Connection String Format:**
```
postgresql://[user]:[password]@[host]:[port]/[database]
```

**Examples:**
- Docker: `postgresql://postgres:postgres@postgres:5432/haven`
- Local: `postgresql://postgres:postgres@localhost:5432/haven`
- Remote: `postgresql://user:pass@db.example.com:5432/haven`

### Qdrant

| Variable | Default | Description |
|----------|---------|-------------|
| `QDRANT_URL` | `http://qdrant:6333` | Qdrant server URL. |
| `QDRANT_COLLECTION` | `haven_chunks` | Collection name for vectors. |

**Local Development:** Qdrant runs in Docker. For external Qdrant:
```
QDRANT_URL=http://qdrant.example.com:6333
```

## MinIO Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MINIO_ENDPOINT` | `minio:9000` | MinIO server endpoint. |
| `MINIO_ACCESS_KEY` | `minioadmin` | Access key. |
| `MINIO_SECRET_KEY` | `minioadmin` | Secret key. |
| `MINIO_BUCKET` | `haven-files` | Bucket name. |
| `MINIO_SECURE` | `false` | Use HTTPS. |

**MinIO Console:** Access at `http://localhost:9001` (default credentials: `minioadmin`/`minioadmin`)

## Development vs Production

### Development Defaults

For local development, many settings have permissive defaults:
- `AUTH_TOKEN=changeme` (insecure, for local only)
- `MINIO_SECURE=false` (HTTP)
- Default passwords (`postgres`, `minioadmin`)

### Production Checklist

- [ ] Change `AUTH_TOKEN` to strong random value
- [ ] Set `CATALOG_TOKEN` and `SEARCH_TOKEN` for service auth
- [ ] Use strong Postgres password
- [ ] Use strong MinIO credentials
- [ ] Set `MINIO_SECURE=true` if using HTTPS
- [ ] Use managed database (RDS, Cloud SQL, etc.)
- [ ] Use managed object storage (S3, GCS, etc.) instead of MinIO
- [ ] Configure proper network security
- [ ] Use secret management (AWS Secrets Manager, Vault, etc.)

## Configuration Examples

### Minimal Local Development

```bash
# .env
AUTH_TOKEN=changeme
OLLAMA_BASE_URL=http://host.docker.internal:11434
```

### Production-like Local Setup

```bash
# .env
AUTH_TOKEN=$(openssl rand -hex 32)
CATALOG_TOKEN=$(openssl rand -hex 32)
SEARCH_TOKEN=$(openssl rand -hex 32)
MINIO_ACCESS_KEY=$(openssl rand -hex 16)
MINIO_SECRET_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
OLLAMA_BASE_URL=http://host.docker.internal:11434
EMBEDDING_MODEL=BAAI/bge-m3
WORKER_BATCH_SIZE=16
WORKER_POLL_INTERVAL=2.0
```

### External Services

```bash
# .env
DATABASE_URL=postgresql://user:pass@db.example.com:5432/haven
QDRANT_URL=http://qdrant.example.com:6333
MINIO_ENDPOINT=s3.amazonaws.com
MINIO_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE
MINIO_SECRET_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
MINIO_BUCKET=haven-production
MINIO_SECURE=true
```

## Haven.app Configuration Files

Haven.app uses multiple configuration files:

### Main Configuration: `~/.haven/hostagent.yaml`

```yaml
gateway:
  url: "http://host.docker.internal:8085"
  auth_token: "changeme"
  timeout: 30.0

collectors:
  imessage:
    enabled: true
    batch_size: 100
    lookback_days: 30
    images:
      enabled: true
      ocr: true
      captioning: false
  
  localfs:
    enabled: false
    watch_dir: "~/HavenInbox"
    include: ["*.txt", "*.md", "*.pdf"]
    exclude: []
  
  contacts:
    enabled: true
    vcf_directory: null
  
  email:
    imap:
      enabled: false
      server: "imap.example.com"
      port: 993
      username: "user@example.com"
      folders: ["INBOX"]
    local:
      enabled: false
      mail_directory: "~/Library/Mail"

advanced:
  ocr:
    languages: ["en"]
    timeoutMs: 15000
    recognitionLevel: "accurate"
    includeLayout: false
  entity:
    types: ["person", "organization", "place"]
    minConfidence: 0.6
  face:
    minFaceSize: 0.01
    minConfidence: 0.7
    includeLandmarks: false
  caption:
    enabled: false
    method: "ollama"
    timeoutMs: 10000
    model: null
  fswatch:
    eventQueueSize: 1024
    debounceMs: 500
  localfs:
    maxFileBytes: 104857600
  debug:
    enabled: false
    outputPath: "~/.haven/debug_documents.jsonl"
```

### Per-Collector Enrichment: `~/.haven/collector_enrichment.plist`

Controls whether enrichment is skipped per collector. See [Per-Collector Enrichment Control](#per-collector-enrichment-control) above.

Edit via Settings UI (`⌘,`) or edit the files directly.

## Troubleshooting Configuration

### Common Issues

**Services can't connect:**
- Check `DATABASE_URL`, `QDRANT_URL`, `MINIO_ENDPOINT` match Docker service names
- Verify network connectivity between containers
- Check service dependencies in `compose.yaml`

**Authentication failures:**
- Verify `AUTH_TOKEN` matches between Gateway and clients
- Check `CATALOG_TOKEN` and `SEARCH_TOKEN` if using service-to-service auth
- Ensure tokens are set in all relevant services

**Embedding worker not processing:**
- Check `CATALOG_BASE_URL` is correct
- Verify `EMBEDDING_MODEL` matches Search Service
- Check `WORKER_POLL_INTERVAL` and `WORKER_BATCH_SIZE` are reasonable
- Verify Ollama is accessible at `OLLAMA_BASE_URL`

**Haven.app can't reach Gateway:**
- Verify Gateway is running: `curl http://localhost:8085/v1/healthz`
- Check `gateway.url` in `~/.haven/hostagent.yaml`
- For Docker: use `http://host.docker.internal:8085`
- Check firewall/network settings

### Validation

Test configuration:

```bash
# Check Gateway
curl -H "Authorization: Bearer $AUTH_TOKEN" http://localhost:8085/v1/healthz

# Check Catalog (if token set)
curl -H "Authorization: Bearer $CATALOG_TOKEN" http://localhost:8081/v1/healthz

# Check Search
curl http://localhost:8080/healthz

# Check Postgres
psql "$DATABASE_URL" -c "SELECT version();"

# Check Qdrant
curl http://localhost:6333/collections
```

## Related Documentation

- [Getting Started](../getting-started.md) - Initial setup guide
- [Local Development](../operations/local-dev.md) - Development workflow
- [Technical Reference](technical_reference.md) - Deep technical details

