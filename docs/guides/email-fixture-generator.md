# Email Fixture Generator

The email fixture generator (`scripts/generate_email_fixtures.py`) creates realistic test data for the Haven email collector that simulates a real Mail.app environment. It supports both **synthetic email generation** and **importing real user emails**.

## Overview

The generator creates a complete email testing environment including:

1. **`.emlx` files** - RFC 2822 formatted email messages (Mail.app format)
2. **Envelope Index** - SQLite database simulating Mail.app's message metadata
3. **Catalog** - JSON metadata for all generated emails
4. **README** - Documentation for the generated fixture set
5. **Attachments** (when importing) - Copied from source Mail.app cache

## Features

### Synthetic Generation
- **Multiple email types**: Receipts, bills, appointments, notifications, action requests, promotional
- **Realistic content**: Order numbers, account numbers, tracking codes, dates, amounts
- **Intent classification**: Each email is tagged with its primary intent
- **Noise filtering**: Configurable ratio of promotional/spam emails
- **Mailbox organization**: Emails categorized into Inbox, Receipts, Bills, Junk, etc.
- **Threading support**: Reply-To and References headers for conversation threads
- **Multipart MIME**: Plain text + HTML bodies with proper MIME boundaries
- **Attachments**: Placeholder attachment support in .emlx files
- **PII patterns**: Account numbers, phone numbers, addresses for redaction testing

### Real Email Import
- **Parse existing .emlx files**: Import from Mail.app cache or other sources
- **Convert .eml files**: Automatically converts standard RFC 2822 .eml files to .emlx format
- **Automatic intent classification**: Analyzes subject/body to determine email type
- **Noise detection**: Identifies promotional emails via List-Unsubscribe headers and keywords
- **Attachment handling**: Copies attachments from Mail.app cache structure
- **Metadata extraction**: Parses headers, dates, threading information
- **Configurable limits**: Control how many emails to import
- **Preserves original data**: Copies files without modification (converts .eml to .emlx)

## Quick Start

### Generate Synthetic Emails

#### Minimal Fixture Set (10 emails)

```bash
python scripts/generate_email_fixtures.py --output tests/fixtures/email_minimal --preset minimal
```

#### Realistic Fixture Set (100 emails)

```bash
python scripts/generate_email_fixtures.py --output tests/fixtures/email --preset realistic
```

#### Stress Test Fixture Set (1000 emails)

```bash
python scripts/generate_email_fixtures.py --output tests/fixtures/email_stress --preset stress
```

### Import Real User Emails

#### Import from Mail.app Cache

```bash
# Import all emails from a Mail.app Messages directory
python scripts/generate_email_fixtures.py \
  --output ~/.haven/fixtures/my_emails \
  --import-from ~/Library/Mail/V10/Messages

# Import limited number (e.g., first 50 emails)
python scripts/generate_email_fixtures.py \
  --output ~/.haven/fixtures/sample \
  --import-from ~/Library/Mail/V10/Messages \
  --limit 50
```

#### Import from .eml Files

Standard .eml files (RFC 2822 format) are automatically converted to .emlx format:

```bash
# Import from a directory containing .eml files
python scripts/generate_email_fixtures.py \
  --output ~/.haven/fixtures/exported_emails \
  --import-from ~/Downloads/exported_emails

# Works with mixed .eml and .emlx files
python scripts/generate_email_fixtures.py \
  --output ~/.haven/fixtures/mixed \
  --import-from ~/email_backup \
  --limit 100
```

The script automatically detects file types and converts .eml to .emlx format during import.

#### Import Without Attachments

```bash
# Skip attachment copying to save space
python scripts/generate_email_fixtures.py \
  --output ~/.haven/fixtures/no_attachments \
  --import-from ~/Library/Mail/V10/Messages \
  --no-attachments
```

### Custom Synthetic Configuration

```bash
python scripts/generate_email_fixtures.py \
  --output ~/.haven/fixtures/email \
  --count 250 \
  --noise 0.3 \
  --start-date 2025-01-01T00:00:00Z
```

## Command-Line Options

| Option | Short | Default | Description |
|--------|-------|---------|-------------|
| `--output` | `-o` | Required | Output directory for fixtures |
| `--import-from` | | None | Import real .emlx files from this directory (disables synthetic generation) |
| `--limit` | | None | Maximum number of emails to import (only with `--import-from`) |
| `--no-attachments` | | False | Skip copying attachments when importing (only with `--import-from`) |
| `--count` | `-c` | 50 | Number of emails to generate (ignored with `--import-from`) |
| `--noise` | `-n` | 0.2 | Ratio of promotional/spam emails (0.0-1.0, ignored with `--import-from`) |
| `--preset` | `-p` | None | Use preset configuration: minimal/realistic/stress (ignored with `--import-from`) |
| `--start-date` | | 90 days ago | Start date for email timestamps (ISO format, ignored with `--import-from`) |

