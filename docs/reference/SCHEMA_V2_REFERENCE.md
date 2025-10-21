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
7. [Query Patterns](#query-patterns)
8. [Workflow Status](#workflow-status)
9. [Service Integration](#service-integration)
10. [Performance Considerations](#performance-considerations)
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

### 7. ingest_submissions

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
    error_details JSONB,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Key Indexes**:
```sql
CREATE INDEX idx_ingest_submissions_status ON ingest_submissions(status);
CREATE INDEX idx_ingest_submissions_source ON ingest_submissions(source_type, source_id);
```

**Usage**:
- Gateway computes `idempotency_key` from content hash + metadata
- Catalog checks key before inserting document
- Enables safe retries and duplicate detection
- Links submission to resulting document via `result_doc_id`

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
