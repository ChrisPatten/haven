# Local Files Collector

The Local Files collector watches directories for files and ingests them into Haven for search and analysis.

## Overview

The Local Files collector:
- Monitors directories for new and modified files
- Supports multiple file types (text, PDF, images)
- Extracts text content automatically
- Enriches images with OCR and captioning
- Tracks processed files to avoid duplicates

## Prerequisites

- macOS, Linux, or Windows
- Gateway API running and accessible
- Read access to watched directories

## Supported File Types

| Extension | MIME Type | Text Extraction |
|-----------|-----------|-----------------|
| `.txt` | `text/plain` | Direct read |
| `.md` | `text/markdown` | Direct read |
| `.pdf` | `application/pdf` | PDF parser |
| `.png` | `image/png` | OCR (if enabled) |
| `.jpg`, `.jpeg` | `image/jpeg` | OCR (if enabled) |
| `.heic` | `image/heic` | OCR (if enabled) |

## Using Haven.app (Recommended)

Haven.app provides the easiest way to run the Local Files collector:

1. **Launch Haven.app**

2. **Configure Collector:**
   - Open Settings (`⌘,`)
   - Navigate to Local Files Collector
   - Configure options:
     - Watch directory (e.g., `~/HavenInbox`)
     - Include patterns (glob, e.g., `*.txt`, `*.pdf`)
     - Exclude patterns (glob, e.g., `*.tmp`)
     - Move/delete after processing
     - Tags for ingested files

3. **Run Collector:**
   - Open Collectors window (`⌘2`)
   - Select Local Files collector
   - Click "Run" or use menu "Run All Collectors"

4. **Monitor Progress:**
   - View Dashboard (`⌘1`) for activity log
   - Check processed file count
   - Review any errors

## Using CLI (Alternative)

For environments without Haven.app or automated runs:

### Basic Usage

```bash
# Set authentication
export AUTH_TOKEN="changeme"
export GATEWAY_URL="http://localhost:8085"

# Watch a directory
python scripts/collectors/collector_localfs.py \
  --watch ~/HavenInbox \
  --move-to ~/.haven/localfs/processed
```

### Options

| Flag | Description |
|------|-------------|
| `--watch DIR` | Directory to watch for files |
| `--move-to DIR` | Move files here after processing |
| `--include PATTERN` | Include files matching pattern (glob) |
| `--exclude PATTERN` | Exclude files matching pattern (glob) |
| `--delete-after` | Delete files after processing (instead of move) |
| `--dry-run` | Log matches without uploading |
| `--one-shot` | Process current backlog and exit |
| `--tags TAG1,TAG2` | Add tags to ingested files |
| `--state-file PATH` | Custom state file location |

### Examples

```bash
# Watch directory, move processed files
python scripts/collectors/collector_localfs.py \
  --watch ~/Documents/Inbox \
  --move-to ~/Documents/Processed \
  --include "*.txt" --include "*.pdf"

# One-time run, delete after processing
python scripts/collectors/collector_localfs.py \
  --watch ~/Downloads \
  --delete-after \
  --one-shot

# Dry run to see what would be processed
python scripts/collectors/collector_localfs.py \
  --watch ~/HavenInbox \
  --dry-run

# Add tags to files
python scripts/collectors/collector_localfs.py \
  --watch ~/Documents \
  --tags "personal,important"
```

## How It Works

### File Detection

1. **Initial Scan:**
   - Scans watch directory for matching files
   - Checks against include/exclude patterns
   - Skips already processed files (via state file)

2. **File Watching:**
   - Uses filesystem events (FSEvents on macOS)
   - Detects new and modified files
   - Triggers processing automatically

3. **Duplicate Detection:**
   - Calculates SHA256 hash of file content
   - Checks against Gateway for existing files
   - Skips duplicates automatically

### File Processing

1. **Upload:**
   - Uploads file to Gateway
   - Gateway stores in MinIO object storage
   - Returns file metadata and SHA256

2. **Text Extraction:**
   - **Text files:** Direct read
   - **PDF:** Uses PDF parser
   - **Images:** OCR extraction (if enabled)

3. **Image Enrichment:**
   - OCR for text in images
   - Optional captioning via Ollama
   - Entity detection

4. **Document Creation:**
   - Creates document with extracted text
   - Links file attachment
   - Adds metadata (tags, timestamps, filename)

5. **Post-Processing:**
   - Moves file to `move-to` directory (if configured)
   - Or deletes file (if `--delete-after`)
   - Updates state file with processed file hash

## Configuration

### Environment Variables

See [Configuration Reference](../reference/configuration.md) for complete list. Key variables:

- `AUTH_TOKEN` - Gateway API authentication
- `GATEWAY_URL` - Gateway API base URL
- `LOCALFS_MAX_FILE_MB` - Maximum file size (default: 100 MB)
- `LOCALFS_REQUEST_TIMEOUT` - HTTP timeout (default: 300 seconds)

### Haven.app Configuration

Configure via Settings (`⌘,`) → Local Files Collector:

```yaml
collectors:
  localfs:
    enabled: true
    watch_dir: "~/HavenInbox"
    include: ["*.txt", "*.md", "*.pdf", "*.png", "*.jpg"]
    exclude: ["*.tmp", "*.log"]
    move_to: "~/.haven/localfs/processed"
    delete_after: false
    tags: ["inbox"]
```

**Per-Collector Enrichment:**

Control enrichment behavior for Local Files collector via Settings (`⌘,`) → Enrichment Settings:

- **Skip Enrichment**: When enabled, file documents are submitted without OCR, face detection, entity extraction, or captioning
- **Default**: Enrichment is enabled (skipEnrichment: false)

Global enrichment module settings (OCR quality, entity types, captioning models) are configured in Advanced Settings. See [Configuration Reference](../reference/configuration.md#enrichment-configuration) for details.

### File Patterns

Use glob patterns for include/exclude:

- `*.txt` - All .txt files
- `*.pdf` - All PDF files
- `**/*.md` - All .md files recursively
- `*.tmp` - Exclude .tmp files
- `test_*` - Files starting with "test_"

## State Management

### State File

State is tracked in `~/Library/Application Support/Haven/State/localfs_collector_state.json`:

```json
{
  "processed_files": {
    "sha256_hash": {
      "path": "/full/path/to/file",
      "processed_at": "2024-01-01T12:00:00Z"
    }
  }
}
```

### Resetting State

To reprocess all files:

```bash
# Remove state file
rm ~/Library/Application\ Support/Haven/State/localfs_collector_state.json

# Run collector (will process all files)
# In Haven.app: Collectors → Local Files → Run
```

**Warning:** This will re-upload all files. Use with caution.

## Workflow Examples

### Inbox Processing

Set up an inbox directory for manual file drops:

```bash
# Create inbox
mkdir -p ~/HavenInbox

# Configure collector to watch inbox
# In Haven.app: Settings → Local Files → Watch Directory: ~/HavenInbox

# Drop files into inbox
cp document.pdf ~/HavenInbox/

# Collector automatically processes and moves files
```

### Automated Document Sync

Watch a shared directory:

```bash
python scripts/collectors/collector_localfs.py \
  --watch ~/Documents/Shared \
  --include "*.pdf" \
  --include "*.docx" \
  --tags "shared,work"
```

### One-Time Import

Process existing files:

```bash
python scripts/collectors/collector_localfs.py \
  --watch ~/OldDocuments \
  --one-shot \
  --delete-after
```

## Troubleshooting

### Files Not Processing

**Issue:** Files in watch directory not being processed

**Solutions:**
- Check include/exclude patterns match files
- Verify file types are supported
- Check state file for already-processed files
- Review collector logs for errors
- Ensure collector is running (check Haven.app status)

### Permission Errors

**Error:** Cannot read files

**Solution:**
- Verify read permissions on watch directory
- Check file permissions
- On macOS: ensure Full Disk Access if needed

### Large File Errors

**Error:** File too large

**Solution:**
- Increase `LOCALFS_MAX_FILE_MB` environment variable
- Or split large files before processing
- Default limit is 100 MB

### Duplicate Files

**Issue:** Same file processed multiple times

**Solution:**
- Check state file is being updated
- Verify SHA256 hashing is working
- Check for multiple collector instances
- Review Gateway deduplication logs

## Performance Considerations

### File Size Limits

- **Small files (< 1 MB):** Fast processing
- **Medium files (1-10 MB):** Moderate processing time
- **Large files (10-100 MB):** Slower, consider splitting
- **Very large files (> 100 MB):** May timeout, increase `LOCALFS_REQUEST_TIMEOUT`

### Batch Processing

The collector processes files one at a time. For large directories:
- Use `--one-shot` for initial import
- Then enable continuous watching
- Consider processing in smaller batches

### Network Considerations

- Files are uploaded to Gateway
- Ensure sufficient bandwidth for large files
- Consider local Gateway for faster uploads

## Related Documentation

- [Configuration Reference](../reference/configuration.md) - Environment variables
- [Haven.app Guide](../havenui.md) - App usage
- [Functional Guide](../reference/functional_guide.md) - Ingestion workflows