## Import Mode vs Generate Mode

The script operates in two mutually exclusive modes:

### Generate Mode (Default)
When `--import-from` is **not** specified, the script generates synthetic emails based on templates.

**Use cases:**
- Creating test fixtures for CI/CD pipelines
- Generating consistent, repeatable test data
- Testing with specific email patterns and intents
- Stress testing with large volumes of data

**Configuration:** `--count`, `--noise`, `--preset`, `--start-date`

### Import Mode
When `--import-from` is specified, the script imports real .emlx files from the given directory.

**Use cases:**
- Testing with real user data (privacy-preserving development copy)
- Validating collector behavior against actual Mail.app emails
- Debugging specific email formats or edge cases
- Creating fixtures from a subset of production data

**Configuration:** `--limit`, `--no-attachments`

**Import process:**
1. Recursively scans source directory for `.emlx` files
2. Parses each file to extract headers, body, and attachments
3. Classifies intent based on subject/body keywords
4. Detects noise/promotional emails via List-Unsubscribe headers
5. Copies files to output directory with sequential numbering
6. Optionally copies attachments from parallel Attachments/ directory
7. Creates Envelope Index database with metadata
8. Generates catalog.json with extracted metadata
| `--count` | `-c` | 50 | Number of emails to generate |
| `--noise` | `-n` | 0.2 | Ratio of promotional/spam emails (0.0-1.0) |
| `--preset` | `-p` | None | Use preset configuration (minimal/realistic/stress) |
| `--start-date` | | 90 days ago | Start date for email timestamps (ISO format) |

## Presets

### Minimal (10 emails, 10% noise)
Best for quick tests and CI pipelines.

```bash
--preset minimal
```

### Realistic (100 emails, 25% noise)
Simulates a typical user's mailbox over 90 days.

```bash
--preset realistic
```

### Stress (1000 emails, 30% noise)
For performance testing and large-scale validation.

```bash
--preset stress
```

## Privacy and Security for Imported Emails

When using `--import-from` to import real user emails, follow these guidelines to protect privacy:

### Best Practices

1. **Use a sanitized copy**: Never point directly at your live Mail.app database
   ```bash
   # Create a working copy first
   cp -R ~/Library/Mail/V10/Messages /tmp/mail_copy
   python scripts/generate_email_fixtures.py \
     --output ./fixtures --import-from /tmp/mail_copy --limit 50
   ```

2. **Limit sensitive data**: Use `--limit` to import only a small sample
   ```bash
   # Import just 10-20 emails for testing
   --limit 20
   ```

3. **Exclude attachments with PII**: Use `--no-attachments` if attachments may contain sensitive data
   ```bash
   --no-attachments
   ```

4. **Store fixtures securely**: 
   - Add imported fixtures to `.gitignore`
   - Store in `~/.haven/fixtures/` or `.tmp/` directories
   - Never commit real user data to version control

5. **Review imported data**: Check catalog.json to ensure no sensitive PII before sharing
   ```bash
   # Review what was imported
   cat output_dir/catalog.json | less
   ```

### Privacy Considerations

The import process extracts:
- ✓ Email headers (From, To, Subject, Date, Message-ID)
- ✓ Email body content (plain text and HTML)
- ✓ Attachment metadata (filenames, sizes, content types)
- ✓ Optional: Attachment file content

**Does NOT modify**: Original .emlx files are copied as-is without modification.

**Recommended for testing**: Use synthetic generation mode instead of importing real emails when possible. Only use `--import-from` when you need to test against actual email formats or edge cases.

## Output Structure

```
output_dir/
├── Messages/              # .emlx files
│   ├── 1.emlx
│   ├── 2.emlx
│   └── ...
├── Attachments/          # (only when importing with --import-from)
│   ├── 1/
│   │   ├── document.pdf
│   │   └── image.jpg
│   └── 2/
│       └── receipt.pdf
├── Envelope Index         # SQLite database
├── catalog.json          # Metadata catalog
└── README.md            # Usage documentation
```

### .emlx File Format

Each `.emlx` file follows Mail.app's format:

```
<byte_count>
From: sender@example.com
To: recipient@example.com
Subject: Example Email
Date: Thu, 21 Oct 2025 10:00:00 -0400
Message-ID: <unique123@example.com>
Content-Type: text/plain; charset=utf-8

Email body content here...
```

