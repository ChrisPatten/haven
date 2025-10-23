# Mail.app Cache Structure and .emlx Format

## Research Documentation for Haven Email Collector (haven-26)

**Author:** Research Task  
**Date:** October 20, 2025  
**Purpose:** Document Mail.app local cache structure to inform `collector_email_local.py` implementation

---

## Table of Contents

1. [Mail.app Cache Directory Structure](#1-mailapp-cache-directory-structure)
2. [Envelope Index SQLite Database](#2-envelope-index-sqlite-database)
3. [.emlx File Format](#3-emlx-file-format)
4. [Attachment Storage](#4-attachment-storage)
5. [Mailbox Filtering Strategy](#5-mailbox-filtering-strategy)
6. [VIP and List-Unsubscribe Headers](#6-vip-and-list-unsubscribe-headers)
7. [Implementation Patterns](#7-implementation-patterns)
8. [References](#8-references)

---

## 1. Mail.app Cache Directory Structure

### 1.1 Primary Locations

Mail.app stores all local cache data in a versioned directory structure:

```
~/Library/Mail/
├── V{version}/              # Version-specific directory (e.g., V10, V11)
│   ├── MailData/
│   │   ├── Envelope Index  # SQLite database for indexed mode
│   │   ├── Envelope Index-shm
│   │   ├── Envelope Index-wal
│   │   └── ...
│   ├── Mailboxes/          # Mailbox hierarchy with .emlx files
│   │   ├── {Account}/
│   │   │   ├── INBOX.mbox/
│   │   │   │   ├── {guid}.emlx
│   │   │   │   ├── {guid}.emlx
│   │   │   │   └── Messages/
│   │   │   ├── Sent.mbox/
│   │   │   ├── Junk.mbox/
│   │   │   ├── Trash.mbox/
│   │   │   └── Drafts.mbox/
│   │   └── ...
│   └── Attachments/        # Centralized attachment storage
│       └── {message_id}/
│           └── {index}/
│               └── {filename}
└── Bundles/                # Mail plugins
```

### 1.2 Version Detection

The version number in the `V{version}` directory name indicates the Mail.app database format version. Common versions:

- **V10**: macOS Catalina and earlier
- **V11**: macOS Big Sur and later (current as of 2025)

**Implementation Note:** The collector should:
1. Detect the highest version directory present
2. Fall back to earlier versions if the current one is unavailable
3. Handle missing directories gracefully (e.g., no Mail.app configured)

```python
def locate_mail_data_directory() -> Optional[Path]:
    """Find the Mail.app data directory, preferring the highest version."""
    mail_root = Path.home() / "Library" / "Mail"
    if not mail_root.exists():
        return None
    
    # Find all V* directories and sort by version number
    version_dirs = sorted(
        [d for d in mail_root.iterdir() if d.name.startswith("V") and d.is_dir()],
        key=lambda p: int(p.name[1:]) if p.name[1:].isdigit() else 0,
        reverse=True
    )
    
    return version_dirs[0] if version_dirs else None
```

---

## 2. Envelope Index SQLite Database

### 2.1 Database Location

```
~/Library/Mail/V{version}/MailData/Envelope Index
```

This SQLite database provides a centralized index for fast message lookups and is **preferred for Indexed Mode** in the collector.

### 2.2 Key Tables

#### 2.2.1 `messages` Table

The primary table for message metadata:

```sql
CREATE TABLE messages (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id INTEGER NOT NULL DEFAULT 0,
    global_message_id INTEGER NOT NULL,
    remote_id INTEGER,
    document_id TEXT,
    sender INTEGER,                        -- Foreign key to addresses.ROWID
    subject_prefix TEXT,
    subject INTEGER NOT NULL,              -- Foreign key to subjects.ROWID
    summary INTEGER,
    date_sent INTEGER,                     -- Apple epoch timestamp
    date_received INTEGER,                 -- Apple epoch timestamp
    mailbox INTEGER NOT NULL,              -- Foreign key to mailboxes.ROWID
    remote_mailbox INTEGER,
    flags INTEGER NOT NULL DEFAULT 0,
    read INTEGER NOT NULL DEFAULT 0,
    flagged INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0,
    size INTEGER NOT NULL DEFAULT 0,
    conversation_id INTEGER NOT NULL DEFAULT 0,
    date_last_viewed INTEGER,
    list_id_hash INTEGER,
    unsubscribe_type INTEGER,
    searchable_message INTEGER,
    brand_indicator INTEGER,
    display_date INTEGER,
    color TEXT,
    type INTEGER,
    fuzzy_ancestor INTEGER,
    automated_conversation INTEGER DEFAULT 0,
    root_status INTEGER DEFAULT -1,
    flag_color INTEGER,
    is_urgent INTEGER NOT NULL DEFAULT 0
);
```

**Key Columns for Collector:**
- `ROWID`: Primary key for incremental sync (track last seen ROWID)
- `message_id`: Unique identifier
- `sender`: Foreign key to addresses table (use JOIN to get email address)
- `subject`: Foreign key to subjects table (use JOIN to get subject text)
- `date_sent`, `date_received`: Timestamps (Apple epoch: seconds since 2001-01-01)
- `mailbox`: Links to mailboxes table for folder filtering
- `remote_id`: Matches the .emlx filename in the mailbox directory
- `read`, `flagged`: User interaction signals
- `flags`: Bitmask including VIP status (see section 6.1)

**Note:** Recipients (To/Cc/Bcc) are NOT in this table - see `recipients` table below.

#### 2.2.2 `mailboxes` Table

Defines the mailbox hierarchy:

```sql
CREATE TABLE mailboxes (
    ROWID INTEGER PRIMARY KEY,
    url TEXT NOT NULL,                     -- URL to mailbox (e.g., imap://account-id/INBOX)
    total_count INTEGER NOT NULL DEFAULT 0,
    unread_count INTEGER NOT NULL DEFAULT 0,
    deleted_count INTEGER NOT NULL DEFAULT 0,
    unseen_count INTEGER NOT NULL DEFAULT 0,
    unread_count_adjusted_for_duplicates INTEGER NOT NULL DEFAULT 0,
    change_identifier TEXT,
    source INTEGER,
    alleged_change_identifier TEXT
);
```

**Important Notes:**
- **No `name` or `type` columns** - these must be derived from the `url` field
- Mailbox name extraction: parse the URL path (e.g., `imap://account-id/INBOX` → `INBOX`)
- Mailbox type detection: check for keywords in the name (Trash, Junk, Sent, Drafts, Archive)

**Implementation Note:** Filter out mailboxes by name matching (Trash, Junk, Bulk, Spam, etc.)

#### 2.2.3 `addresses` Table

Normalizes email addresses:

```sql
CREATE TABLE addresses (
    ROWID INTEGER PRIMARY KEY,
    address TEXT NOT NULL,                 -- Email address
    comment TEXT NOT NULL                  -- Display name
);
```

Used for senders and referenced by the `recipients` table.

#### 2.2.4 `recipients` Table

Stores email recipients (To/Cc/Bcc):

```sql
CREATE TABLE recipients (
    ROWID INTEGER PRIMARY KEY,
    message INTEGER NOT NULL,              -- Foreign key to messages.ROWID
    address INTEGER NOT NULL,              -- Foreign key to addresses.ROWID
    type INTEGER,                          -- 0=To, 1=Cc, 2=Bcc
    position INTEGER                       -- Order in recipient list
);
```

**Usage Pattern:**
```sql
SELECT r.type, a.address
FROM recipients r
LEFT JOIN addresses a ON r.address = a.ROWID
WHERE r.message = ?
ORDER BY r.position
```

#### 2.2.5 `subjects` Table

Normalizes email subjects:

```sql
CREATE TABLE subjects (
    ROWID INTEGER PRIMARY KEY,
    subject TEXT NOT NULL
);
```

Referenced by `messages.subject`.

#### 2.2.6 `message_global_data` Table

Stores additional message metadata (NOT message content):

```sql
CREATE TABLE message_global_data (
    ROWID INTEGER PRIMARY KEY,
    message_id INTEGER,                    -- Links to messages.message_id (not ROWID)
    follow_up_start_date INTEGER,
    follow_up_end_date INTEGER,
    follow_up_jsonstringformodelevaluationforsuggestions TEXT,
    download_state INTEGER NOT NULL DEFAULT 0,
    read_later_date INTEGER,
    send_later_date INTEGER,
    validation_state INTEGER NOT NULL DEFAULT 0,
    generated_summary INTEGER,
    urgent INTEGER,
    model_analytics TEXT,
    model_category INTEGER,
    category_model_version INTEGER,
    model_subcategory INTEGER,
    model_high_impact INTEGER NOT NULL DEFAULT 0,
    category_is_temporary INTEGER
);
```

**Note:** This table does NOT contain `to_list`, `cc_list`, or `bcc_list` columns. Recipients are in the `recipients` table.

### 2.3 Sample Queries

#### Incremental Sync Query

```sql
SELECT 
    m.ROWID,
    m.message_id,
    s.subject,
    a.address AS sender,
    m.date_received,
    m.read,
    m.flagged,
    m.flags,
    mb.url AS mailbox_url
FROM messages m
LEFT JOIN subjects s ON s.ROWID = m.subject
LEFT JOIN addresses a ON a.ROWID = m.sender
LEFT JOIN mailboxes mb ON mb.ROWID = m.mailbox
WHERE m.ROWID > ?  -- last_seen_rowid
ORDER BY m.ROWID ASC
LIMIT ?;  -- batch_size
```

#### Fetch Recipients for a Message

```sql
SELECT 
    r.type,
    a.address,
    a.comment AS display_name
FROM recipients r
LEFT JOIN addresses a ON a.ROWID = r.address
WHERE r.message = ?  -- message ROWID
ORDER BY r.position;
```

#### VIP Sender Detection

VIP status is stored in the `flags` bitmask. The VIP flag is `0x20000` (131072):

```sql
SELECT DISTINCT a.address
FROM messages m
LEFT JOIN addresses a ON a.ROWID = m.sender
WHERE (m.flags & 131072) != 0;
```

#### Thread/Conversation Query

```sql
SELECT 
    m.ROWID,
    s.subject,
    a.address AS sender,
    m.date_received
FROM messages m
LEFT JOIN subjects s ON s.ROWID = m.subject
LEFT JOIN addresses a ON a.ROWID = m.sender
WHERE m.conversation_id = ?
ORDER BY m.date_received ASC;
```

### 2.4 Indexed Mode Implementation

**State Tracking:**
```python
@dataclass
class IndexedModeState:
    last_rowid: int = 0
    last_sync_timestamp: str = ""
    total_processed: int = 0
```

**Incremental Fetch:**
```python
**Incremental Fetch:**
```python
def fetch_new_messages_from_index(
    db_path: Path,
    last_rowid: int,
    batch_size: int = 100
) -> List[EmailMetadata]:
    """Query Envelope Index for new messages since last_rowid."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    
    cursor = conn.execute("""
        SELECT 
            m.ROWID, m.message_id, s.subject, a.address AS sender,
            m.date_received, m.read, m.flagged, m.flags,
            mb.url AS mailbox_url
        FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN mailboxes mb ON mb.ROWID = m.mailbox
        WHERE m.ROWID > ?
        ORDER BY m.ROWID ASC
        LIMIT ?
    """, (last_rowid, batch_size))
    
    results = []
    for row in cursor.fetchall():
        # Fetch recipients for this message
        recipients = fetch_recipients(conn, row["ROWID"])
        
        results.append(EmailMetadata(
            rowid=row["ROWID"],
            message_id=row["message_id"],
            subject=row["subject"],
            sender=row["sender"],
            recipients=recipients,
            date_received=row["date_received"],
            is_read=bool(row["read"]),
            is_flagged=bool(row["flagged"]),
            is_vip=bool(row["flags"] & 0x20000),
            mailbox_url=row["mailbox_url"]
        ))
    
    conn.close()
    return results


def fetch_recipients(conn, message_rowid: int) -> Dict[str, List[str]]:
    """Fetch To/Cc/Bcc recipients for a message."""
    cursor = conn.execute("""
        SELECT r.type, a.address
        FROM recipients r
        LEFT JOIN addresses a ON a.ROWID = r.address
        WHERE r.message = ?
        ORDER BY r.position
    """, (message_rowid,))
    
    recipients = {"to": [], "cc": [], "bcc": []}
    for row in cursor.fetchall():
        recipient_type = row[0]
        address = row[1]
        if recipient_type == 0:
            recipients["to"].append(address)
        elif recipient_type == 1:
            recipients["cc"].append(address)
        elif recipient_type == 2:
            recipients["bcc"].append(address)
    
    return recipients
```
```

---

## 3. .emlx File Format

### 3.1 File Location

Each message is stored as a standalone `.emlx` file:

```
~/Library/Mail/V{version}/Mailboxes/{Account}/{Mailbox}.mbox/{message_id}.emlx
```

**Naming Convention:**  
Files are named with numeric IDs (e.g., `12345.emlx`, `67890.emlx`). The ID typically corresponds to `messages.message_id` in the Envelope Index.

### 3.2 File Structure

The `.emlx` format consists of:

1. **Header Line:** Single integer indicating the length of the RFC 2822 message in bytes
2. **RFC 2822 Message:** The full email content (headers + body)
3. **XML plist Metadata:** Apple-specific metadata appended after the message

**Example:**

```
1234
Return-Path: <sender@example.com>
From: Sender Name <sender@example.com>
To: recipient@example.com
Subject: Test Message
Date: Mon, 20 Oct 2025 14:30:00 -0400
Message-ID: <abc123@mail.example.com>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

This is the message body.
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>flags</key>
    <integer>8589934592</integer>
    <key>date-received</key>
    <real>1729452600.0</real>
    <key>remote-id</key>
    <string>12345</string>
    <key>subject</key>
    <string>Test Message</string>
</dict>
</plist>
```

### 3.3 Parsing .emlx Files

**Python Implementation:**

```python
import email
import plistlib
from pathlib import Path
from typing import Optional, Dict, Any
from email.message import EmailMessage

def parse_emlx_file(emlx_path: Path) -> tuple[EmailMessage, Dict[str, Any]]:
    """
    Parse an .emlx file and return the RFC 2822 message and plist metadata.
    
    Returns:
        (EmailMessage, metadata_dict)
    """
    with open(emlx_path, 'rb') as f:
        # Read first line (message byte length)
        first_line = f.readline().decode('utf-8').strip()
        try:
            message_length = int(first_line)
        except ValueError:
            raise ValueError(f"Invalid .emlx format: expected integer length, got {first_line!r}")
        
        # Read the RFC 2822 message
        message_bytes = f.read(message_length)
        
        # Parse the email message
        msg = email.message_from_bytes(message_bytes, policy=email.policy.default)
        
        # Read remaining content (plist metadata)
        remaining = f.read()
        
        # Find plist start
        plist_start = remaining.find(b'<?xml')
        if plist_start >= 0:
            plist_bytes = remaining[plist_start:]
            try:
                metadata = plistlib.loads(plist_bytes)
            except Exception as e:
                logger.warning(f"Failed to parse plist metadata: {e}")
                metadata = {}
        else:
            metadata = {}
    
    return msg, metadata


def extract_email_metadata(msg: EmailMessage) -> Dict[str, Any]:
    """Extract key metadata fields from an EmailMessage."""
    return {
        "subject": msg.get("Subject", ""),
        "from": msg.get("From", ""),
        "to": msg.get("To", ""),
        "cc": msg.get("Cc", ""),
        "bcc": msg.get("Bcc", ""),
        "date": msg.get("Date", ""),
        "message_id": msg.get("Message-ID", ""),
        "in_reply_to": msg.get("In-Reply-To", ""),
        "references": msg.get("References", ""),
        "list_unsubscribe": msg.get("List-Unsubscribe", ""),
        "content_type": msg.get_content_type(),
        "is_multipart": msg.is_multipart()
    }
```

### 3.4 Extracting Text Content

```python
def extract_text_from_email(msg: EmailMessage) -> tuple[str, str]:
    """
    Extract plain text and HTML content from an email message.
    
    Returns:
        (plain_text, html_content)
    """
    plain_text = ""
    html_content = ""
    
    if msg.is_multipart():
        for part in msg.walk():
            content_type = part.get_content_type()
            content_disposition = str(part.get("Content-Disposition", ""))
            
            # Skip attachments
            if "attachment" in content_disposition:
                continue
            
            if content_type == "text/plain":
                try:
                    plain_text += part.get_content()
                except Exception:
                    pass
            elif content_type == "text/html":
                try:
                    html_content += part.get_content()
                except Exception:
                    pass
    else:
        content_type = msg.get_content_type()
        if content_type == "text/plain":
            plain_text = msg.get_content()
        elif content_type == "text/html":
            html_content = msg.get_content()
    
    return plain_text.strip(), html_content.strip()
```

### 3.5 Handling Multipart MIME

Email messages often contain multiple parts:

- **text/plain**: Plain text version
- **text/html**: HTML formatted version
- **image/**, **application/**: Attachments

**Best Practice:** Prefer `text/plain` for ingestion; fall back to HTML with tag stripping if plain text is unavailable.

```python
def get_email_body(msg: EmailMessage) -> str:
    """Extract the best text representation from an email."""
    plain_text, html_content = extract_text_from_email(msg)
    
    if plain_text:
        return plain_text
    elif html_content:
        # Strip HTML tags (basic approach)
        from html.parser import HTMLParser
        
        class HTMLStripper(HTMLParser):
            def __init__(self):
                super().__init__()
                self.text = []
            
            def handle_data(self, data):
                self.text.append(data)
            
            def get_text(self):
                return ''.join(self.text)
        
        stripper = HTMLStripper()
        stripper.feed(html_content)
        return stripper.get_text().strip()
    else:
        return ""
```

---

## 4. Attachment Storage

### 4.1 Attachment Directory Structure

Mail.app stores attachments separately from `.emlx` files:

```
~/Library/Mail/V{version}/Attachments/
└── {message_id}/
    └── {attachment_index}/
        └── {filename}
```

**Example:**
```
Attachments/
└── 12345/              # message_id
    ├── 2/              # First attachment (index may not start at 0)
    │   └── receipt.pdf
    └── 3/              # Second attachment
        └── invoice.png
```

### 4.2 Resolving Attachment Paths

Given an `.emlx` file and attachment metadata from the MIME parts, resolve the filesystem path:

```python
def resolve_attachment_path(
    mail_version_dir: Path,
    message_id: int,
    attachment_index: int,
    filename: str
) -> Optional[Path]:
    """
    Resolve the filesystem path for an email attachment.
    
    Args:
        mail_version_dir: ~/Library/Mail/V{version}/
        message_id: Message ID from Envelope Index or .emlx filename
        attachment_index: Attachment index (from MIME multipart order)
        filename: Attachment filename
    
    Returns:
        Path to attachment file if it exists, else None
    """
    attachments_dir = mail_version_dir / "Attachments" / str(message_id)
    
    if not attachments_dir.exists():
        return None
    
    # Try direct path
    attachment_path = attachments_dir / str(attachment_index) / filename
    if attachment_path.exists():
        return attachment_path
    
    # Fallback: search all subdirectories for matching filename
    for subdir in attachments_dir.iterdir():
        if subdir.is_dir():
            candidate = subdir / filename
            if candidate.exists():
                return candidate
    
    return None
```

### 4.3 Attachment Metadata Extraction

```python
from email.message import EmailMessage
from typing import List, Dict, Any

def extract_attachments(msg: EmailMessage) -> List[Dict[str, Any]]:
    """
    Extract attachment metadata from an email message.
    
    Returns:
        List of attachment descriptors with filename, content_type, size
    """
    attachments = []
    
    if not msg.is_multipart():
        return attachments
    
    for index, part in enumerate(msg.iter_attachments()):
        filename = part.get_filename()
        if not filename:
            continue
        
        content_type = part.get_content_type()
        size = len(part.get_content())
        
        attachments.append({
            "index": index,
            "filename": filename,
            "content_type": content_type,
            "size": size
        })
    
    return attachments
```

---

## 5. Mailbox Filtering Strategy

### 5.1 Mailboxes to Exclude

**High-Noise Mailboxes:**
- **Junk/Spam** (check URL for keywords: "junk", "spam")
- **Trash/Bin** (check URL for keywords: "trash", "bin", "deleted")
- **Drafts** (check URL for keyword: "draft")
- **Bulk** (check URL for keyword: "bulk")
- **Promotions** (if using Gmail-style labels)

**Implementation:**

```python
EXCLUDED_MAILBOX_KEYWORDS = {
    "junk", "spam", "trash", "bin", "deleted", "draft", "bulk",
    "promotion", "promotions", "update", "updates", "social", "forum", "forums"
}

def should_skip_mailbox(mailbox_url: str) -> bool:
    """Determine if a mailbox should be skipped during collection."""
    # Extract mailbox name from URL (e.g., imap://account-id/INBOX -> INBOX)
    mailbox_name = mailbox_url.split('/')[-1].lower()
    
    # Check if any excluded keyword is in the mailbox name
    for keyword in EXCLUDED_MAILBOX_KEYWORDS:
        if keyword in mailbox_name:
            return True
    
    return False
```

### 5.2 VIP Sender Handling

VIP senders should be **prioritized** in noise filtering:

```python
def calculate_relevance_score(metadata: Dict[str, Any]) -> float:
    """
    Calculate a relevance score for an email (0.0 to 1.0).
    Higher scores = more relevant.
    """
    score = 0.5  # Baseline
    
    # VIP boost
    if metadata.get("is_vip"):
        score += 0.3
    
    # Flagged/starred boost
    if metadata.get("is_flagged"):
        score += 0.2
    
    # List-Unsubscribe penalty (likely promotional)
    if metadata.get("list_unsubscribe"):
        score -= 0.4
    
    # Promotional keywords penalty
    subject_lower = metadata.get("subject", "").lower()
    promotional_keywords = ["unsubscribe", "promotional", "offer", "discount", "deal"]
    if any(kw in subject_lower for kw in promotional_keywords):
        score -= 0.2
    
    # Clamp to [0, 1]
    return max(0.0, min(1.0, score))
```

---

## 6. VIP and List-Unsubscribe Headers

### 6.1 VIP Sender Detection

VIP status is stored in the `messages.flags` column as a bitmask:
- **VIP Flag:** `0x20000` (131072 in decimal)
- Check with: `(flags & 0x20000) != 0`

**Python Example:**
```python
def is_vip_sender(flags: int) -> bool:
    """Check if a message is from a VIP sender."""
    VIP_FLAG = 0x20000
    return (flags & VIP_FLAG) != 0
```

**SQL Example:**
```sql
SELECT DISTINCT a.address
FROM messages m
LEFT JOIN addresses a ON a.ROWID = m.sender
WHERE (m.flags & 131072) != 0;
```

### 6.2 List-Unsubscribe Header

The `List-Unsubscribe` header indicates bulk/marketing emails:

```
List-Unsubscribe: <mailto:unsubscribe@example.com>, <https://example.com/unsubscribe>
```

**Detection:**

```python
def is_promotional_email(msg: EmailMessage) -> bool:
    """Check if an email is likely promotional based on headers."""
    list_unsubscribe = msg.get("List-Unsubscribe", "")
    if list_unsubscribe:
        return True
    
    # Additional heuristics
    precedence = msg.get("Precedence", "").lower()
    if precedence in ("bulk", "junk", "list"):
        return True
    
    # Check for X-Mailer indicating bulk email software
    x_mailer = msg.get("X-Mailer", "").lower()
    bulk_mailers = ["mailchimp", "sendgrid", "constant contact"]
    if any(mailer in x_mailer for mailer in bulk_mailers):
        return True
    
    return False
```

### 6.3 Intent Classification

Use simple keyword/pattern matching to classify email intent:

```python
from enum import Enum
from typing import Optional

class EmailIntent(str, Enum):
    BILL = "bill"
    RECEIPT = "receipt"
    CONFIRMATION = "confirmation"
    APPOINTMENT = "appointment"
    ACTION_REQUEST = "action_request"
    NOTIFICATION = "notification"
    CONVERSATION = "conversation"
    PROMOTIONAL = "promotional"
    UNKNOWN = "unknown"

def classify_email_intent(subject: str, body: str, sender: str) -> EmailIntent:
    """
    Classify the intent of an email based on subject and body content.
    """
    subject_lower = subject.lower()
    body_lower = body.lower()
    
    # Bill/statement patterns
    if any(kw in subject_lower for kw in ["bill", "invoice", "statement", "payment due"]):
        return EmailIntent.BILL
    
    # Receipt patterns
    if any(kw in subject_lower for kw in ["receipt", "order confirmation", "your order"]):
        return EmailIntent.RECEIPT
    
    # Confirmation patterns
    if any(kw in subject_lower for kw in ["confirmation", "confirmed", "booking"]):
        return EmailIntent.CONFIRMATION
    
    # Appointment patterns
    if any(kw in subject_lower for kw in ["appointment", "meeting", "calendar", "invitation"]):
        return EmailIntent.APPOINTMENT
    
    # Action request patterns
    if any(kw in subject_lower for kw in ["action required", "please review", "response needed"]):
        return EmailIntent.ACTION_REQUEST
    
    # Notification patterns
    if any(kw in subject_lower for kw in ["notification", "alert", "reminder"]):
        return EmailIntent.NOTIFICATION
    
    # Promotional (List-Unsubscribe already detected elsewhere)
    if any(kw in subject_lower for kw in ["unsubscribe", "offer", "discount", "deal"]):
        return EmailIntent.PROMOTIONAL
    
    # Default to conversation for direct emails
    return EmailIntent.CONVERSATION
```

---

## 7. Implementation Patterns

### 7.1 Indexed Mode (Preferred)

**When to Use:** When Envelope Index is available and accessible.

**Workflow:**
1. Locate Envelope Index SQLite database
2. Query for messages with `ROWID > last_seen_rowid`
3. Filter by mailbox type (exclude Trash, Junk)
4. Resolve `.emlx` file paths from Envelope Index metadata
5. Parse `.emlx` files for full content
6. Track state (`last_rowid`, `last_sync_timestamp`)

**Advantages:**
- Fast incremental sync (single SQL query)
- Built-in metadata (VIP, read status, flags)
- Efficient for large mailboxes

**State File:**
```json
{
  "mode": "indexed",
  "last_rowid": 12345,
  "last_sync_timestamp": "2025-10-20T14:30:00Z",
  "total_processed": 5432
}
```

### 7.2 Crawler Mode (Fallback)

**When to Use:** When Envelope Index is unavailable or inaccessible (permissions, corruption).

**Workflow:**
1. Scan `~/Library/Mail/V*/Mailboxes/` for `.mbox` directories
2. Recursively find all `.emlx` files
3. Track file state: `(inode, mtime)` to detect changes
4. Filter by mailbox name (skip Junk, Trash, etc.)
5. Parse changed/new `.emlx` files
6. Optionally use FSEvents for real-time monitoring

**State File:**
```json
{
  "mode": "crawler",
  "file_states": {
    "/path/to/12345.emlx": {
      "inode": 9876543,
      "mtime": 1729452600.0,
      "last_processed": "2025-10-20T14:30:00Z",
      "content_sha256": "abc123..."
    }
  },
  "total_processed": 1234
}
```

**Advantages:**
- Works without Envelope Index access
- More resilient to database corruption
- Can use FSEvents for real-time updates

**Disadvantages:**
- Slower initial scan (filesystem walk)
- Less metadata available (must parse each .emlx)
- Requires careful state tracking to avoid duplicates

### 7.3 Hybrid Approach

**Recommendation:** Start with Indexed Mode, fall back to Crawler Mode if Envelope Index is unavailable:

```python
def determine_collection_mode(mail_data_dir: Path) -> str:
    """Determine which collection mode to use."""
    envelope_index = mail_data_dir / "MailData" / "Envelope Index"
    
    if envelope_index.exists() and os.access(envelope_index, os.R_OK):
        return "indexed"
    else:
        logger.warning("Envelope Index not accessible, using Crawler mode")
        return "crawler"
```

### 7.4 Incremental Sync Strategy

**Key Principles:**
1. **Idempotency:** Use stable identifiers (Message-ID, content SHA256)
2. **Change Detection:** Track `(ROWID, inode, mtime)` depending on mode
3. **State Persistence:** Save after each batch
4. **Error Recovery:** Allow resumption from last known state

**Idempotency Key Generation:**
```python
def generate_idempotency_key(msg: EmailMessage, content_sha256: str) -> str:
    """
    Generate a unique idempotency key for an email.
    
    Format: email_local:{message_id}:{content_hash}
    """
    message_id = msg.get("Message-ID", "").strip("<>")
    if not message_id:
        # Fallback to hash-based ID
        message_id = hashlib.sha256(
            f"{msg.get('From')}{msg.get('Subject')}{msg.get('Date')}".encode()
        ).hexdigest()[:16]
    
    return f"email_local:{message_id}:{content_sha256[:16]}"
```

---

## 8. References

### 8.1 Internal References

- **Haven Schema:** `documentation/SCHEMA_V2_REFERENCE.md`
- **iMessage Collector:** `scripts/collectors/collector_imessage.py` (pattern reference)
- **LocalFS Collector:** `scripts/collectors/collector_localfs.py` (pattern reference)
- **Image Enrichment:** `shared/image_enrichment.py`
- **Gateway API:** `services/gateway_api/app.py`

### 8.2 External References

- **RFC 2822:** Internet Message Format (email structure)
- **MIME RFC 2045-2049:** Multipurpose Internet Mail Extensions
- **Apple plist:** Property List XML format
- **SQLite Documentation:** https://www.sqlite.org/

### 8.3 macOS Permissions

**Full Disk Access Required:**
- Mail.app cache is protected by macOS privacy controls
- Collector must run with Full Disk Access (FDA) in production
- For development, manually grant FDA to Terminal.app or Python.app

**Grant FDA:**
1. System Preferences → Security & Privacy → Privacy
2. Select "Full Disk Access"
3. Add Terminal.app or Python executable
4. Restart Terminal

---

## Summary for Implementation

### Indexed Mode Implementation Checklist

- [ ] Locate Envelope Index database (`~/Library/Mail/V*/MailData/Envelope Index`)
- [ ] Query `messages` table with `ROWID > last_seen`
- [ ] Filter by `mailbox.type NOT IN (1, 2)` (exclude Trash, Junk)
- [ ] Resolve `.emlx` file paths from mailbox URL
- [ ] Parse `.emlx` files (header line + RFC 2822 + plist)
- [ ] Extract metadata (subject, sender, recipients, date)
- [ ] Handle VIP senders (`vip_sender = 1`)
- [ ] Track state (`last_rowid`)

### Crawler Mode Implementation Checklist

- [ ] Scan `~/Library/Mail/V*/Mailboxes/` for `.mbox` directories
- [ ] Skip excluded mailbox names (Junk, Trash, Promotions)
- [ ] Find all `.emlx` files recursively
- [ ] Track file state: `(inode, mtime, content_sha256)`
- [ ] Parse changed/new `.emlx` files
- [ ] Set up FSEvents watcher (optional)
- [ ] Save state after each batch

### Common Implementation Tasks

- [ ] Parse `.emlx` format (byte length + message + plist)
- [ ] Extract text from multipart MIME (prefer plain text)
- [ ] Resolve attachment paths (`Attachments/{message_id}/{index}/`)
- [ ] Detect List-Unsubscribe header for noise filtering
- [ ] Classify intent (bill, receipt, confirmation, etc.)
- [ ] Calculate relevance score (VIP boost, promotional penalty)
- [ ] Generate idempotency keys (`email_local:{message_id}:{hash}`)
- [ ] Build Gateway v2 document payloads
- [ ] Submit to Gateway `/v1/ingest`
- [ ] Handle image attachments (enrich via `shared.image_enrichment`)

---

**End of Documentation**
