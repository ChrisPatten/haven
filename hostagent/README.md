# Haven Host Agent

Native macOS Swift service providing localhost HTTP API for host-only capabilities (iMessage collection, Vision OCR, filesystem monitoring).

## Overview

The Haven Host Agent is a Swift-based daemon that runs on macOS to provide access to system-level data and capabilities that cannot run inside Docker containers. It replaces the Python-based collectors with a unified, performant, native service.

### Key Features

- **🔒 Localhost-only HTTP API** - Accessible via `host.docker.internal` from Docker containers
- **👁️ Vision-based OCR** - Native macOS Vision framework for text extraction (replaces `imdesc`)
- **💬 iMessage Collection** - Safe, read-only access to Messages.app database with smart snapshots
- **📁 File System Monitoring** - FSEvents-based file watching with presigned URL uploads
- **🔌 Modular Architecture** - Enable/disable capabilities via runtime configuration
- **📊 Observable** - Prometheus metrics, structured JSON logging, health checks

## Quick Start

### Prerequisites

- macOS 14.0+ (Sonoma or later)
- Xcode 15.0+ or Swift 5.9+ toolchain
- Full Disk Access permission (required for Messages database)

### Installation

```bash
# Clone and build
cd hostagent
swift build -c release

# Install binary
sudo cp .build/release/hostagent /usr/local/bin/

# Create config directory
mkdir -p ~/.haven

# Copy default config
cp Resources/default-config.yaml ~/.haven/hostagent.yaml

# Edit config (IMPORTANT: change auth secret!)
nano ~/.haven/hostagent.yaml
```

### Grant Full Disk Access

1. Open **System Settings** → **Privacy & Security** → **Full Disk Access**
2. Click the **+** button
3. Navigate to `/usr/local/bin/hostagent`
4. Enable the checkbox
5. If prompted, authenticate with your password

> **Development Mode:** For rapid development without Full Disk Access, see [DEVELOPMENT_MODE.md](DEVELOPMENT_MODE.md) to use a copy of chat.db in `~/.haven/`.

### Run Manually

```bash
# Start the server
hostagent

# Start with custom config
hostagent --config ~/.haven/hostagent-dev.yaml

# Check health
curl http://localhost:7090/v1/health

# Authenticate with header
curl -H "x-auth: change-me" http://localhost:7090/v1/capabilities
```

### Auto-Start with LaunchAgent

```bash
# Copy LaunchAgent plist
cp Resources/LaunchAgents/com.haven.hostagent.plist ~/Library/LaunchAgents/

# Edit paths in plist (replace YOUR_USER with your username)
nano ~/Library/LaunchAgents/com.haven.hostagent.plist

# Load and start
launchctl load ~/Library/LaunchAgents/com.haven.hostagent.plist
launchctl start com.haven.hostagent

# Check status
launchctl list | grep haven

# View logs
tail -f ~/Library/Logs/Haven/hostagent.log
```

## API Reference

All endpoints require the `x-auth` header (default: `x-auth: change-me`).

### Core Endpoints

#### Health Check
```bash
GET /v1/health

Response:
{
  "status": "healthy",
  "started_at": "2025-10-16T14:00:00Z",
  "version": "1.0.0",
  "module_summaries": [...]
}
```

#### Capabilities
```bash
GET /v1/capabilities

Response:
{
  "modules": {
    "imessage": { "enabled": true, "permissions": { "fda": true } },
    "ocr": { "enabled": true, "permissions": {} },
    ...
  }
}
```

#### Metrics
```bash
GET /v1/metrics

Response: (Prometheus text format)
imsg_messages_total{status="success"} 15432
imsg_attachments_total 234
ocr_requests_total 189
...
```

### OCR Service (Vision Framework)

**Replaces `imdesc` with native macOS Vision OCR**

```bash
# Upload image file
POST /v1/ocr
Content-Type: multipart/form-data

Form data:
  file: <image file>

# Or use presigned URL
POST /v1/ocr
Content-Type: application/json

{
  "url": "https://minio.example.com/presigned-get-url"
}

Response:
{
  "ocr_text": "Detected text here...",
  "ocr_boxes": [
    {
      "text": "Line 1",
      "bbox": [0.1, 0.2, 0.8, 0.05],
      "level": "line",
      "confidence": 0.98
    }
  ],
  "lang": "en",
  "tooling": {
    "vision": "macOS-14.5"
  },
  "timings_ms": {
    "read": 12,
    "ocr": 210,
    "total": 230
  }
}
```

### iMessage Collector

```bash
# Backfill historical messages
POST /v1/collectors/imessage:run
Content-Type: application/json

{
  "mode": "backfill",
  "batch_size": 500,
  "max_rows": 10000
}

# Tail new messages
POST /v1/collectors/imessage:run

{
  "mode": "tail",
  "batch_size": 200
}

# Check state
GET /v1/collectors/imessage/state

Response:
{
  "cursor_rowid": 152340,
  "head_rowid": 152892,
  "floor_rowid": 1,
  "last_run": "2025-10-16T14:05:00Z",
  "last_error": null
}
```

### File System Watch

```bash
# Add watch
POST /v1/fs-watches
Content-Type: application/json

{
  "path": "/Users/chris/Ingest",
  "glob": "*.pdf",
  "target": "gateway",
  "handoff": "presigned"
}

# List watches
GET /v1/fs-watches

# Remove watch
DELETE /v1/fs-watches/{id}
```

## Configuration

Configuration is loaded from `~/.haven/hostagent.yaml` (or custom path via `--config` flag).

