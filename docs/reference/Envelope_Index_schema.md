# Mail.app Envelope Index Schema

Query run against: `/Users/chrispatten/Library/Mail/V10/MailData/Envelope Index`

## CREATE TABLE Statement

```sql
CREATE TABLE messages (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id INTEGER NOT NULL DEFAULT 0,
    global_message_id INTEGER NOT NULL,
    remote_id INTEGER,
    document_id TEXT COLLATE BINARY,
    sender INTEGER,
    subject_prefix TEXT COLLATE BINARY,
    subject INTEGER NOT NULL,
    summary INTEGER,
    date_sent INTEGER,
    date_received INTEGER,
    mailbox INTEGER NOT NULL,
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
    color TEXT COLLATE BINARY,
    type INTEGER,
    fuzzy_ancestor INTEGER,
    automated_conversation INTEGER DEFAULT 0,
    root_status INTEGER DEFAULT -1,
    flag_color INTEGER,
    is_urgent INTEGER NOT NULL DEFAULT 0
)
```

## Column List (PRAGMA table_info)

| cid | name                    | type    | notnull | dflt_value | pk |
|-----|-------------------------|---------|---------| ---------- |----|
| 0   | ROWID                   | INTEGER | 0       |            | 1  |
| 1   | message_id              | INTEGER | 1       | 0          | 0  |
| 2   | global_message_id       | INTEGER | 1       |            | 0  |
| 3   | remote_id               | INTEGER | 0       |            | 0  |
| 4   | document_id             | TEXT    | 0       |            | 0  |
| 5   | sender                  | INTEGER | 0       |            | 0  |
| 6   | subject_prefix          | TEXT    | 0       |            | 0  |
| 7   | subject                 | INTEGER | 1       |            | 0  |
| 8   | summary                 | INTEGER | 0       |            | 0  |
| 9   | date_sent               | INTEGER | 0       |            | 0  |
| 10  | date_received           | INTEGER | 0       |            | 0  |
| 11  | mailbox                 | INTEGER | 1       |            | 0  |
| 12  | remote_mailbox          | INTEGER | 0       |            | 0  |
| 13  | flags                   | INTEGER | 1       | 0          | 0  |
| 14  | read                    | INTEGER | 1       | 0          | 0  |
| 15  | flagged                 | INTEGER | 1       | 0          | 0  |
| 16  | deleted                 | INTEGER | 1       | 0          | 0  |
| 17  | size                    | INTEGER | 1       | 0          | 0  |
| 18  | conversation_id         | INTEGER | 1       | 0          | 0  |
| 19  | date_last_viewed        | INTEGER | 0       |            | 0  |
| 20  | list_id_hash            | INTEGER | 0       |            | 0  |
| 21  | unsubscribe_type        | INTEGER | 0       |            | 0  |
| 22  | searchable_message      | INTEGER | 0       |            | 0  |
| 23  | brand_indicator         | INTEGER | 0       |            | 0  |
| 24  | display_date            | INTEGER | 0       |            | 0  |
| 25  | color                   | TEXT    | 0       |            | 0  |
| 26  | type                    | INTEGER | 0       |            | 0  |
| 27  | fuzzy_ancestor          | INTEGER | 0       |            | 0  |
| 28  | automated_conversation  | INTEGER | 0       | 0          | 0  |
| 29  | root_status             | INTEGER | 0       | -1         | 0  |
| 30  | flag_color              | INTEGER | 0       |            | 0  |
| 31  | is_urgent               | INTEGER | 1       | 0          | 0  |

## Sample Data (First 5 Rows)

| ROWID | message_id            | global_message_id | remote_id | sender | subject | date_sent  | date_received | mailbox | flags       | read | conversation_id |
|-------|-----------------------|-------------------|-----------|--------|---------|------------|---------------|---------|-------------|------|-----------------|
| 1     | 4773312084381739807   | 1                 | 9507      | 1      | 1       | 1677098044 | 1677098108    | 2       | 8590195840  | 0    | 31              |
| 2     | -8870798389135542176  | 2                 | 9506      | 3      | 2       | 1677078053 | 1677078055    | 2       | 8590195840  | 0    | 30              |
| 3     | 378390787877563686    | 3                 | 9505      | 4      | 3       | 1677029074 | 1677029121    | 2       | 25770065025 | 1    | 29              |
| 4     | 8326054568977240875   | 4                 | 9504      | 5      | 4       | 1677007502 | 1677007509    | 2       | 8590132353  | 1    | 636             |
| 5     | -1223034532183719061  | 5                 | 9503      | 7      | 5       | 1677003409 | 1677003411    | 2       | 8590195840  | 0    | 28              |

## Notes

- **No `guid` column**: The real Mail.app Envelope Index does NOT contain a `guid` column
- **mailboxes table**: Only contains `url` column (plus counters), no `name`, `displayName`, or `type` columns
  - Mailbox names must be derived from the URL path (e.g., `imap://account-id/INBOX` → `INBOX`)
  - Mailbox types (Trash, Junk, etc.) must be inferred from the mailbox name in the URL
- **recipients table**: Email recipients (To/Cc/Bcc) are stored in a separate `recipients` table:
  - Structure: `ROWID`, `message` (foreign key to messages.ROWID), `address` (foreign key to addresses.ROWID), `type`, `position`
  - `type`: 0 = To, 1 = Cc, 2 = Bcc
  - Must join recipients → addresses to get actual email addresses
- **message_global_data table**: Does NOT contain `to_list`, `cc_list`, or `bcc_list` columns
  - Contains: `message_id`, `follow_up_start_date`, `follow_up_end_date`, `download_state`, `read_later_date`, `send_later_date`, `validation_state`, `generated_summary`, `urgent`, `model_analytics`, `model_category`, `category_model_version`, `model_subcategory`, `model_high_impact`, `category_is_temporary`
- Foreign keys: `sender`, `subject`, `summary` reference other tables (`addresses`, `subjects`, `summaries`)
- Timestamps: `date_sent`, `date_received`, `date_last_viewed`, `display_date` use Apple epoch (seconds since 2001-01-01)
- The `remote_id` matches the .emlx filename in the mailbox directory structure

---

## Additional Important Tables

### recipients Table

```sql
CREATE TABLE recipients (
    ROWID INTEGER PRIMARY KEY,
    message INTEGER NOT NULL,     -- Foreign key to messages.ROWID
    address INTEGER NOT NULL,     -- Foreign key to addresses.ROWID
    type INTEGER,                 -- 0=To, 1=Cc, 2=Bcc
    position INTEGER              -- Order in recipient list
);
```

### subjects Table

```sql
CREATE TABLE subjects (
    ROWID INTEGER PRIMARY KEY,
    subject TEXT NOT NULL
);
```

### addresses Table

```sql
CREATE TABLE addresses (
    ROWID INTEGER PRIMARY KEY,
    address TEXT NOT NULL,
    comment TEXT NOT NULL         -- Display name
);
```

### mailboxes Table (Complete Structure)

```sql
CREATE TABLE mailboxes (
    ROWID INTEGER PRIMARY KEY,
    url TEXT NOT NULL,
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
