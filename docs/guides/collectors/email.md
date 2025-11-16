# Email Collectors

Haven supports two email collection methods: IMAP for remote mailboxes and local Mail.app for macOS email clients.

## Overview

Email collectors:
- Extract emails from IMAP servers or macOS Mail.app
- Preserve email structure (threads, attachments, metadata)
- Enrich attachments with OCR and captioning
- Link emails to contacts and conversations

## Prerequisites

- macOS (for Mail.app collector)
- IMAP access (for IMAP collector)
- Gateway API running and accessible

## IMAP Collector

The IMAP collector fetches emails directly from IMAP servers.

### Using Haven.app

1. **Configure IMAP Account:**
   - Open Settings (`⌘,`)
   - Navigate to Email Collector → IMAP
   - Configure:
     - Server hostname
     - Port (usually 993 for SSL)
     - Username
     - Password or app-specific password
     - Folders to sync (e.g., INBOX, Sent)

2. **Run Collector:**
   - Open Collectors window (`⌘2`)
   - Select Email collector
   - Click "Run"

### Configuration

**Haven.app Settings:**

```yaml
collectors:
  email:
    imap:
      enabled: true
      server: "imap.example.com"
      port: 993
      tls: true
      username: "user@example.com"
      password: "password"  # or use keychain reference
      folders:
        - "INBOX"
        - "Sent"
        - "Receipts"
```

**Authentication:**

- **Password:** Direct password (stored securely)
- **App Password:** For accounts with 2FA
- **OAuth2:** XOAUTH2 support (via keychain)

### IMAP Collector Details

The IMAP collector:
- Connects to IMAP server
- Fetches emails from specified folders
- Processes emails in batches
- Handles attachments and inline content
- Preserves email threading

**Supported Features:**
- Multiple folders
- SSL/TLS encryption
- App-specific passwords
- OAuth2 authentication
- Attachment extraction

**Limitations:**
- Requires MailCore2 framework (x86_64, Rosetta on Apple Silicon)
- Messages kept in-memory during processing
- Large mailboxes may take time

## Local Mail.app Collector

The local collector reads emails from macOS Mail.app's local cache.

### Using Haven.app

1. **Configure Mail.app Collector:**
   - Open Settings (`⌘,`)
   - Navigate to Email Collector → Local
   - Configure:
     - Mail data directory (usually `~/Library/Mail`)
     - Account selection
     - Folders to sync

2. **Run Collector:**
   - Open Collectors window (`⌘2`)
   - Select Email collector
   - Click "Run"

### Configuration

**Haven.app Settings:**

```yaml
collectors:
  email:
    local:
      enabled: true
      mail_directory: "~/Library/Mail"
      accounts:
        - "iCloud"
        - "Gmail"
      folders:
        - "INBOX"
        - "Sent Messages"
```

### Mail.app Collector Details

The local collector:
- Reads `.emlx` files from Mail.app cache
- Extracts email content and metadata
- Processes attachments
- Preserves folder structure

**File Structure:**

Mail.app stores emails in:
```
~/Library/Mail/
  └── V[version]/
      └── [Account]/
          └── [Mailbox]/
              └── [UID].emlx
```

**Supported Formats:**
- `.emlx` - Mail.app message format
- Extracts headers, body, attachments
- Preserves threading via Message-ID

## How Email Collection Works

### Email Processing

1. **Email Extraction:**
   - Reads email from source (IMAP or Mail.app)
   - Extracts headers, body, attachments
   - Parses MIME structure

2. **Metadata Extraction:**
   - From, To, CC, BCC addresses
   - Subject, Date, Message-ID
   - Threading information
   - Folder/mailbox name

3. **People Resolution:**
   - Normalizes email addresses
   - Links to `people` table
   - Creates `document_people` relationships

4. **Attachment Processing:**
   - Extracts attachments
   - Uploads to Gateway/MinIO
   - Enriches images with OCR
   - Links to email document

