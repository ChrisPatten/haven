# iMessage Collector

The iMessage collector extracts conversations from the macOS Messages database and ingests them into Haven for search and analysis.

## Overview

The iMessage collector:
- Reads messages from `~/Library/Messages/chat.db`
- Extracts conversations, participants, and attachments
- Enriches images with OCR and optional captioning
- Tracks versions to prevent duplicate ingestion
- Supports both Haven.app and CLI execution

## Prerequisites

- macOS with access to Messages database
- Full Disk Access permission (required for reading `chat.db`)
- Gateway API running and accessible

## Using Haven.app (Recommended)

Haven.app provides the easiest way to run the iMessage collector:

1. **Launch Haven.app**
2. **Grant Permissions:**
   - System Settings → Privacy & Security → Full Disk Access
   - Add Haven.app to the list
   - Restart Haven.app if already running

3. **Configure Collector:**
   - Open Settings (`⌘,`)
   - Navigate to iMessage Collector
   - Configure options:
     - Enable/disable collector
     - Batch size (default: 100)
     - Lookback days (how far back to process)
     - Image handling (OCR, captioning)

4. **Run Collector:**
   - Open Collectors window (`⌘2`)
   - Select iMessage collector
   - Click "Run" or use menu "Run All Collectors"

5. **Monitor Progress:**
   - View Dashboard (`⌘1`) for activity log
   - Check status indicator in menu bar
   - Review error messages if any

## Using CLI (Alternative)

For environments without Haven.app or automated runs:

### Basic Usage

```bash
# Set authentication
export AUTH_TOKEN="changeme"
export GATEWAY_URL="http://localhost:8085"

# Run collector (processes new messages since last run)
python scripts/collectors/collector_imessage.py

# Simulate a message for testing
python scripts/collectors/collector_imessage.py --simulate "Test message"
```

### Options

| Flag | Description |
|------|-------------|
| `--once` | Process current backlog and exit (no continuous monitoring) |
| `--no-images` | Skip image enrichment (OCR, captioning) |
| `--simulate TEXT` | Inject a test message instead of reading from database |
| `--batch-size N` | Process N messages per batch (default: 100) |
| `--lookback-days N` | Only process messages from last N days |
| `--disable-images` | Alias for `--no-images` |

### Examples

```bash
# Single run, no images
python scripts/collectors/collector_imessage.py --once --no-images

# Process last 7 days only
python scripts/collectors/collector_imessage.py --lookback-days 7

# Large batch size for faster processing
python scripts/collectors/collector_imessage.py --batch-size 500
```

## How It Works

### Data Extraction

1. **Database Access:**
   - Creates backup of `chat.db` to `~/.haven/chat.db`
   - Reads messages, attachments, and metadata
   - Extracts conversation threads and participants

2. **Message Processing:**
   - Normalizes message content and metadata
   - Extracts sender/recipient information
   - Links messages to conversation threads
   - Tracks message versions for deduplication

3. **Attachment Handling:**
   - Identifies image attachments
   - Optionally enriches with OCR and captioning
   - Uploads to Gateway for storage
   - Links attachments to messages

4. **Ingestion:**
   - Sends messages to Gateway API
   - Gateway forwards to Catalog for persistence
   - Catalog creates documents, threads, and chunks
   - Embedding worker processes chunks for search

### Version Tracking

The collector maintains version tracking to prevent duplicate ingestion:

- **State File:** `~/.haven/imessage_collector_state.json`
  - Tracks last processed message ID
  - Enables incremental sync

- **Version File:** `~/.haven/imessage_versions.json`
  - Stores message signatures (text hash + attachment hashes)
  - Prevents re-ingestion of unchanged messages
  - Handles message edits and updates

### Image Enrichment

When enabled, images are enriched with:

1. **OCR (Optical Character Recognition):**
   - Uses macOS Vision framework
   - Extracts text from images
   - Adds to message content for searchability

2. **Captioning (Optional):**
   - Uses Ollama vision models (e.g., `llava:7b`)
   - Generates descriptive captions
   - Helps with image search

3. **Entity Detection:**
   - Detects faces, objects, scenes
   - Adds metadata for filtering

**Disabling Images:**
- Use `--no-images` flag or disable in Haven.app settings
- Images are replaced with placeholder text `[image]`
- Messages remain searchable without image content

## Configuration

### Environment Variables

See [Configuration Reference](../reference/configuration.md) for complete list. Key variables:

- `AUTH_TOKEN` - Gateway API authentication
- `GATEWAY_URL` - Gateway API base URL
- `OLLAMA_ENABLED` - Enable captioning
- `OLLAMA_API_URL` - Ollama server URL
- `IMDESC_CLI_PATH` - Path to OCR helper binary

### Haven.app Configuration

Configure via Settings (`⌘,`) → iMessage Collector:

```yaml
collectors:
  imessage:
    enabled: true
    batch_size: 100
    lookback_days: 30
    images:
      enabled: true
      ocr: true
      captioning: false
```

## State Management

### State Files

All state files are stored in `~/.haven/`:

- `imessage_collector_state.json` - Last processed message ID
- `imessage_versions.json` - Message version signatures
- `chat.db` - Backup of Messages database

### Resetting State

To reprocess all messages:

```bash
# Remove state files
rm ~/.haven/imessage_collector_state.json
rm ~/.haven/imessage_versions.json

# Run collector (will process from beginning)
python scripts/collectors/collector_imessage.py
```

**Warning:** This will re-ingest all messages. Use with caution.

## Troubleshooting

### Permission Issues

**Error:** Cannot access Messages database

**Solution:**
1. System Settings → Privacy & Security → Full Disk Access
2. Add Haven.app (or Terminal if using CLI)
3. Restart application

### Gateway Connection Issues

**Error:** Cannot connect to Gateway

**Solution:**
- Verify Gateway is running: `curl http://localhost:8085/v1/healthz`
- Check `GATEWAY_URL` environment variable
- For Docker: use `http://host.docker.internal:8085`
- Verify `AUTH_TOKEN` matches Gateway configuration

### Image Enrichment Failures

**Error:** OCR or captioning not working

**Solution:**
- Check OCR helper is built: `scripts/build-imdesc.sh`
- Verify Ollama is running if using captioning
- Check `OLLAMA_API_URL` is correct
- Collector will continue without enrichment if helpers unavailable

### Duplicate Messages

**Issue:** Messages being ingested multiple times

**Solution:**
- Check version tracking files exist
- Verify state file is being updated
- Check for multiple collector instances running
- Review Gateway idempotency logs

## Performance Considerations

### Batch Size

- **Small batches (10-50):** Slower but lower memory usage
- **Medium batches (100-200):** Good balance (default)
- **Large batches (500+):** Faster but higher memory usage

### Lookback Days

- **Recent only (7-30 days):** Fast, good for regular syncs
- **All messages:** Slower initial run, complete history

### Image Processing

- **No images:** Fastest, minimal processing
- **OCR only:** Moderate speed, good searchability
- **OCR + captioning:** Slowest, best searchability

## Related Documentation

- [Configuration Reference](../reference/configuration.md) - Environment variables
- [Haven.app Guide](../havenui.md) - App usage
- [Functional Guide](../reference/functional_guide.md) - Ingestion workflows