Environment variables override file settings:
- `HAVEN_PORT` - Server port (default: 7090)
- `HAVEN_AUTH_SECRET` - Authentication secret
- `HAVEN_GATEWAY_URL` - Gateway base URL
- `HAVEN_LOG_LEVEL` - Log level (debug, info, warning, error)

### Module Configuration

Each module can be enabled/disabled and configured independently:

```yaml
modules:
  imessage:
    enabled: true          # Enable iMessage collection
    batch_size: 500        # Messages per batch
    ocr_enabled: true      # Enable image OCR enrichment
  
  ocr:
    enabled: true
    languages: [en]        # Hint for Vision (best-effort)
    timeout_ms: 2000       # Per-image timeout
  
  fswatch:
    enabled: false
    watches: []            # Managed via API
  
  # Stub modules (not yet implemented)
  contacts: { enabled: false }
  calendar: { enabled: false }
  reminders: { enabled: false }
  mail: { enabled: false }
  notes: { enabled: false }
  faces: { enabled: false }
```

## Docker Integration

From your Haven `compose.yaml`, configure services to reach the host agent:

```yaml
services:
  gateway_api:
    environment:
      - HOST_AGENT_URL=http://host.docker.internal:7090
      - HOST_AGENT_AUTH=${HAVEN_AUTH_SECRET:-change-me}
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Then from gateway code:

```python
import httpx

async def get_ocr(image_path: str) -> dict:
    url = f"{os.getenv('HOST_AGENT_URL')}/v1/ocr"
    headers = {"x-auth": os.getenv("HOST_AGENT_AUTH")}
    
    async with httpx.AsyncClient() as client:
        with open(image_path, "rb") as f:
            files = {"file": f}
            resp = await client.post(url, headers=headers, files=files)
            resp.raise_for_status()
            return resp.json()
```

## Development

### Building

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run tests
swift test

# Run specific test
swift test --filter OCRServiceTests
```

### Project Structure

- `Sources/HavenCore/` - Shared utilities (config, logging, HTTP, gateway client)
- `Sources/OCR/` - Vision framework OCR service
- `Sources/IMessages/` - Messages.app database collector
- `Sources/FSWatch/` - File system monitoring
- `Sources/HostHTTP/` - SwiftNIO HTTP server
- `Sources/HostAgent/` - Main executable
- `Tests/` - Unit and integration tests

### Adding a New Module

1. Create module directory in `Sources/`
2. Implement module protocol with health check
3. Register in `ModulesConfig` (HavenCore/Config.swift)
4. Add handler in `HostHTTP/Router.swift`
5. Add tests in `Tests/`

## Migration from Python Collectors

### iMessage Collector

**Before (Python):**
```bash
python scripts/collectors/collector_imessage.py --simulate "Hi"
```

**After (Host Agent):**
```bash
curl -H "x-auth: change-me" \
  -X POST http://localhost:7090/v1/collectors/imessage:run \
  -H "Content-Type: application/json" \
  -d '{"mode": "tail"}'
```

### OCR (imdesc replacement)

**Before (Swift script):**
```bash
./scripts/collectors/imdesc /path/to/image.jpg
```

**After (Host Agent):**
```bash
curl -H "x-auth: change-me" \
  -X POST http://localhost:7090/v1/ocr \
  -F "file=@/path/to/image.jpg"
```

## Performance

### Benchmarks

- **iMessage backfill**: >= 10k messages/hour with OCR enabled
- **Tail latency**: <= 5s p50 for new message detection  
- **OCR latency**: <= 1.5s p50 for 5MB images
- **Memory footprint**: <= 500MB resident
- **CPU usage**: <= 20% average during backfill

### Optimizations

- **Batch processing** - Configurable batch sizes for throughput tuning
- **Concurrent OCR** - Parallel image processing with timeout isolation
- **Database snapshots** - Read-only copies prevent Messages.app locking
- **Cursor-based pagination** - Efficient large dataset traversal
- **Actor isolation** - Structured concurrency for safety

## Security

### Threat Model

- **Localhost binding** - Server only accepts connections from 127.0.0.1
- **Shared secret auth** - x-auth header required for all requests
- **TCC permissions** - Minimal by default; contacts/photos opt-in
- **FDA requirement** - Required for Messages database access
- **Read-only operations** - Never modifies Messages database or system data

### Best Practices

1. **Change default auth secret** in production
2. **Use environment variables** for sensitive config
3. **Rotate secrets** periodically
4. **Monitor access logs** for unauthorized attempts
5. **Keep macOS updated** for latest security patches

## Troubleshooting

### "Permission denied" accessing Messages database

1. Verify Full Disk Access is granted
2. Restart the agent after granting FDA
3. Check FDA applies to the correct binary path
4. Try running manually first: `hostagent`

### "Connection refused" from Docker

1. Verify agent is running: `curl http://localhost:7090/v1/health`
2. Check `extra_hosts` in compose.yaml includes `host.docker.internal`
3. On Linux, use `--network host` or `host.docker.internal:172.17.0.1`
4. Verify firewall allows localhost connections

### OCR timeout errors

1. Increase `timeout_ms` in config
2. Check image size (large images take longer)
3. Monitor CPU usage (throttling affects performance)
4. Consider disabling OCR for backfill: `ocr_enabled: false`

### High memory usage

1. Reduce `batch_size` for iMessage collector
2. Disable unused modules
3. Check for FSEvents leaks (file watch accumulation)
4. Restart agent periodically via LaunchAgent

## Contributing

See [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) for detailed architecture and development roadmap.

## License

[Include your license here]

## Support

- **Issues**: GitHub Issues
- **Docs**: `documentation/` directory
- **Architecture**: `IMPLEMENTATION_GUIDE.md`
- **Parent project**: [Haven](../README.md)