5. **Document Creation:**
   - Creates document with email content
   - Links to thread (if applicable)
   - Adds metadata (source, folder, date)
   - Creates chunks for search

### Threading

Emails are linked via:
- **Message-ID:** Original message identifier
- **In-Reply-To:** Parent message
- **References:** Thread chain
- **Subject:** Thread matching (fallback)

### Deduplication

Emails are deduplicated by:
- Message-ID (if present)
- Content hash
- Source + external ID

## Configuration

### Environment Variables

See [Configuration Reference](../reference/configuration.md) for complete list. Key variables:

- `AUTH_TOKEN` - Gateway API authentication
- `GATEWAY_URL` - Gateway API base URL
- `OLLAMA_ENABLED` - Enable image captioning
- `OLLAMA_API_URL` - Ollama server URL

### Haven.app Configuration

**Per-Collector Enrichment:**

Control enrichment behavior for Email collector via Settings (`⌘,`) → Enrichment Settings:

- **Skip Enrichment**: When enabled, email documents are submitted without OCR, face detection, entity extraction, or captioning
- **Default**: Enrichment is enabled (skipEnrichment: false)

Global enrichment module settings (OCR quality, entity types, captioning models) are configured in Advanced Settings. See [Configuration Reference](../reference/configuration.md#enrichment-configuration) for details.

### IMAP Configuration

**Server Settings:**

| Provider | Server | Port | TLS |
|----------|--------|------|-----|
| Gmail | `imap.gmail.com` | 993 | Yes |
| iCloud | `imap.mail.me.com` | 993 | Yes |
| Outlook | `outlook.office365.com` | 993 | Yes |
| Yahoo | `imap.mail.yahoo.com` | 993 | Yes |

**App Passwords:**

For accounts with 2FA, use app-specific passwords:
- Gmail: Settings → Security → App passwords
- iCloud: appleid.apple.com → App-Specific Passwords
- Outlook: Security → App passwords

### Mail.app Configuration

**Default Mail Directory:**
- `~/Library/Mail` - Standard location
- `~/Library/Mail/V[version]` - Version-specific

**Account Discovery:**
- Automatically discovers accounts
- Lists available mailboxes
- Can filter by account name

## Troubleshooting

### IMAP Connection Issues

**Error:** Cannot connect to IMAP server

**Solutions:**
- Verify server hostname and port
- Check SSL/TLS settings
- Verify credentials
- Check firewall/network settings
- Try app-specific password for 2FA accounts

### Mail.app Access Issues

**Error:** Cannot read Mail.app data

**Solutions:**
- Grant Full Disk Access permission
- Verify Mail.app directory path
- Check file permissions
- Ensure Mail.app is not running (may lock files)

### Missing Emails

**Issue:** Some emails not being collected

**Solutions:**
- Check folder configuration
- Verify email filters
- Review deduplication logs
- Check for permission issues
- Verify email format is supported

### Attachment Issues

**Error:** Attachments not processing

**Solutions:**
- Check attachment size limits
- Verify Gateway/MinIO is accessible
- Review attachment extraction logs
- Check for corrupted attachments

## Performance Considerations

### IMAP Collector

- **Batch Size:** Process emails in batches (default: 50)
- **Folders:** Limit folders for faster syncs
- **Date Range:** Use date filters for initial sync
- **Network:** Ensure stable connection

### Mail.app Collector

- **Large Mailboxes:** May take time for initial sync
- **Incremental:** Faster after initial sync
- **File Access:** Reading `.emlx` files is I/O intensive

### General Tips

- Start with recent emails (date filter)
- Process in smaller batches for large mailboxes
- Use incremental sync after initial import
- Monitor memory usage for large attachments

## Related Documentation

- [Configuration Reference](../reference/configuration.md) - Environment variables
- [Haven.app Guide](../havenui.md) - App usage
- [Functional Guide](../reference/functional_guide.md) - Ingestion workflows
- [Email Utilities](../hostagent/email-utilities.md) - Advanced email processing

