# Haven Host Agent (Swift)

## Overview
The host agent is a Swift-based daemon that runs on macOS, exposes an authenticated HTTP API on `127.0.0.1`, and brokers host-only capabilities for the Haven platform. It replaces the legacy `imdesc` helper, manages iMessage backfill/tailing with Vision OCR image enrichment, offers an OCR microservice, and captures filesystem events for gateway handoff.

Key binaries and assets:
- Swift Package: `haven-hostagent`
- Executable target: `haven-hostagent`
- Libraries: `Core`, `HostHTTP`, `IMessages`, `OCR`, `FSWatch`
- LaunchAgent: `documentation/hostagent/com.haven.hostagent.plist`

## Prerequisites
- macOS 14 or later with Xcode command-line tools
- Swift 6 toolchain (`swift build --version`)
- Full Disk Access granted for the agent binary (Messages DB, attachments)
- Optional: Vision OCR requires the default Apple frameworks (bundled with macOS)

## Building & Running
From the repository root:

```bash
cd haven-hostagent
swift build --cache-path .swiftpm-cache
swift run --cache-path .swiftpm-cache haven-hostagent
```

> **Note:** When running inside sandboxes, SwiftPM may attempt to write caches under `~/Library` and `~/.cache`. If you see permission errors, export `SWIFTPM_CUSTOM_CACHE_PATH` to a writable directory (e.g. `.swiftpm-cache`).

### Configuration
The agent loads `~/.haven/hostagent.yaml` (auto-created on first launch) and supports environment overrides:

```yaml
port: 7090
auth:
  header: x-auth
  secret: change-me
modules:
  imessage:
    enabled: true
    batch_size: 500
    ocr_enabled: true
    timeout_seconds: 30
  ocr:
    enabled: true
    languages: ["en"]
    timeout_ms: 2000
  fswatch:
    enabled: false
    watches: []
```

Important override environment variables:
- `HOST_AGENT_PORT`: listen port
- `HOST_AGENT_AUTH`: shared secret expected in the `x-auth` header
- `HOST_AGENT_BASE_URL`: gateway URL used for ingestion
- `IMESSAGE_DB_PATH`: override Messages DB path (useful for testing)
- `IMESSAGE_ATTACHMENTS_ROOT`: override attachment root directory

### LaunchAgent Installation
1. Copy `documentation/hostagent/com.haven.hostagent.plist` to `~/Library/LaunchAgents/com.haven.hostagent.plist`
2. Update `ProgramArguments[0]` if the binary lives elsewhere
3. Load with `launchctl load ~/Library/LaunchAgents/com.haven.hostagent.plist`
4. Grant Full Disk Access to the compiled binary via `System Settings → Privacy & Security → Full Disk Access`
5. Logs are written to `~/Library/Logs/Haven/`

## HTTP API (v1)
All endpoints require the shared secret header, default `x-auth`.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/health` | Runtime health, module summaries |
| GET | `/v1/capabilities` | Module availability, permission status |
| GET | `/v1/metrics` | Prometheus text exposition |
| GET | `/v1/modules` | Current module configs |
| PUT | `/v1/modules/{name}` | Enable/disable module and update config |
| POST | `/v1/collectors/imessage:run` | Trigger backfill/tail batch |
| GET | `/v1/collectors/imessage/state` | Cursor positions and last run info |
| GET | `/v1/collectors/imessage/logs?since=10m` | Recent structured logs |
| POST | `/v1/ocr` | Vision OCR for file upload or presigned URL |
| GET | `/v1/ocr/health` | OCR readiness and language hints |
| POST | `/v1/fs-watches` | Register filesystem watcher |
| GET | `/v1/fs-watches` | List registered watchers |
| DELETE | `/v1/fs-watches/{id}` | Remove watcher |

### cURL Examples
```bash
# Health
curl -H 'x-auth: change-me' http://127.0.0.1:7090/v1/health

# Run a backfill batch of 500 messages
curl -H 'x-auth: change-me' -H 'Content-Type: application/json' \
  -d '{"mode":"backfill","batch_size":500}' \
  http://127.0.0.1:7090/v1/collectors/imessage:run

# OCR via presigned URL
curl -H 'x-auth: change-me' -H 'Content-Type: application/json' \
  -d '{"url":"https://storage.example.com/sample.png"}' \
  http://127.0.0.1:7090/v1/ocr
```

## Module Notes

### iMessage Collector
- Creates a read-only snapshot of `chat.db` (env override: `IMESSAGE_DB_PATH`)
- Reads rows ascending by `rowid` using a durable cursor stored at `~/Library/Application Support/Haven/hostagent/state/imessage_state.json`
- Joins `message`, `handle`, `chat`, `attachment` tables and emits idempotent event payloads to the gateway
- Vision OCR can be disabled per-run or globally via config
- Attachment OCR failures are isolated per attachment and surfaced through metadata

### OCR Service
- Uses Vision `VNRecognizeTextRequest` with configurable language hints and timeouts
- Supports `multipart/form-data` uploads (`file`) and JSON presigned URLs
- Responds with recognized text, bounding boxes, language guess, and timing metrics

### FS Watch Service
- Uses `DispatchSourceFileSystemObject` to observe directories with debounce
- On create/modify: requests presigned PUT from the gateway, uploads to MinIO, notifies the gateway of metadata
- Watches persist in config (`modules.fswatch.config.watches`)

## Docker/Gateway Integration
Set the following environment variables in `docker compose` (gateway service configuration):

```yaml
environment:
  HOST_AGENT_BASE_URL: "http://host.docker.internal:7090"
  HOST_AGENT_AUTH: "change-me"
```

## Testing
The Swift package includes focused tests covering OCR, iMessage batching, and FS watch flows:

```bash
swift test --cache-path .swiftpm-cache
```

In sandboxed environments lacking access to `~/Library` or the global clang module cache, the test run may fail. If that happens, export `SWIFTPM_CUSTOM_CACHE_PATH` and `CLANG_MODULE_CACHE_PATH` to writable directories before executing `swift test`.

### Test Coverage
- `OCRModuleTests` – Vision OCR end-to-end on a generated sample image
- `IMessagesModuleTests` – Snapshot pagination, cursor advancement, attachment metadata, gateway batch emission (with mocked gateway)
- `FSWatchModuleTests` – Debounced filesystem event resulting in presigned PUT + notification

## FDA / TCC Guidance
1. Build the agent binary (`swift build`) and copy to a static location (`/usr/local/bin/haven-hostagent`).
2. Add the binary to **Full Disk Access** in System Settings.
3. On first launch, macOS will prompt for Messages database access; grant permission.
4. For Vision, no additional TCC prompts are required.
5. Contacts/Calendar/Reminders/Mail/Notes modules are shipped as disabled stubs and surface status via `/v1/capabilities`.

## Maintenance Notes
- Module configs are persisted in `~/.haven/hostagent.yaml`; the API writes back updated settings.
- Metrics are exposed in Prometheus format for scraping by local collectors.
- Environment overrides make automated testing possible without touching the real Messages DB or attachments tree.
- Update the LaunchAgent plist if the binary path changes; reload via `launchctl unload` / `launchctl load`.
