# Haven Unified Schema v2 - Complete Reference

**Last Updated**: October 16, 2025  
**Status**: Implemented  
**Branch**: `schema_refinement`

---

## Table of Contents

1. [Overview](#overview)
2. [Design Principles](#design-principles)
3. [Migration from v1](#migration-from-v1)
4. [Core Tables](#core-tables)
5. [Type-Specific Metadata](#type-specific-metadata)
6. [File Enrichment Schema](#file-enrichment-schema)
7. [CRM Relationship Schema](#crm-relationship-schema)
8. [Query Patterns](#query-patterns)
9. [Workflow Status](#workflow-status)
10. [Service Integration](#service-integration)
11. [Performance Considerations](#performance-considerations)
11. [Complete DDL Reference](#complete-ddl-reference)

---

## Overview

Unified Schema v2 represents a complete redesign of Haven's data model, replacing the legacy message-centric approach with a flexible, type-agnostic document model. The schema harmonizes ingestion, storage, search, and enrichment across all data sources while maintaining high performance for timeline-based queries and semantic search.

### Key Capabilities

- **Universal Document Model**: Single table for messages, files, notes, reminders, calendar events, and contacts
- **First-Class Relationships**: Threads, files, and chunks are independent entities with explicit junction tables
- **Content Deduplication**: Files deduplicated by SHA256; documents versioned with full history
- **Progressive Enhancement**: Support for partial data with clear status tracking
- **Timeline-Optimized**: Fast queries for "show me everything that happened" use cases
- **Search-Ready**: Pre-computed facets, full-text indexes, and vector embeddings

### Core Entities

| Entity | Purpose | Key Features |
|--------|---------|--------------|
| `documents` | All content (messages, files, notes, etc.) | Versioning, timeline, people, facets |
| `threads` | Conversations and chat groups | Participants, message counts, time ranges |
| `files` | Binary files with deduplication | SHA256 uniqueness, enrichment storage |
| `document_files` | Document-file relationships | Attachment roles, ordering, captions |
| `chunks` | Text segments for search | Embeddings, source references, ordinals |
| `chunk_documents` | Chunk-document relationships | Multi-document chunks, relevance weights |
| `people` | Normalized person records | Contact merging, identifier normalization |
| `person_identifiers` | Phone/email identifiers | Canonical format, priority, verification |
| `document_people` | Document-person relationships | Sender/recipient/participant roles |
| `crm_relationships` | Relationship strength scoring | Directional edges, decay buckets, features |
| `ingest_batches` | Batch submission tracking | Batch-level idempotency, aggregate counts |
| `ingest_submissions` | Idempotency tracking | Deduplication keys, status tracking |
| `source_change_tokens` | Incremental sync state | Per-source tokens (contacts, etc.) |

---

## Design Principles

### 1. Atomic Documents
Every unit of information is a document with a unique identity, regardless of source type. This enables:
- Unified search across all sources
- Consistent enrichment pipelines
- Cross-source relationships and citations

### 2. First-Class Files
Binary files are separate entities, not embedded in documents:
- **Deduplication**: Same file sent in 3 messages → stored once
- **Independent enrichment**: OCR/captions computed once, reused everywhere
- **Storage flexibility**: Multiple backends (MinIO, S3, local)

### 3. Explicit Relationships
No implicit joins or derived relationships:
- `threads` → `documents`: One-to-many conversation structure
- `documents` ↔ `files`: Many-to-many via `document_files` junction
- `documents` ↔ `chunks`: Many-to-many via `chunk_documents` junction
- `documents` → `documents`: Version chains via `previous_version_id`

### 4. Progressive Enhancement
Documents can exist in partial states:
- Text extracted, attachments not yet enriched
- Enrichment failed but document remains searchable
- Embeddings pending but full-text search available
- Status flags track progress without blocking access

### 5. Version History
Documents are immutable; edits create new versions:
- `version_number` increments on each edit
- `previous_version_id` links to prior version
- `is_active_version` flags current state
- Full audit trail for compliance and debugging

### 6. Timeline-First
Optimized for chronological queries:
- `content_timestamp`: Primary sort key
- `content_timestamp_type`: Indicates meaning (sent, created, modified, due)
- Separate `content_created_at` and `content_modified_at` for additional context
- Indexed for fast DESC scans

### 7. Facet-Rich
Pre-computed search facets for instant filtering:
- `has_attachments`, `attachment_count`: File filters
- `has_location`: Geo-tagged content
- `has_due_date`, `due_date`, `is_completed`: Task management
- Partial indexes on facets reduce index size and improve performance

### 8. People-Centric
Raw identifiers stored without resolution:
- `people` JSONB array: `[{"identifier": "+15551234567", "role": "sender", "identifier_type": "phone"}]`
- Person resolution happens at query time (future: link to contacts)
- Supports multiple identifier types: phone, email, self, username
- GIN index on `people` for fast containment queries

---

## Migration from v1

### What Changed

#### Removed Tables (Legacy v1)
- `messages` → Replaced by `documents`
- `attachments` → Replaced by `files` + `document_files`
- `people` → Person resolution moved to future phase
- `person_identifiers`, `person_addresses`, `person_urls` → Removed
- `people_source_map`, `people_conflict_log` → Removed
- `search_documents`, `search_chunks`, `search_ingest_log`, `search_deletes` → Replaced by unified tables
- `embed_jobs`, `delete_jobs` → Status tracking moved to documents/chunks

#### New Tables (v2)
- `documents`: Universal content table
- `threads`: First-class conversation entity
- `files`: Deduplicated binary storage
- `document_files`: Document-file junction
- `chunks`: Search chunks with embeddings
- `chunk_documents`: Chunk-document junction
- `ingest_submissions`: Idempotency tracking
- `source_change_tokens`: Incremental sync state

### Schema Differences

| Aspect | v1 | v2 |
|--------|----|----|
| **Content Storage** | `messages` table (message-specific) | `documents` table (universal) |
| **File Handling** | `attachments` per message | `files` deduplicated by SHA256 |
| **Threads** | Implicit (group by chat) | Explicit `threads` table |
| **Versioning** | Not supported | Full version history |
| **People** | Resolved to `people` table | Raw identifiers in JSONB |
| **Timestamps** | `sent_at`, `received_at` | `content_timestamp` + type |
| **Facets** | Computed at query time | Pre-computed columns |
| **Search** | Separate `search_*` tables | Integrated into core tables |
| **Chunks** | One-to-many (doc → chunks) | Many-to-many (docs ↔ chunks) |
| **Enrichment** | Per-attachment in message | Per-file in `files` table |

### Migration Strategy

**Recommended Approach**: Clean slate re-ingestion

1. **Backup v1 data**: Export existing messages/attachments
2. **Deploy v2 schema**: Run `schema/init.sql` (drops legacy tables)
3. **Re-run collectors**:
   - iMessage: Re-process `~/Library/Messages/chat.db` (~2-3 hours for 300K messages)
   - Local files: Re-scan filesystem
   - Contacts: Re-export and ingest
4. **Backfill enrichment**: Re-run image enrichment on attachments
5. **Re-generate embeddings**: Embedding service processes new chunks
6. **Validate**: Compare document counts, search results, timeline queries

**Why not incremental migration?**
- v1 and v2 schemas are fundamentally incompatible (different data models)
- Re-ingestion is faster than writing complex migration scripts (~3-4 hours total)
- Ensures data quality and consistency
- Enables fixing known v1 issues (missing source types, inconsistent timestamps)

### Breaking Changes

1. **API Contracts**:
   - All API endpoints updated for v2 payloads
   - `POST /v1/catalog/documents`: New `DocumentIngestRequest` structure
   - `GET /v1/search`: New filter parameters and response format
   - `POST /v1/ingest`: Updated to build v2 document payloads

2. **Database Queries**:
   - All queries referencing `messages` must be updated to `documents`
   - Thread queries must join `threads` table
   - File queries must join through `document_files` → `files`
   - People queries must use JSONB containment operators

3. **Collector Output**:
   - Collectors must emit v2-compatible payloads
   - `source_type` and `external_id` now required
   - `people` array required (can be empty)
   - Thread payload optional but recommended

4. **Enrichment Pipeline**:
   - Enrichment stored in `files.enrichment` (not per-document)
   - Enrichment status tracked in `files.enrichment_status`
   - Backfill scripts must update file records, not document metadata

---

## Core Tables

### 1. documents

The primary table for all atomic units of information.

**Purpose**: Store text content from any source with rich metadata, versioning, and relationships.

**Schema**:
```sql
CREATE TABLE documents (
    -- Identity
    doc_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    external_id TEXT NOT NULL,              -- Source-specific ID: "imessage:{guid}", "localfs:{sha256}"
    source_type TEXT NOT NULL,              -- "imessage", "sms", "email", "localfs", "note", "reminder", "calendar_event", "contact"
    source_provider TEXT,                   -- "apple_messages", "gmail", "notion", "apple_notes"
    
    -- Version Control
    version_number INTEGER NOT NULL DEFAULT 1,
    previous_version_id UUID REFERENCES documents(doc_id),
    is_active_version BOOLEAN NOT NULL DEFAULT true,
    superseded_at TIMESTAMPTZ,
    superseded_by_id UUID REFERENCES documents(doc_id),
    
    -- Content
    title TEXT,                             -- Thread name, file name, note title
    text TEXT NOT NULL,                     -- Full searchable text
    text_sha256 TEXT NOT NULL,              -- Hash for duplicate detection
    mime_type TEXT,                         -- "text/plain", "text/html", "application/json"
    canonical_uri TEXT,                     -- URL, file path, or URI reference
    
    -- Time Dimensions
    content_timestamp TIMESTAMPTZ NOT NULL, -- Primary timestamp (sent_at, modified_at, event_start, due)
    content_timestamp_type TEXT NOT NULL,   -- "sent", "received", "modified", "created", "event_start", "due"
    content_created_at TIMESTAMPTZ,         -- When content was originally created
    content_modified_at TIMESTAMPTZ,        -- When content was last modified
    
    -- People (raw identifiers)
    people JSONB NOT NULL DEFAULT '[]',     -- [{"identifier": "+15551234567", "role": "sender", "identifier_type": "phone"}]
    
    -- Relationships
    thread_id UUID REFERENCES threads(thread_id),
    parent_doc_id UUID REFERENCES documents(doc_id),
    source_doc_ids UUID[],                  -- Documents this came from (e.g., PDF from 3 messages)
    related_doc_ids UUID[],
    
    -- Search Facets (pre-computed)
    has_attachments BOOLEAN NOT NULL DEFAULT false,
    attachment_count INTEGER NOT NULL DEFAULT 0,
    has_location BOOLEAN NOT NULL DEFAULT false,
    has_due_date BOOLEAN NOT NULL DEFAULT false,
    due_date TIMESTAMPTZ,
    is_completed BOOLEAN,
    completed_at TIMESTAMPTZ,
    
    -- Metadata (type-specific structured data)
    metadata JSONB NOT NULL DEFAULT '{}',
    
    -- Workflow Status
    status TEXT NOT NULL DEFAULT 'submitted', -- "submitted", "extracting", "extracted", "enriching", "enriched", "indexed", "failed"
    extraction_failed BOOLEAN NOT NULL DEFAULT false,
    enrichment_failed BOOLEAN NOT NULL DEFAULT false,
    error_details JSONB,
    
    -- Audit
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT documents_external_id_version_key UNIQUE (external_id, version_number)
);
```

**Key Indexes**:
```sql
CREATE INDEX idx_documents_source_type ON documents(source_type);
CREATE INDEX idx_documents_external_id ON documents(external_id);
CREATE INDEX idx_documents_active_version ON documents(is_active_version) WHERE is_active_version = true;
CREATE INDEX idx_documents_thread ON documents(thread_id) WHERE thread_id IS NOT NULL;
CREATE INDEX idx_documents_content_timestamp ON documents(content_timestamp DESC);
CREATE INDEX idx_documents_people ON documents USING GIN(people);
CREATE INDEX idx_documents_metadata ON documents USING GIN(metadata);
CREATE INDEX idx_documents_text_search ON documents USING GIN(to_tsvector('english', text));

-- Facet indexes (partial for efficiency)
CREATE INDEX idx_documents_has_attachments ON documents(has_attachments) WHERE has_attachments = true;
CREATE INDEX idx_documents_due_date ON documents(due_date) WHERE due_date IS NOT NULL;
```

**Design Notes**:
- `external_id` + `version_number` uniqueness allows multiple versions
- `is_active_version` enables efficient current-state queries without version filtering
- `people` JSONB array stores raw identifiers; resolution happens at query time
- Pre-computed facets enable fast filtering without expensive aggregations
- Status workflow tracked in single `status` field with failure flags
- `text_sha256` used for content-based deduplication (same text = potential duplicate)

---

### 2. threads

First-class entity for conversations, chat threads, email threads.

**Purpose**: Track conversation metadata, participants, and message counts.

**Schema**:
```sql
CREATE TABLE threads (
    thread_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    external_id TEXT UNIQUE NOT NULL,       -- "imessage:chat144098762100126627", "email:thread_abc123"
    source_type TEXT NOT NULL,              -- "imessage", "sms", "email", "slack"
    source_provider TEXT,                   -- "apple_messages", "gmail", "slack"
    
    title TEXT,                             -- Chat name, email subject
    participants JSONB NOT NULL DEFAULT '[]', -- [{"identifier": "+15551234567", "role": "participant"}]
    
    thread_type TEXT,                       -- "group", "direct", "channel"
    is_group BOOLEAN,
    participant_count INTEGER,
    metadata JSONB NOT NULL DEFAULT '{}',
    
    first_message_at TIMESTAMPTZ,
    last_message_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Key Indexes**:
```sql
CREATE INDEX idx_threads_external_id ON threads(external_id);
CREATE INDEX idx_threads_source_type ON threads(source_type);
CREATE INDEX idx_threads_last_message ON threads(last_message_at DESC);
CREATE INDEX idx_threads_participants ON threads USING GIN(participants);
```

**Usage**:
- One thread → many documents (messages)
- Enables: "show me the full conversation", "all messages in this thread"
- Supports: group chat metadata, participant tracking, thread-level search
- `participants` JSONB contains same structure as `documents.people`

---

### 3. files

Binary files (images, PDFs, videos, etc.) with content-based deduplication.

**Purpose**: Store file metadata and enrichment data, deduplicated by SHA256.

**Schema**:
```sql
CREATE TABLE files (
    file_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    content_sha256 TEXT UNIQUE NOT NULL,    -- Deduplication key
    
    object_key TEXT NOT NULL,               -- S3/MinIO object key or file path
    storage_backend TEXT NOT NULL,          -- "minio", "s3", "local"
    
    filename TEXT,
    mime_type TEXT,
    size_bytes BIGINT,
    
    enrichment_status TEXT NOT NULL DEFAULT 'pending', -- "pending", "processing", "enriched", "failed", "skipped"
    enrichment JSONB,                       -- {"ocr": {...}, "caption": "...", "vision": {...}, "exif": {...}}
    
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_enriched_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Key Indexes**:
```sql
CREATE INDEX idx_files_content_sha256 ON files(content_sha256);
CREATE INDEX idx_files_enrichment_status ON files(enrichment_status);
CREATE INDEX idx_files_mime_type ON files(mime_type);
CREATE INDEX idx_files_enrichment ON files USING GIN(enrichment);
```

**Key Features**:
- SHA256-based deduplication: same file sent in 3 messages → stored once
- Enrichment stored on file (not per-document) since it's content-based
- Supports progressive enhancement: file can exist without enrichment
- Multiple storage backends supported (MinIO, S3, local filesystem)

---

### 4. document_files

Junction table linking documents to files (attachments, extracted sources).

**Purpose**: Define document-file relationships with roles and ordering.

**Schema**:
```sql
CREATE TABLE document_files (
    doc_id UUID NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    file_id UUID NOT NULL REFERENCES files(file_id) ON DELETE CASCADE,
    
    role TEXT NOT NULL,                     -- "attachment", "extracted_from", "thumbnail", "preview"
    attachment_index INTEGER,               -- Order in attachment list (0, 1, 2, ...)
    
    filename TEXT,                          -- Filename in this context (may differ)
    caption TEXT,                           -- User-provided caption
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    PRIMARY KEY (doc_id, file_id, role)
);
```

**Key Indexes**:
```sql
CREATE INDEX idx_document_files_doc ON document_files(doc_id);
CREATE INDEX idx_document_files_file ON document_files(file_id);
CREATE INDEX idx_document_files_role ON document_files(role);
```

**Usage Examples**:
- Message with 2 photo attachments: 2 rows with `role="attachment"`, `attachment_index=0,1`
- PDF extracted to create document: 1 row with `role="extracted_from"`
- Document with thumbnail: 1 row with `role="thumbnail"`

**Design Notes**:
- Composite primary key: `(doc_id, file_id, role)` allows same file attached to same document in different roles
- `filename` stored here (not in `files`) because filename may differ per document
- `caption` stored here because captions are document-specific, not file-specific
- `attachment_index` provides stable ordering for display

---

### 5. chunks

Text chunks for semantic search and embedding.

**Purpose**: Store text segments with embeddings for vector search.

**Schema**:
```sql
CREATE TABLE chunks (
    chunk_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    text TEXT NOT NULL,
    text_sha256 TEXT NOT NULL,
    ordinal INTEGER NOT NULL,               -- Order within document (if single-doc chunk)
    
    source_ref JSONB,                       -- {"type": "paragraph", "index": 3} for citation
    
    embedding_status TEXT NOT NULL DEFAULT 'pending', -- "pending", "processing", "embedded", "failed"
    embedding_model TEXT,
    embedding_vector VECTOR(1024),          -- pgvector extension
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Key Indexes**:
```sql
CREATE INDEX idx_chunks_embedding_status ON chunks(embedding_status);
CREATE INDEX idx_chunks_text_search ON chunks USING GIN(to_tsvector('english', text));
-- Vector index created after embeddings populated:
-- CREATE INDEX idx_chunks_embedding ON chunks USING ivfflat (embedding_vector vector_cosine_ops) WITH (lists = 100);
```

**Key Features**:
- Many-to-many relationship with documents (via `chunk_documents`)
- `source_ref` enables highlighting/citation of original source
- Supports combining multiple messages into semantic chunks (future)
- `ordinal` provides ordering within single-document chunks

---

### 6. chunk_documents

Junction table for many-to-many chunk-document relationships.

**Purpose**: Link chunks to documents with relevance weights.

**Schema**:
```sql
CREATE TABLE chunk_documents (
    chunk_id UUID NOT NULL REFERENCES chunks(chunk_id) ON DELETE CASCADE,
    doc_id UUID NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    
    ordinal INTEGER,                        -- Order of this document within chunk
    weight DECIMAL(3,2),                    -- Relevance weight 0.0-1.0
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    PRIMARY KEY (chunk_id, doc_id)
);
```

**Key Indexes**:
```sql
CREATE INDEX idx_chunk_documents_chunk ON chunk_documents(chunk_id);
CREATE INDEX idx_chunk_documents_doc ON chunk_documents(doc_id);
```

**Usage Examples**:
- Single message → single chunk: 1 row with `weight=1.0`
- 3 short messages → 1 combined chunk: 3 rows with `weight=0.33` each, `ordinal=0,1,2`
- Long PDF → 50 chunks: 50 rows with `weight=1.0` each
---

### 7. ingest_batches

Batch-level tracking for grouped ingestion requests.

**Purpose**: Capture idempotency keys, aggregate success/failure counts, and lifecycle status for multi-document submissions.

**Schema**:
```sql
CREATE TABLE ingest_batches (
    batch_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    idempotency_key TEXT UNIQUE NOT NULL,
    status TEXT NOT NULL DEFAULT 'submitted',   -- "submitted", "processing", "completed", "partial", "failed"
    total_count INTEGER NOT NULL DEFAULT 0,
    success_count INTEGER NOT NULL DEFAULT 0,
    failure_count INTEGER NOT NULL DEFAULT 0,
    error_details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Key Indexes**:
```sql
CREATE INDEX idx_ingest_batches_status ON ingest_batches(status);
CREATE INDEX idx_ingest_batches_created_at ON ingest_batches(created_at DESC);
```

**Usage Notes**:
- `batch_id` is returned to collectors and used to correlate per-document submissions.
- `success_count` / `failure_count` are updated incrementally, allowing partial success reporting.
- `ingest_submissions.batch_id` links individual submissions back to their batch for replay/idempotency.

---

### 8. ingest_submissions

Idempotency tracking for ingestion requests.

**Purpose**: Prevent duplicate ingestion with idempotency keys.

**Schema**:
```sql
CREATE TABLE ingest_submissions (
    submission_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    idempotency_key TEXT UNIQUE NOT NULL,   -- For preventing duplicate ingestion

    source_type TEXT NOT NULL,
    source_id TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,

    status TEXT NOT NULL DEFAULT 'submitted', -- "submitted", "processing", "cataloged", "completed", "failed"
    result_doc_id UUID REFERENCES documents(doc_id),
    batch_id UUID REFERENCES ingest_batches(batch_id),
    error_details JSONB,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Key Indexes**:
```sql
CREATE INDEX idx_ingest_submissions_status ON ingest_submissions(status);
CREATE INDEX idx_ingest_submissions_source ON ingest_submissions(source_type, source_id);
CREATE INDEX idx_ingest_submissions_batch_id ON ingest_submissions(batch_id);
CREATE INDEX idx_ingest_submissions_batch_status ON ingest_submissions(batch_id, status);
```

**Usage**:
- Gateway computes `idempotency_key` from content hash + metadata
- Catalog checks key before inserting document
- Enables safe retries and duplicate detection
- Links submission to resulting document via `result_doc_id`
- Optional `batch_id` references `ingest_batches` when the submission originated from `/v1/ingest:batch`

---

### 8. source_change_tokens

Stores incremental sync state for collectors.

**Purpose**: Track last-seen change tokens for incremental synchronization.

**Schema**:
```sql
CREATE TABLE source_change_tokens (
    source TEXT NOT NULL,
    device_id TEXT NOT NULL,
    change_token_b64 TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source, device_id)
);
```

**Usage**:
- Contacts collector stores CNContactStore change tokens
- Enables incremental sync without re-processing all data
- `device_id` supports multi-device scenarios

---

## Type-Specific Metadata

The `metadata` JSONB column in `documents` contains source-specific structured data.

### Messages (imessage, sms, email)

```jsonb
{
    "source": "imessage",
    "message": {
        "guid": "6F15DDA0-9D80-4872-9B99-51D509AD24BE",
        "sent_at": "2020-09-10T22:42:46.195666+00:00",
        "received_at": "2020-09-10T22:42:46.195666+00:00",
        "sender": "+14197330824",
        "is_from_me": false,
        "service": "iMessage",
        "direction": "received",
        "read": true,
        "row_id": 124398
    },
    "attachments": {
        "known": [
            {
                "attachment_index": 0,
                "filename": "IMG_2930.png",
                "mime_type": "image/png",
                "size_bytes": 359915,
                "file_id": "uuid-of-file",
                "enriched": true
            }
        ]
    },
    "reply_to_guid": "parent-message-guid",
    "thread_originator_guid": "thread-start-guid",
    "associated_message_guid": "sticker-parent-guid",
    "associated_message_type": 1000,
    "is_audio_message": false,
    "expire_state": null,
    "expressive_send_style_id": null,
    "extraction": {
        "status": "ready",
        "method": "direct_text"
    },
    "ingested_at": "2025-10-15T16:13:39.525813+00:00"
}
```

**Key Fields**:
- `message.guid`: Source-specific message ID (matches `external_id` suffix)
- `message.row_id`: Original database row ID for lookups
- `reply_to_guid`: Parent message for thread reconstruction
- `associated_message_type`: 1000 = sticker, 2000 = reaction
- `is_audio_message`: Voice message flag
- `expire_state`: Voice message expiration (1=expired, 3=saved)
- `expressive_send_style_id`: Message effects (Bloom, Echo, Confetti, etc.)

**Special Message Types** (detected by collector):
- **Stickers**: `associated_message_type=1000`, references parent via `associated_message_guid`
- **Voice messages**: `is_audio_message=true`, includes expiration state
- **Emoji/memoji images**: Flagged via attributed body `__kIMEmojiImageAttributeName`
- **iCloud document links**: URL in text, rich link flag in attributed body
- **Replies**: `reply_to_guid` present, parent text excerpt included in formatted text

### Files (localfs, gdrive)

```jsonb
{
    "source": "localfs",
    "file": {
        "path": "/Users/chrispatten/haven_dropbox/Org Structure.md",
        "filename": "Org Structure.md",
        "size_bytes": 1790,
        "mime_type": "text/markdown",
        "sha256": "2e1aeed44718c3f154e47383facae3c53a20e64845e70ee9074255cdd0c50c91",
        "created_at": "2025-06-19T17:51:19.639659+00:00",
        "modified_at": "2025-06-19T17:51:19.639659+00:00",
        "tags": ["work", "documentation"]
    },
    "extraction": {
        "status": "ready",
        "method": "direct_read",
        "detected_encoding": "utf-8"
    }
}
```

### Contacts

```jsonb
{
    "source": "contact",
    "contact": {
        "given_name": "John",
        "family_name": "Doe",
        "organization_name": "Acme Corp",
        "emails": [
            {"value": "john@example.com", "label": "work"}
        ],
        "phones": [
            {"value": "+15551234567", "label": "mobile"}
        ],
        "addresses": [
            {
                "street": "123 Main St",
                "city": "San Francisco",
                "state": "CA",
                "postal_code": "94102",
                "label": "work"
            }
        ],
        "birthday": "1985-03-15",
        "notes": "Met at conference 2024"
    }
}
```

### Notes (apple_notes, notion)

```jsonb
{
    "source": "apple_notes",
    "note": {
        "note_id": "x-coredata://...",
        "folder": "Personal/Ideas",
        "created_at": "2023-01-15T10:30:00.000Z",
        "modified_at": "2023-01-20T15:45:00.000Z",
        "locked": false,
        "pinned": true
    },
    "extraction": {
        "status": "ready",
        "method": "html_to_text",
        "has_images": true,
        "has_checklists": true
    }
}
```

### Reminders (apple_reminders, todoist)

```jsonb
{
    "source": "apple_reminders",
    "reminder": {
        "reminder_id": "x-apple-reminder://...",
        "list": "Work",
        "priority": 3,
        "flagged": true,
        "notes": "Additional context",
        "recurrence": "weekly",
        "subtasks": [
            {"title": "Subtask 1", "completed": false}
        ]
    }
}
```

### Calendar Events (apple_calendar, google_calendar)

```jsonb
{
    "source": "apple_calendar",
    "event": {
        "event_id": "uuid-from-calendar",
        "calendar": "Work",
        "location": "123 Main St, San Francisco, CA",
        "start_time": "2023-02-15T14:00:00.000Z",
        "end_time": "2023-02-15T15:00:00.000Z",
        "all_day": false,
        "timezone": "America/Los_Angeles",
        "recurrence": "weekly",
        "status": "confirmed",
        "organizer": "boss@company.com",
        "attendees": [
            {"email": "person1@company.com", "status": "accepted"}
        ]
    }
}
```

---

## File Enrichment Schema

The `enrichment` JSONB column in `files` contains content-based enrichment data.

### Image Files

```jsonb
{
    "ocr": {
        "text": "Extracted text from image",
        "confidence": 0.95,
        "language": "en",
        "boxes": [
            {
                "text": "specific text region",
                "x": 0.005, "y": 0.861, "w": 0.854, "h": 0.065,
                "confidence": 0.97
            }
        ],
        "entities": {
            "dates": ["2024-10-15"],
            "phone_numbers": ["+15551234567"],
            "emails": ["test@example.com"],
            "urls": ["https://example.com"],
            "addresses": ["123 Main St, San Francisco"]
        }
    },
    "caption": {
        "text": "A group of people standing in front of a building",
        "model": "llava:13b",
        "confidence": 0.85,
        "generated_at": "2025-10-08T19:25:30.000Z"
    },
    "vision": {
        "faces": [
            {"x": 0.1, "y": 0.2, "w": 0.15, "h": 0.2, "confidence": 0.92}
        ],
        "objects": [
            {"label": "person", "confidence": 0.95, "count": 3}
        ],
        "scene": "outdoor",
        "colors": {
            "dominant": ["#F0F0F0", "#333333"]
        }
    },
    "exif": {
        "camera": "iPhone 14 Pro",
        "taken_at": "2023-03-27T23:45:00.000Z",
        "location": {
            "latitude": 37.7749,
            "longitude": -122.4194
        },
        "width": 1920,
        "height": 1080
    }
}
```

**Enrichment Sources**:
- **OCR**: Native macOS Vision API via `imdesc` CLI helper
- **Caption**: Ollama vision models (llava:13b, qwen2.5vl:3b)
- **Vision**: Object detection, face detection, scene classification
- **EXIF**: Camera metadata, GPS coordinates, timestamps

### PDF Files

```jsonb
{
    "pdf": {
        "pages": 5,
        "version": "1.4",
        "title": "Q4 Financial Report",
        "author": "Finance Department",
        "created_at": "2023-12-01T10:00:00.000Z"
    },
    "ocr": {
        "text": "Full extracted text from all pages",
        "confidence": 0.92,
        "method": "tesseract",
        "per_page": [
            {"page": 1, "text": "Page 1 text", "confidence": 0.95}
        ]
    },
    "structure": {
        "toc": [
            {"title": "Executive Summary", "page": 1}
        ],
        "tables_detected": 5
    }
}
```

### Video/Audio Files

```jsonb
{
    "media": {
        "duration_seconds": 125.5,
        "width": 1920,
        "height": 1080,
        "codec": "h264"
    },
    "transcription": {
        "text": "Full transcription",
        "confidence": 0.88,
        "segments": [
            {
                "start": 0.0,
                "end": 5.2,
                "text": "Welcome to the presentation"
            }
        ]
    }
}
```

---

## People Normalization Schema

### Overview

The people normalization system resolves and merges contact identities across multiple sources (iMessage, Contacts, email) into unified person records. This enables accurate attribution of documents to people, contact deduplication, and relationship intelligence.

### Architecture

**Key Tables**:
- `people`: Normalized person records with display names, structured names, and metadata
- `person_identifiers`: Phone numbers and email addresses in canonical format
- `person_addresses`: Physical addresses associated with people
- `person_urls`: Web URLs and social profiles
- `people_source_map`: Maps external contact IDs to unified person records
- `document_people`: Junction table linking documents to people with roles
- `people_conflict_log`: Tracks merge conflicts for manual resolution

**Data Flow**:
1. **Contact Ingestion**: Contacts collector imports from macOS Contacts or VCF files
2. **Identifier Normalization**: Phone/email identifiers converted to canonical format (E.164 for phones, lowercase for emails)
3. **Person Resolution**: Identifiers matched against existing people records
4. **Merge Detection**: Duplicate detection based on identifier overlap
5. **Document Attribution**: Documents linked to people via `document_people` junction

### Table: people

Primary table for normalized person records.

**Purpose**: Store unified person records merged from multiple contact sources.

**Schema**:
```sql
CREATE TABLE people (
    person_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    display_name TEXT NOT NULL,
    given_name TEXT,
    family_name TEXT,
    organization TEXT,
    nicknames TEXT[] DEFAULT '{}',
    notes TEXT,
    photo_hash TEXT,
    source TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    deleted BOOLEAN NOT NULL DEFAULT false,
    merged_into UUID REFERENCES people(person_id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Key Columns**:

| Column | Type | Description |
|--------|------|-------------|
| `person_id` | UUID | Immutable primary key for the person |
| `display_name` | TEXT | Primary name shown in UI (required) |
| `given_name` | TEXT | First/given name |
| `family_name` | TEXT | Last/family name |
| `organization` | TEXT | Company or organization affiliation |
| `nicknames` | TEXT[] | Array of alternate names |
| `notes` | TEXT | Free-form notes about the person |
| `photo_hash` | TEXT | Hash of contact photo for deduplication |
| `source` | TEXT | Primary source (e.g., 'macos_contacts', 'vcf') |
| `version` | INTEGER | Version number for optimistic locking |
| `deleted` | BOOLEAN | Soft delete flag |
| `merged_into` | UUID | Points to person this record was merged into |
| `created_at` | TIMESTAMPTZ | When the person record was created |
| `updated_at` | TIMESTAMPTZ | Last update timestamp |

**Design Notes**:
- **Soft Deletes**: `deleted=true` marks person as removed but preserves history
- **Merge Tracking**: `merged_into` creates a chain to final person record
- **Version Control**: `version` enables optimistic locking for concurrent updates
- **Source Tracking**: `source` indicates primary source for conflict resolution

### Table: person_identifiers

Normalized phone numbers and email addresses.

**Purpose**: Store canonical identifiers for person matching and resolution.

**Schema**:
```sql
CREATE TYPE identifier_kind AS ENUM ('phone', 'email');

CREATE TABLE person_identifiers (
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    kind identifier_kind NOT NULL,
    value_raw TEXT NOT NULL,
    value_canonical TEXT NOT NULL,
    label TEXT,
    priority INTEGER NOT NULL DEFAULT 100,
    verified BOOLEAN NOT NULL DEFAULT true,
    CONSTRAINT person_identifiers_unique UNIQUE (person_id, kind, value_canonical)
);

CREATE INDEX idx_person_identifiers_lookup ON person_identifiers(kind, value_canonical);
```

**Key Columns**:

| Column | Type | Description |
|--------|------|-------------|
| `person_id` | UUID | Foreign key to people |
| `kind` | ENUM | Type: 'phone' or 'email' |
| `value_raw` | TEXT | Original value as entered |
| `value_canonical` | TEXT | Normalized value (E.164 for phone, lowercase for email) |
| `label` | TEXT | Optional label (e.g., 'work', 'home', 'mobile') |
| `priority` | INTEGER | Display order (lower = higher priority) |
| `verified` | BOOLEAN | Whether identifier is verified |

**Design Notes**:
- **Canonical Format**: Phone numbers normalized to E.164 (+country code), emails to lowercase
- **Deduplication**: Unique constraint on `(person_id, kind, value_canonical)`
- **Fast Lookup**: Index on `(kind, value_canonical)` enables efficient person resolution
- **Label Flexibility**: Label is free-form text, not constrained

### Table: document_people

Junction table linking documents to people.

**Purpose**: Track which people are associated with each document and their role.

**Schema**:
```sql
CREATE TABLE document_people (
    doc_id UUID NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    PRIMARY KEY (doc_id, person_id),
    CONSTRAINT document_people_valid_role CHECK (
        role IN ('sender', 'recipient', 'participant', 'mentioned', 'contact')
    )
);

CREATE INDEX idx_document_people_person ON document_people(person_id);
CREATE INDEX idx_document_people_doc ON document_people(doc_id);
CREATE INDEX idx_document_people_role ON document_people(role);
```

**Key Columns**:

| Column | Type | Description |
|--------|------|-------------|
| `doc_id` | UUID | Foreign key to documents |
| `person_id` | UUID | Foreign key to people |
| `role` | TEXT | Role: 'sender', 'recipient', 'participant', 'mentioned', 'contact' |

**Roles**:
- **sender**: Person who authored/sent the message or document
- **recipient**: Direct recipient of a message
- **participant**: Thread participant (group conversations)
- **mentioned**: Person referenced in the content
- **contact**: For contact-type documents, the person the contact represents

**Design Notes**:
- **Many-to-Many**: Documents can have multiple people, people can be in multiple documents
- **Role-Based Queries**: Index on `role` enables efficient filtering
- **Cascade Deletes**: Removing document or person cleans up junction records

### Table: people_source_map

Maps external contact IDs to unified person records.

**Purpose**: Track which external contact IDs map to which person_id for sync operations.

**Schema**:
```sql
CREATE TABLE people_source_map (
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    CONSTRAINT people_source_map_unique UNIQUE (source, external_id)
);

CREATE INDEX idx_people_source_map_person ON people_source_map(person_id);
```

**Key Columns**:

| Column | Type | Description |
|--------|------|-------------|
| `source` | TEXT | Source system (e.g., 'macos_contacts', 'vcf') |
| `external_id` | TEXT | ID in source system |
| `person_id` | UUID | Unified person record |

**Design Notes**:
- **Idempotency**: Enables repeated imports to update same person record
- **Multi-Source**: Same person can have entries from multiple sources
- **Sync Support**: Used by contacts collector to detect updates vs. creates

### PeopleRepository API

The `PeopleRepository` class provides high-level operations for person management.

**Key Methods**:

```python
class PeopleRepository:
    def upsert_batch(
        self, 
        source: str, 
        batch: Sequence[PersonIngestRecord]
    ) -> UpsertStats
    """
    Upsert multiple person records atomically.
    - Resolves person_id via source_map or creates new
    - Updates person fields only if changed
    - Refreshes identifiers, addresses, URLs
    - Handles soft deletes
    - Returns statistics (created, updated, deleted, skipped)
    """
    
    def get_person(
        self, 
        person_id: UUID, 
        include_identifiers: bool = True
    ) -> Optional[Dict]
    """
    Retrieve full person record with optional identifiers.
    """
    
    def list_people(
        self, 
        limit: int = 100, 
        offset: int = 0, 
        include_deleted: bool = False
    ) -> List[Dict]
    """
    List people with pagination and optional deleted records.
    """
    
    def search_people(
        self, 
        query: str, 
        limit: int = 20
    ) -> List[Dict]
    """
    Full-text search across display_name, given_name, family_name, organization.
    """
```

### PeopleResolver API

The `PeopleResolver` class handles identifier-to-person lookups.

**Key Methods**:

```python
class PeopleResolver:
    def resolve(
        self, 
        kind: IdentifierKind, 
        value: str
    ) -> Optional[Dict[str, str]]
    """
    Resolve a single identifier to person.
    Returns: {'person_id': '...', 'display_name': '...'}
    """
    
    def resolve_many(
        self, 
        items: Sequence[tuple[IdentifierKind, str]]
    ) -> Dict[str, Dict[str, str]]
    """
    Batch resolve multiple identifiers.
    Returns: {'phone:+15551234567': {'person_id': '...', 'display_name': '...'}}
    """
```

**Usage Example**:
```python
from shared.people_repository import PeopleResolver
from shared.people_normalization import IdentifierKind

resolver = PeopleResolver(conn, default_region="US")

# Resolve single identifier
person = resolver.resolve(IdentifierKind.PHONE, "+1 (555) 123-4567")
if person:
    print(f"Found {person['display_name']} ({person['person_id']})")

# Batch resolve
items = [
    (IdentifierKind.PHONE, "+15551234567"),
    (IdentifierKind.EMAIL, "john@example.com")
]
results = resolver.resolve_many(items)
```

### Self-Person Detection

The system supports identifying which person record represents the user ("self") for relationship calculations.

**Storage**: `system_settings` table stores `self_person_id`

**Detection Methods**:
1. **Manual Configuration**: Admin sets self_person_id via API
2. **Auto-Detection**: Analyzes message patterns (high outbound ratio, specific identifiers)
3. **MIME Charset Analysis**: Uses charset metadata from email sources as a signal

**API Functions**:
```python
def get_self_person_id_from_settings(conn: Connection) -> Optional[UUID]
    """Retrieve self_person_id from system_settings"""

def store_self_person_id_if_needed(conn: Connection, person_id: UUID) -> bool
    """Store self_person_id if not already set"""
```

**Usage**: CRM relationship calculations use `self_person_id` as the subject for directional scoring.

---

## CRM Relationship Schema

### Overview

The CRM relationship tables store relationship strength scores between people, enabling efficient queries for contact prioritization and relationship management. This system computes and tracks relationship metrics (frequency, recency, etc.) to power Haven's contact intelligence features.

### Architecture

**Key Tables**:
- `crm_relationships`: Directional relationship scores between person pairs
- `people`: Contact/person records (existing; referenced by FK)

**Data Flow**:
1. **Ingestion**: Documents with people metadata create raw contact signals
2. **Feature Aggregation** (hv-62): Scheduled job computes edge metrics from documents
3. **Scoring** (hv-63): Scheduled job updates relationship scores using hv-62 features
4. **Query**: Gateway queries for top relationships, recent contacts, etc.

### Table: crm_relationships

Primary table for directional relationship scoring.

**Purpose**: Store computed relationship strength scores and metadata for efficient top-N queries.

**Schema**:
```sql
CREATE TABLE crm_relationships (
    relationship_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Relationship Endpoints (directional: self_person_id → person_id)
    self_person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    
    -- Scoring & Metrics
    score FLOAT NOT NULL,                   -- Relationship strength (0.0 and above; range/normalization per hv-62)
    last_contact_at TIMESTAMPTZ NOT NULL,  -- Most recent message/contact with this person
    decay_bucket INT NOT NULL,              -- Temporal bucket: 0=today, 1=week, 2=month, 3=quarter, etc.
    
    -- Computed Edge Features (used by scoring jobs)
    edge_features JSONB DEFAULT '{}',       -- {"days_since_contact": 3, "messages_30d": 12, "messages_90d": 42, ...}
    
    -- Metadata
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT crm_relationships_unique UNIQUE (self_person_id, person_id),
    CONSTRAINT crm_relationships_valid_score CHECK (score >= 0.0),
    CONSTRAINT crm_relationships_valid_decay_bucket CHECK (decay_bucket >= 0)
);
```

**Key Columns**:

| Column | Type | Description |
|--------|------|-------------|
| `relationship_id` | UUID | Immutable primary key for the relationship edge |
| `self_person_id` | UUID | FK to `people`: the observer/subject ("me") |
| `person_id` | UUID | FK to `people`: the other party ("contact") |
| `score` | FLOAT | Relationship strength score (computed and updated by hv-63 job) |
| `last_contact_at` | TIMESTAMPTZ | Timestamp of most recent message/contact with this person |
| `decay_bucket` | INT | Temporal bucketing for efficient time-windowed queries |
| `edge_features` | JSONB | Raw metrics: `days_since_contact`, `messages_30d`, `messages_90d`, etc. |
| `created_at` | TIMESTAMPTZ | When the relationship record was created |
| `updated_at` | TIMESTAMPTZ | Last update timestamp (maintained by trigger) |

**Design Notes**:
- **Directionality**: Relationship is directional. `(self_person_id=A, person_id=B)` means "A's relationship with B". The reverse relationship `(A→B)` is separate.
- **Score Range**: Determined by hv-62; may be 0-1 or 0-100. Constraint is `>= 0.0`.
- **Decay Bucket**: Integer enabling efficient queries like "relationships from this week" via index on `(self_person_id, score DESC) WHERE decay_bucket IN (0, 1)`.
- **Edge Features**: JSONB storing raw metrics for debugging, analytics, and downstream feature engineering. Examples:
  - `messages_30d`: Count of messages in last 30 days
  - `messages_90d`: Count in last 90 days
  - `days_since_contact`: Days since last message
  - `thread_count`: Number of distinct threads
  - `avg_message_length`: Average message length in conversation
- **Update Frequency**: Refreshed by scheduled jobs (hv-63). Manual inserts via API not expected during normal operation.

### Indexes

**Designed to Support Primary Query Patterns**:

```sql
-- 1. Top N relationships for person X (primary access pattern)
CREATE INDEX idx_crm_relationships_top_score ON crm_relationships(
    self_person_id,
    score DESC,
    last_contact_at DESC
);
-- Usage: WHERE self_person_id = ? ORDER BY score DESC, last_contact_at DESC LIMIT N

-- 2. Recent contacts (time-windowed queries)
CREATE INDEX idx_crm_relationships_recent_contacts ON crm_relationships(
    self_person_id,
    last_contact_at DESC
);
-- Usage: WHERE self_person_id = ? AND last_contact_at > ? ORDER BY last_contact_at DESC

-- 3. Reverse lookup (who has me as a relationship)
CREATE INDEX idx_crm_relationships_person_lookup ON crm_relationships(person_id);
-- Usage: WHERE person_id = ?

-- 4. Partial index on recent decay buckets (optimization for common time windows)
CREATE INDEX idx_crm_relationships_decay_bucket_recent ON crm_relationships(
    self_person_id,
    score DESC
)
WHERE decay_bucket IN (0, 1, 2);  -- Today, week, month
-- Usage: WHERE self_person_id = ? AND decay_bucket IN (0, 1, 2) ORDER BY score DESC
```

**Index Rationale**:
- **`idx_crm_relationships_top_score`**: Primary query pattern. Efficiently finds strongest relationships for a given person. Sort by score desc, then by recency.
- **`idx_crm_relationships_recent_contacts`**: Supports time-windowed queries without filtering on score. Useful for "recent contacts" regardless of strength.
- **`idx_crm_relationships_person_lookup`**: Reverse lookup. Finds all relationships where this person is the contact (used for deduplication, conflict detection).
- **`idx_crm_relationships_decay_bucket_recent`**: Partial index for common time windows. Reduces index size and improves query performance for recent relationships.

### Example Queries

**Get top 10 relationships for current user**:
```sql
SELECT 
    cr.relationship_id,
    cr.person_id,
    p.display_name,
    cr.score,
    cr.last_contact_at,
    cr.edge_features
FROM crm_relationships cr
JOIN people p ON cr.person_id = p.person_id
WHERE cr.self_person_id = $1
ORDER BY cr.score DESC, cr.last_contact_at DESC
LIMIT 10;
```

**Get top 5 relationships in last 90 days**:
```sql
SELECT 
    cr.relationship_id,
    cr.person_id,
    p.display_name,
    cr.score,
    cr.last_contact_at
FROM crm_relationships cr
JOIN people p ON cr.person_id = p.person_id
WHERE cr.self_person_id = $1
    AND cr.last_contact_at > NOW() - interval '90 days'
ORDER BY cr.score DESC
LIMIT 5;
```

**Get all people who have user as a contact**:
```sql
SELECT DISTINCT
    cr.self_person_id,
    p.display_name
FROM crm_relationships cr
JOIN people p ON cr.self_person_id = p.person_id
WHERE cr.person_id = $1;
```

### Relationship Feature Aggregation

Haven computes relationship strength scores based on communication patterns extracted from message history. The feature aggregation pipeline analyzes document metadata to generate metrics that feed the scoring algorithm.

**Feature Computation Pipeline**:

1. **Extract Message Events**: Query `document_people` joined with `documents` to extract directional message events (sender → recipient)
2. **Compute Edge Features**: For each `(self_person_id, person_id)` pair, calculate:
   - `days_since_last_message`: Days elapsed since most recent message
   - `messages_30d`: Message count in last 30 days
   - `messages_90d`: Message count in last 90 days
   - `distinct_threads_90d`: Number of distinct conversation threads
   - `attachments_30d`: Attachment count in last 30 days
   - `avg_reply_latency_seconds`: Average time between outbound and inbound messages
3. **Compute Decay Bucket**: Temporal bucket based on recency (0=today, 1=week, 2=month, 3=quarter, etc.)
4. **Calculate Score**: Weighted combination of features (implementation in `relationship_features.py`)
5. **Upsert to `crm_relationships`**: Store or update relationship records with computed metrics

**Feature Implementation** (`services/search_service/relationship_features.py`):

```python
@dataclass(frozen=True, slots=True)
class RelationshipEvent:
    """Single directional message event"""
    self_person_id: UUID
    person_id: UUID
    timestamp: datetime
    thread_id: Optional[UUID]
    direction: str  # "inbound" | "outbound"
    attachment_count: int
    thread_participant_count: int

@dataclass(frozen=True, slots=True)
class RelationshipFeatureSummary:
    last_contact_at: datetime
    days_since_last_message: float
    messages_30d: int
    distinct_threads_90d: int
    attachments_30d: int
    avg_reply_latency_seconds: Optional[float]
    decay_bucket: int
```

**SQL Query for Event Extraction**:

The feature aggregation job runs this query to extract all message events:

```sql
WITH sender_events AS (
    SELECT 
        dp_sender.person_id AS sender_person_id,
        dp_recipient.person_id AS recipient_person_id,
        d.content_timestamp,
        d.thread_id,
        d.attachment_count,
        COUNT(DISTINCT dp_all.person_id) AS participant_count
    FROM documents d
    JOIN document_people dp_sender ON d.doc_id = dp_sender.doc_id AND dp_sender.role = 'sender'
    JOIN document_people dp_recipient ON d.doc_id = dp_recipient.doc_id AND dp_recipient.role = 'recipient'
    LEFT JOIN document_people dp_all ON d.doc_id = dp_all.doc_id
    WHERE d.is_active_version = true
        AND d.source_type IN ('imessage', 'sms', 'email')
    GROUP BY dp_sender.person_id, dp_recipient.person_id, d.doc_id
),
bidirectional_events AS (
    SELECT 
        b.sender_person_id AS self_person_id,
        b.recipient_person_id AS person_id,
        b.content_timestamp,
        b.thread_id,
        'outbound' AS direction,
        b.attachment_count,
        b.participant_count
    FROM sender_events b
    UNION ALL
    SELECT 
        b.recipient_person_id AS self_person_id,
        b.sender_person_id AS person_id,
        b.content_timestamp,
        b.thread_id,
        'inbound' AS direction,
        b.attachment_count,
        b.participant_count
    FROM sender_events b
)
SELECT 
    self_person_id,
    person_id,
    content_timestamp,
    thread_id,
    direction,
    attachment_count,
    participant_count
FROM bidirectional_events
WHERE self_person_id <> person_id
ORDER BY self_person_id, person_id, content_timestamp;
```

**Feature Calculation Logic**:

```python
def compute_features(events: List[RelationshipEvent]) -> RelationshipFeatureSummary:
    """
    Compute relationship features from chronological event list.
    
    Metrics:
    - last_contact_at: Most recent message timestamp
    - days_since_last_message: Time since last contact
    - messages_30d: Count of messages in last 30 days
    - distinct_threads_90d: Unique threads in last 90 days
    - attachments_30d: Attachments exchanged in last 30 days
    - avg_reply_latency_seconds: Average time between outbound and next inbound
    - decay_bucket: Temporal bucket (0=today, 1=this week, 2=this month, etc.)
    """
    now = datetime.now(UTC)
    last_contact = events[-1].timestamp
    days_since = (now - last_contact).total_seconds() / 86400
    
    cutoff_30d = now - timedelta(days=30)
    cutoff_90d = now - timedelta(days=90)
    
    messages_30d = sum(1 for e in events if e.timestamp >= cutoff_30d)
    attachments_30d = sum(e.attachment_count for e in events if e.timestamp >= cutoff_30d)
    threads_90d = len({e.thread_id for e in events if e.timestamp >= cutoff_90d and e.thread_id})
    
    # Reply latency: time between outbound message and next inbound
    latencies = []
    for i in range(len(events) - 1):
        if events[i].direction == 'outbound' and events[i+1].direction == 'inbound':
            delta = (events[i+1].timestamp - events[i].timestamp).total_seconds()
            if 0 < delta < 86400:  # Only count replies within 24 hours
                latencies.append(delta)
    
    avg_latency = sum(latencies) / len(latencies) if latencies else None
    
    # Decay bucket: 0=today, 1=this week, 2=this month, 3=this quarter, 4=older
    if days_since < 1:
        decay_bucket = 0
    elif days_since < 7:
        decay_bucket = 1
    elif days_since < 30:
        decay_bucket = 2
    elif days_since < 90:
        decay_bucket = 3
    else:
        decay_bucket = 4
    
    return RelationshipFeatureSummary(
        last_contact_at=last_contact,
        days_since_last_message=days_since,
        messages_30d=messages_30d,
        distinct_threads_90d=threads_90d,
        attachments_30d=attachments_30d,
        avg_reply_latency_seconds=avg_latency,
        decay_bucket=decay_bucket
    )
```

**Scoring Algorithm**:

The relationship score combines multiple signals:

```python
def compute_score(features: RelationshipFeatureSummary) -> float:
    """
    Compute relationship strength score from features.
    
    Scoring factors:
    - Recency: Exponential decay based on days_since_last_message
    - Frequency: Message count with diminishing returns
    - Engagement: Thread diversity, attachments, reply speed
    """
    # Recency factor (exponential decay, half-life = 30 days)
    recency = math.exp(-features.days_since_last_message / 30.0)
    
    # Frequency factor (log scale with saturation)
    frequency = math.log1p(features.messages_30d)
    
    # Engagement factor
    thread_diversity = math.log1p(features.distinct_threads_90d)
    attachment_bonus = min(features.attachments_30d * 0.1, 2.0)  # Cap at +2.0
    reply_speed_bonus = 1.0
    if features.avg_reply_latency_seconds:
        # Faster replies = higher score (inverse of latency in hours)
        reply_speed_bonus = 1.0 / (1.0 + features.avg_reply_latency_seconds / 3600)
    
    # Weighted combination
    score = (
        recency * 40.0 +           # Recency is most important
        frequency * 20.0 +          # Frequency matters but saturates
        thread_diversity * 15.0 +   # Multi-thread engagement
        attachment_bonus * 10.0 +   # Multimedia richness
        reply_speed_bonus * 15.0    # Responsiveness
    )
    
    return round(score, 2)
```

**Scheduled Job Execution**:

The feature aggregation job should run periodically (e.g., daily or hourly) to keep relationship scores current:

```bash
# Example: Daily refresh at 3am
0 3 * * * python -m services.search_service.relationship_features --refresh-all
```

The job:
1. Extracts all message events from `document_people` + `documents`
2. Groups events by `(self_person_id, person_id)` pair
3. Computes features for each pair
4. Calculates scores
5. Upserts to `crm_relationships` table

**Performance Considerations**:
- Full refresh scans all active documents; consider incremental updates for large datasets
- Indexes on `document_people(role)` and `documents(content_timestamp)` are critical
- Consider materialized view for event extraction query if dataset is very large

---

## Query Patterns

### 1. Timeline: Recent Activity

```sql
SELECT 
    doc_id,
    source_type,
    title,
    LEFT(text, 100) as preview,
    content_timestamp,
    content_timestamp_type,
    has_attachments,
    people
FROM documents
WHERE is_active_version = true
ORDER BY content_timestamp DESC
LIMIT 50;
```

### 2. Search with Facets

```sql
-- Messages with attachments from specific person
SELECT 
    d.doc_id,
    d.title,
    d.text,
    d.content_timestamp,
    d.attachment_count
FROM documents d
WHERE d.is_active_version = true
    AND d.has_attachments = true
    AND d.people @> '[{"identifier": "+15551234567"}]'::jsonb
    AND d.source_type IN ('imessage', 'sms', 'email')
ORDER BY d.content_timestamp DESC;
```

### 3. Thread Context

```sql
-- Get messages around a target message (5 minutes before/after)
WITH target AS (
    SELECT doc_id, thread_id, content_timestamp
    FROM documents
    WHERE doc_id = 'target-doc-id'
)
SELECT 
    d.doc_id,
    d.text,
    d.content_timestamp,
    d.people
FROM documents d
JOIN target t ON d.thread_id = t.thread_id
WHERE d.is_active_version = true
    AND d.content_timestamp BETWEEN 
        (SELECT content_timestamp FROM target) - INTERVAL '5 minutes'
        AND (SELECT content_timestamp FROM target) + INTERVAL '5 minutes'
ORDER BY d.content_timestamp ASC;
```

### 4. Version History

```sql
-- Get all versions of a document
WITH RECURSIVE version_chain AS (
    SELECT 
        doc_id, external_id, version_number, 
        previous_version_id, is_active_version,
        0 as depth
    FROM documents
    WHERE external_id = 'imessage:ABC123' 
        AND is_active_version = true
    
    UNION ALL
    
    SELECT 
        d.doc_id, d.external_id, d.version_number,
        d.previous_version_id, d.is_active_version,
        vc.depth + 1
    FROM documents d
    JOIN version_chain vc ON d.doc_id = vc.previous_version_id
)
SELECT * FROM version_chain 
ORDER BY version_number DESC;
```

### 5. File Deduplication

```sql
-- Find all documents with same file
SELECT 
    d.doc_id,
    d.source_type,
    d.title,
    d.content_timestamp,
    df.role,
    f.filename,
    f.mime_type
FROM documents d
JOIN document_files df ON d.doc_id = df.doc_id
JOIN files f ON df.file_id = f.file_id
WHERE f.content_sha256 = 'target-sha256'
    AND d.is_active_version = true
ORDER BY d.content_timestamp DESC;
```

### 6. Upcoming Tasks

```sql
SELECT 
    doc_id,
    source_type,
    title,
    due_date,
    metadata->'reminder'->>'priority' as priority
FROM documents
WHERE is_active_version = true
    AND has_due_date = true
    AND due_date >= NOW()
    AND (is_completed IS NULL OR is_completed = false)
ORDER BY due_date ASC;
```

### 7. Semantic Search with Filters

```sql
-- Vector similarity with document facets
SELECT 
    d.doc_id,
    d.title,
    d.text,
    c.chunk_id,
    c.text as chunk_text,
    c.embedding_vector <=> $1 as similarity
FROM chunks c
JOIN chunk_documents cd ON c.chunk_id = cd.chunk_id
JOIN documents d ON cd.doc_id = d.doc_id
WHERE d.is_active_version = true
    AND d.source_type = 'imessage'
    AND d.content_timestamp >= NOW() - INTERVAL '30 days'
    AND c.embedding_status = 'embedded'
ORDER BY c.embedding_vector <=> $1
LIMIT 10;
```

### 8. Thread Summary

```sql
SELECT 
    t.thread_id,
    t.title,
    t.participant_count,
    t.first_message_at,
    t.last_message_at,
    COUNT(d.doc_id) as message_count,
    SUM(CASE WHEN d.has_attachments THEN 1 ELSE 0 END) as attachment_count
FROM threads t
LEFT JOIN documents d ON t.thread_id = d.thread_id 
    AND d.is_active_version = true
WHERE t.thread_id = 'target-thread-id'
GROUP BY t.thread_id, t.title, t.participant_count, 
         t.first_message_at, t.last_message_at;
```

---

## Workflow Status

### Document Status Flow

```
submitted → extracting → extracted → enriching → enriched → indexed
              ↓                                      ↓
         extraction_failed                   enrichment_failed
```

**States**:
- `submitted`: Document received, queued for processing
- `extracting`: Binary content being extracted to text
- `extracted`: Text extracted, ready for enrichment
- `enriching`: Attachments being enriched (OCR, captions)
- `enriched`: All enrichment complete
- `indexed`: Document indexed in search service
- `failed`: Terminal failure state

**Flags**:
- `extraction_failed`: Extraction failed, document may have limited content
- `enrichment_failed`: Enrichment failed, document searchable but attachments lack metadata
- Both flags allow progressive enhancement without blocking access

### File Enrichment Status

```
pending → processing → enriched
             ↓
          failed / skipped
```

**States**:
- `pending`: File waiting for enrichment
- `processing`: Enrichment in progress
- `enriched`: All enrichment complete
- `failed`: Enrichment failed (corrupt file, API error)
- `skipped`: Enrichment skipped (unsupported format, too large)

### Chunk Embedding Status

```
pending → processing → embedded
             ↓
          failed
```

**States**:
- `pending`: Chunk waiting for embedding generation
- `processing`: Embedding model running
- `embedded`: Vector stored, ready for search
- `failed`: Embedding failed (API error, timeout)

---

## Service Integration

### Catalog API

**Endpoint**: `POST /v1/catalog/documents`
- Accepts `DocumentIngestRequest` with v2 structure
- Inserts into `documents`, `document_files`, `chunks`, `chunk_documents`, `ingest_submissions`
- Enforces `is_active_version`, updates threads, handles deduplication
- Returns `DocumentIngestResponse` with IDs

**Endpoint**: `PATCH /v1/catalog/documents/{doc_id}/version`
- Creates new document version
- Links to previous version via `previous_version_id`
- Marks old version as inactive (`is_active_version=false`)

**Endpoint**: `POST /v1/catalog/embeddings`
- Updates chunk vectors
- Marks chunks as `embedded`
- Triggers document status update to `indexed`

### Gateway API

**Endpoint**: `POST /v1/ingest`
- Builds v2 document payload
- Normalizes timestamps to `content_timestamp` + `content_timestamp_type`
- Extracts `people` array from message metadata
- Computes `idempotency_key` from content hash
- Forwards to catalog

**Endpoint**: `POST /v1/ingest/file`
- Uploads binary to MinIO
- Calculates SHA256 for deduplication
- Creates file record with enrichment metadata
- Links to document via `document_files`

**Endpoint**: `GET /v1/search`
- Accepts filters: `has_attachments`, `source_type`, `person`, `thread_id`, `start_date`, `end_date`
- Forwards to search service
- Returns facets for UI filtering

**Endpoint**: `POST /catalog/contacts/ingest`
- Converts contacts to documents with `source_type="contact"`
- Stores structured data in `metadata.contact`
- Builds `people` array from phone/email identifiers
- Handles deletions via `DELETE /v1/catalog/documents/{doc_id}`

### Search Service

**`HybridSearchService`**:
- Queries `documents`, `chunks`, `chunk_documents` directly
- Applies SQL filters for timeline, people, attachments, threads
- Combines lexical (full-text) and vector (pgvector) results
- Ranks by recency, relevance, and source trust
- Optional thread context retrieval (surrounding messages)

### Embedding Service

**Worker Loop**:
- Polls `chunks` where `embedding_status='pending'`
- Marks as `processing`, generates vector
- Calls `POST /v1/catalog/embeddings` to store
- Handles failures by marking `embedding_status='failed'`
- Empty chunks marked `embedded` immediately (no vector)

### Collectors

**iMessage Collector**:
- Emits documents with `source_type="imessage"`, `external_id="imessage:{guid}"`
- Builds `people` array from sender/recipients
- Creates thread payload with participants and group metadata
- Detects special message types (stickers, voice messages, replies)
- Maintains version tracker in `~/.haven/imessage_versions.json`

**Local Files Collector**:
- Uploads files via gateway file ingest endpoint
- Gateway creates document with `source_type="localfs"`
- Includes file creation/modification timestamps
- SHA256-based deduplication prevents re-processing

**Contacts Collector**:
- Exports contacts via CNContactStore (macOS)
- Posts batches to gateway contacts endpoint
- Gateway creates documents with `source_type="contact"`
- Incremental sync via `source_change_tokens` table

---

## Performance Considerations

### Index Strategy

**Primary Indexes** (always created):
- Identity lookups: `external_id`, `source_type`, `doc_id`
- Timeline queries: `content_timestamp DESC`
- Relationship traversal: `thread_id`, `parent_doc_id`
- Version filtering: `is_active_version` (partial, where true)
- Status monitoring: `status`, `enrichment_status`, `embedding_status`

**Secondary Indexes** (created based on usage):
- Faceted search: partial indexes on `has_attachments`, `due_date`
- Full-text: GIN indexes on `text` columns
- JSONB: GIN indexes on `people`, `metadata`, `enrichment`
- Vector: IVFFlat index on `embedding_vector` (after population)

**Composite Indexes** (for common combinations):
```sql
-- Timeline for specific source
CREATE INDEX idx_documents_source_timestamp 
    ON documents(source_type, content_timestamp DESC);

-- Active documents by thread
CREATE INDEX idx_documents_thread_active 
    ON documents(thread_id, is_active_version) 
    WHERE is_active_version = true AND thread_id IS NOT NULL;
```

### Partitioning (Future)

For millions of documents, consider partitioning by:
- Time range (monthly/yearly)
- Source type (messages vs files)

```sql
CREATE TABLE documents_2025_10 PARTITION OF documents
FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
```

### Caching

- Thread metadata (participants, titles)
- Recent timeline queries
- File enrichment by SHA256
- Frequently accessed document metadata

### Async Processing

- Document extraction: background jobs
- File enrichment: queue-based processing
- Embedding generation: dedicated worker pool
- Thread updates: trigger-based or batch

---

## Complete DDL Reference

For the complete, executable DDL including all tables, indexes, constraints, triggers, and views, see `schema/init.sql`.

**Key Features**:
- Automatically applied by `postgres` service on first boot
- Drops legacy v1 tables if present
- Creates all v2 tables with constraints
- Sets up indexes for performance
- Defines triggers for `updated_at` timestamps
- Creates convenience views (`active_documents`, `documents_with_files`, `thread_summary`)

**Manual Re-initialization**:
```bash
# From host with psql client
psql postgresql://postgres:postgres@localhost:5432/haven -f schema/init.sql

# From docker container
docker compose exec -T postgres psql -U postgres -d haven -f - < schema/init.sql
```

---

## Summary

Unified Schema v2 provides a flexible, performant foundation for Haven's personal data plane:

- **Universal**: Single model for all content types
- **Scalable**: Optimized indexes and query patterns for millions of documents
- **Flexible**: Type-specific metadata without schema rigidity
- **Robust**: Version history, idempotency, progressive enhancement
- **Search-Ready**: Pre-computed facets, full-text indexes, vector embeddings

The clean slate migration from v1 ensures data quality and enables future enhancements like cross-source relationships, advanced analytics, and multi-user support.

---

**Next Steps**:
1. ✅ Schema implementation complete (`schema/init.sql`)
2. ✅ Models defined (`shared/models_v2.py`)
3. ✅ Services updated (catalog, gateway, search, embedding)
4. ✅ Collectors migrated (imessage, localfs, contacts)
5. 🔄 Performance tuning (vector index, query optimization)
6. 🔄 Documentation consolidation (this document)
7. ⏳ Production deployment and monitoring

**Related Documentation**:
- `documentation/technical_reference.md`: Service architecture
- `documentation/functional_guide.md`: User workflows
- `schema/init.sql`: Executable DDL
- `shared/models_v2.py`: Pydantic models