The first line contains the byte count of the message content (excluding the first line).

### Envelope Index Database

SQLite database with Mail.app-compatible schema:

```sql
-- Messages table
CREATE TABLE messages (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id TEXT,
    subject TEXT,
    sender TEXT,
    date_received INTEGER,  -- Unix timestamp
    date_sent INTEGER,
    mailbox TEXT,
    read INTEGER,
    flagged INTEGER,
    deleted INTEGER,
    junk INTEGER,
    remote_id TEXT,
    original_mailbox TEXT
);

-- Mailboxes table
CREATE TABLE mailboxes (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT,
    name TEXT
);
```

### Catalog JSON

The catalog provides structured metadata for all emails:

```json
{
  "generated_at": "2025-10-21T19:27:04.465271+00:00",
  "total_emails": 100,
  "stats": {
    "intents": {
      "receipt": 13,
      "bill": 17,
      "appointment": 16,
      "notification": 19,
      "action_request": 10,
      "promotional": 25
    },
    "noise_emails": 25,
    "signal_emails": 75
  },
  "emails": [
    {
      "index": 1,
      "path": "/path/to/Messages/1.emlx",
      "message_id": "<receipt0@example.com>",
      "subject": "Order Confirmation - ORD-2025-10000",
      "from": "orders@shop.example.com",
      "to": "customer@example.com",
      "date": "2025-07-24T10:13:04+00:00",
      "intent": "receipt",
      "is_noise": false,
      "has_attachment": false,
      "size": 1408
    }
  ]
}
```

## Usage with Email Collector

### HostAgent Simulate Mode

The primary use case is testing with HostAgent's simulate mode:

```bash
curl -X POST http://localhost:7090/v1/collectors/email_local:run \
  -H "Content-Type: application/json" \
  -H "x-auth: changeme" \
  -d '{
        "mode": "simulate",
        "simulate_path": "/path/to/fixtures/Messages",
        "limit": 100
      }'
```

### Python Collector (when implemented)

```python
from scripts.collectors import collector_email_local

# Indexed mode (using Envelope Index database)
collector_email_local.run_indexed_mode(
    envelope_index_path="/path/to/fixtures/Envelope Index",
    emlx_root="/path/to/fixtures/Messages"
)

# Crawler mode (scanning .emlx files directly)
collector_email_local.run_crawler_mode(
    emlx_root="/path/to/fixtures/Messages"
)
```

### Integration Tests

```python
import tempfile
from pathlib import Path
from scripts import generate_email_fixtures as gen

def test_email_collector_end_to_end():
    with tempfile.TemporaryDirectory() as tmpdir:
        output_dir = Path(tmpdir)
        
        # Generate test fixtures
        templates = gen.generate_templates(count=20, noise_ratio=0.2)
        messages_dir = output_dir / 'Messages'
        messages_dir.mkdir()
        
        metadata_list = []
        for i, template in enumerate(templates):
            date = datetime.now(timezone.utc) - timedelta(days=i)
            metadata = gen.write_emlx_file(messages_dir, i, template, date)
            metadata_list.append(metadata)
        
        # Run collector against fixtures
        result = run_collector(messages_dir)
        
        # Assertions...
        assert result.success
        assert result.processed_count == 20
```

## Email Types and Templates

### Receipt Emails
- **Intent**: `receipt`
- **Content**: Order numbers (ORD-2025-XXXXX), amounts, item lists
- **Mailbox**: Inbox/Receipts
- **Example subjects**: "Order Confirmation - ORD-2025-10000"

### Bill/Statement Emails
- **Intent**: `bill`
- **Content**: Account numbers (****XXXX), due dates, amounts
- **Mailbox**: Inbox/Bills
- **Attachments**: Sometimes includes statement.pdf
- **Example subjects**: "Your Monthly Statement is Ready - Due 2025-11-05"

### Appointment Emails
- **Intent**: `appointment`
- **Content**: Dates, times, locations, confirmation numbers
- **Threading**: Includes In-Reply-To and References headers
- **Mailbox**: Inbox
- **Example subjects**: "Appointment Confirmation"

### Notification Emails
- **Intent**: `notification`
- **Content**: Tracking numbers, shipping updates, account activity
- **Mailbox**: Inbox
- **Example subjects**: "Your package has shipped!"

### Action Request Emails
- **Intent**: `action_request`
- **Content**: Verification codes, password resets, confirmation links
- **Mailbox**: Inbox
- **Example subjects**: "Verify Your Email Address"

