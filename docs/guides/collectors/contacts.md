# Contacts Collector

The Contacts collector syncs macOS Contacts and VCF files into Haven for people normalization and relationship tracking.

## Overview

The Contacts collector:
- Exports contacts from macOS Contacts.app
- Imports VCF (vCard) files
- Normalizes phone numbers and email addresses
- Creates unified person records in Haven
- Links contacts to messages and documents

## Prerequisites

- macOS (for Contacts.app access)
- Contacts permission (for macOS Contacts)
- Gateway API running and accessible

## Using Haven.app (Recommended)

Haven.app provides the easiest way to run the Contacts collector:

1. **Launch Haven.app**

2. **Grant Permissions:**
   - System Settings → Privacy & Security → Contacts
   - Enable Haven.app
   - Restart Haven.app if already running

3. **Configure Collector:**
   - Open Settings (`⌘,`)
   - Navigate to Contacts Collector
   - Configure options:
     - Enable/disable collector
     - VCF import directory (optional)
     - Sync mode (full/incremental)

4. **Run Collector:**
   - Open Collectors window (`⌘2`)
   - Select Contacts collector
   - Click "Run" or use menu "Run All Collectors"

5. **Monitor Progress:**
   - View Dashboard (`⌘1`) for activity log
   - Check contacts imported count
   - Review any errors

## Using CLI (Alternative)

For environments without Haven.app:

### Basic Usage

```bash
# Set authentication
export AUTH_TOKEN="changeme"
export GATEWAY_URL="http://localhost:8085"

# Run collector (exports macOS Contacts)
python scripts/collectors/collector_contacts.py
```

### Options

| Flag | Description |
|------|-------------|
| `--vcf-dir DIR` | Import VCF files from directory |
| `--full-sync` | Force full sync (ignore change tokens) |
| `--batch-size N` | Process N contacts per batch |

### Examples

```bash
# Import VCF files
python scripts/collectors/collector_contacts.py --vcf-dir ~/Contacts/vcf

# Full sync
python scripts/collectors/collector_contacts.py --full-sync

# Custom batch size
python scripts/collectors/collector_contacts.py --batch-size 50
```

## How It Works

### macOS Contacts Export

1. **Permission Check:**
   - Requests Contacts permission if not granted
   - Uses macOS Contacts framework (pyobjc)

2. **Contact Extraction:**
   - Reads all contacts from Contacts.app
   - Extracts names, emails, phones, organizations
   - Preserves contact metadata

3. **Normalization:**
   - Phone numbers → E.164 format
   - Email addresses → lowercase
   - Names → structured format (first, last, display)

4. **Batch Processing:**
   - Groups contacts into batches
   - Sends to Gateway API
   - Gateway forwards to Catalog

5. **People Repository:**
   - Catalog uses `PeopleRepository` for deduplication
   - Merges contacts with matching identifiers
   - Creates/updates person records

### VCF Import

1. **File Discovery:**
   - Scans VCF directory for `.vcf` files
   - Processes each file

2. **Parsing:**
   - Parses vCard format
   - Extracts contact information
   - Handles multiple contacts per file

3. **Ingestion:**
   - Same normalization and processing as Contacts export
   - Creates unified person records

### Change Token Tracking

The collector tracks changes for incremental sync:

- **State File:** `~/.haven/contacts_collector_state.json`
- **Database:** `source_change_tokens` table
- **Incremental Sync:** Only processes new/changed contacts

## People Normalization

Contacts are normalized into the `people` table:

### Identifier Normalization

- **Phone Numbers:**
  - Converted to E.164 format (+1234567890)
  - Handles various input formats
  - Preserves country code

- **Email Addresses:**
  - Lowercased
  - Trimmed whitespace
  - Validated format

### Deduplication

The `PeopleRepository` handles merging:

- **Matching Criteria:**
  - Same email address
  - Same phone number
  - Similar names (fuzzy matching)

- **Merge Behavior:**
  - Combines identifiers from both contacts
  - Preserves all names and metadata
  - Updates `document_people` links

### Person Records

Each contact becomes a person record:

```json
{
  "id": "uuid",
  "display_name": "John Doe",
  "first_name": "John",
  "last_name": "Doe",
  "identifiers": [
    {"type": "email", "value": "john@example.com"},
    {"type": "phone", "value": "+1234567890"}
  ],
  "organization": "Example Corp"
}
```

## Configuration

### Environment Variables

See [Configuration Reference](../reference/configuration.md) for complete list. Key variables:

- `AUTH_TOKEN` - Gateway API authentication
- `GATEWAY_URL` - Gateway API base URL
- `CATALOG_TOKEN` - Optional Catalog API token

### Haven.app Configuration

Configure via Settings (`⌘,`) → Contacts Collector:

```yaml
collectors:
  contacts:
    enabled: true
    vcf_directory: "~/Contacts/vcf"
    sync_mode: "incremental"  # or "full"
```

**Enrichment:**

The Contacts collector always skips enrichment (OCR, face detection, entity extraction, captioning) as contacts don't require these processing steps. This is automatically configured and cannot be changed.

### VCF Directory Structure

Place VCF files in the configured directory:

```
~/Contacts/vcf/
  ├── contacts.vcf
  ├── work-contacts.vcf
  └── family.vcf
```

Each `.vcf` file can contain one or more contacts.

## State Management

### State File

State is tracked in `~/Library/Application Support/Haven/State/contacts_collector_state.json`:

```json
{
  "last_sync_token": "abc123",
  "last_sync_at": "2024-01-01T12:00:00Z",
  "contacts_processed": 150
}
```

### Change Tokens

The collector uses change tokens for incremental sync:

- **macOS Contacts:** Uses Contacts framework change tokens
- **VCF Files:** Tracks file modification times
- **Database:** Stores in `source_change_tokens` table

### Resetting State

To force full re-sync:

```bash
# Remove state file
rm ~/Library/Application\ Support/Haven/State/contacts_collector_state.json

# Run collector (will process all contacts)
# In Haven.app: Collectors → Contacts → Run
```

**Warning:** This will re-process all contacts. Use with caution.

## Integration with Messages

Contacts are automatically linked to messages:

1. **Message Ingestion:**
   - iMessage collector extracts phone numbers and emails
   - Gateway normalizes identifiers

2. **People Resolution:**
   - Catalog uses `PeopleResolver` to match identifiers
   - Links messages to person records via `document_people`

3. **Relationship Tracking:**
   - Relationship scoring uses contact information
   - Enhances relationship strength calculations

## Troubleshooting

### Permission Issues

**Error:** Cannot access Contacts

**Solution:**
1. System Settings → Privacy & Security → Contacts
2. Enable Haven.app
3. Restart Haven.app

### VCF Import Issues

**Error:** VCF files not importing

**Solutions:**
- Verify VCF directory path is correct
- Check file permissions
- Validate VCF file format
- Review collector logs for parsing errors

### Duplicate Contacts

**Issue:** Same contact imported multiple times

**Solution:**
- People normalization handles deduplication
- Check `people` table for merged records
- Review `person_identifiers` for all identifiers
- Verify change token tracking is working

### Missing Contacts

**Issue:** Some contacts not appearing

**Solutions:**
- Check Contacts.app permissions
- Verify contacts have email or phone
- Review normalization logs
- Check for filtering in PeopleRepository

## Performance Considerations

### Batch Size

- **Small batches (10-25):** Slower but lower memory
- **Medium batches (50-100):** Good balance (default)
- **Large batches (200+):** Faster but higher memory

### Full vs Incremental Sync

- **Incremental:** Fast, only processes changes
- **Full:** Slower, processes all contacts
- Use incremental for regular syncs
- Use full sync after major changes

### Large Contact Lists

For large contact lists (1000+):
- Use incremental sync when possible
- Increase batch size for faster processing
- Monitor memory usage
- Consider splitting VCF imports

## Related Documentation

- [Configuration Reference](../reference/configuration.md) - Environment variables
- [Haven.app Guide](../havenui.md) - App usage
- [Functional Guide](../reference/functional_guide.md) - People workflows
- [Relationship Features](../reference/relationship_features.md) - Relationship tracking