### Promotional Emails (Noise)
- **Intent**: `promotional`
- **Is Noise**: True
- **Content**: Sale announcements, newsletters, marketing
- **Headers**: Includes List-Unsubscribe
- **Mailbox**: Junk or Promotions
- **Example subjects**: "🎉 Weekly Newsletter - 50% Off Sale!"

## Testing Best Practices

### Unit Tests

Test individual components with minimal fixtures:

```python
def test_parse_receipt_email():
    """Test parsing a single receipt email"""
    # Generate single fixture
    template = gen.create_receipt_template(0, datetime.now())
    
    with tempfile.TemporaryDirectory() as tmpdir:
        metadata = gen.write_emlx_file(Path(tmpdir), 0, template, datetime.now())
        
        # Parse and assert
        parsed = parse_emlx(metadata['path'])
        assert parsed.intent == 'receipt'
        assert 'ORD-' in parsed.body
```

### Integration Tests

Test full pipeline with realistic fixtures:

```python
def test_collector_indexed_mode():
    """Test collector with Envelope Index"""
    # Use realistic preset
    fixtures = generate_fixture_set(preset='realistic')
    
    # Run collector
    result = collector.run_indexed_mode(fixtures.db_path, fixtures.messages_dir)
    
    # Verify ingestion
    assert result.processed == 100
    assert result.errors == 0
```

### Performance Tests

Use stress preset for benchmarking:

```python
def test_collector_performance():
    """Benchmark collector with large fixture set"""
    fixtures = generate_fixture_set(preset='stress')  # 1000 emails
    
    start = time.time()
    result = collector.run(fixtures.messages_dir)
    duration = time.time() - start
    
    # Performance assertions
    assert duration < 60  # Should complete within 60 seconds
    assert result.processed == 1000
```

## Fixture Maintenance

### Regenerating Fixtures

Fixtures should be regenerated when:
- Email templates change
- New intent types are added
- Mail.app format changes
- Database schema updates

```bash
# Regenerate test fixtures
python scripts/generate_email_fixtures.py \
  --output tests/fixtures/email \
  --preset realistic

# Commit updated fixtures
git add tests/fixtures/email/
git commit -m "Update email test fixtures"
```

### Version Control

**Include in Git:**
- Generator script (`scripts/generate_email_fixtures.py`)
- Tests (`tests/test_generate_email_fixtures.py`)
- Small fixture sets (< 20 emails) for CI

**Exclude from Git:**
- Large fixture sets (> 100 emails)
- Temporary test fixtures in `.tmp/`

Add to `.gitignore`:
```
.tmp/
tests/fixtures/email_stress/
```

## Troubleshooting

### Issue: "No .emlx files found"

**Cause**: Output directory doesn't contain Messages subdirectory

**Solution**: The generator automatically creates `Messages/` subdirectory. Point HostAgent to the full path:
```bash
--simulate_path="/full/path/to/fixtures/Messages"
```

### Issue: "Database file is locked"

**Cause**: Envelope Index database is in use by another process

**Solution**: Close any SQLite viewers or wait for tests to complete

### Issue: "Fixtures don't match real Mail.app behavior"

**Cause**: Mail.app format or schema has changed

**Solution**: 
1. Export real .emlx files from Mail.app
2. Compare with generated fixtures
3. Update generator templates to match
4. Submit PR with improvements

## Contributing

### Adding New Email Types

1. Create a new template function:

```python
def create_invoice_template(index: int, base_date: datetime) -> EmailTemplate:
    """Generate an invoice email template"""
    return EmailTemplate(
        subject=f"Invoice #{1000 + index}",
        from_addr="billing@company.com",
        to_addr="customer@example.com",
        body_plain="Your invoice is ready...",
        intent="invoice",
        # ...
    )
```

2. Add to `TEMPLATE_GENERATORS`:

```python
TEMPLATE_GENERATORS = [
    create_receipt_template,
    create_bill_template,
    create_invoice_template,  # New
    # ...
]
```

3. Add tests:

```python
def test_create_invoice_template():
    template = gen.create_invoice_template(0, datetime.now())
    assert template.intent == "invoice"
    assert "Invoice #" in template.subject
```

4. Update documentation

### Improving Realism

- Study real email patterns from various services
- Add more varied formatting (tables, lists, etc.)
- Include edge cases (malformed headers, missing fields)
- Add international addresses and unicode content
- Include more realistic attachment types

## See Also

- [Email Collector Documentation](./email-collector.md)
- [HostAgent API Reference](../hostagent/index.md)
- [Testing Guide](../contributing.md#testing)
- Haven-25: Local Email Collector Epic (beads)
- Haven-35: Email Collector Test Suite (beads)
