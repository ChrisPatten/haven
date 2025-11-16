# Haven Data Dictionary

**Last Updated**: January 2025  
**Status**: Comprehensive Reference  
**Scope**: Complete field definitions and mappings across all services

---

## Table of Contents

1. [Overview](#overview)
2. [Database Schema](#database-schema)
3. [API Models](#api-models)
4. [Swift Data Structures](#swift-data-structures)
5. [Field Mappings Between Services](#field-mappings-between-services)
6. [Enrichment Metadata Structures](#enrichment-metadata-structures)
7. [Intent Signal Structures](#intent-signal-structures)
8. [People Normalization Structures](#people-normalization-structures)

---

## Overview

This data dictionary provides comprehensive definitions for all data structures used throughout the Haven platform, including:

- **Database Tables**: Postgres schema with field definitions, constraints, and relationships
- **API Models**: Request/response structures for Gateway, Catalog, Search, and Worker services
- **Swift Structures**: Data models used in Haven.app and hostagent collectors
- **Field Mappings**: How fields transform as data flows between services
- **Metadata Schemas**: Enrichment, intent, and type-specific metadata structures

### Data Flow Overview

```
Haven.app (Swift)
  ↓ CollectorDocument
  ↓ EnrichedDocument
  ↓ GatewaySubmissionClient
Gateway API (:8085)
  ↓ IngestRequestModel
  ↓ DocumentIngestRequest
Catalog API (:8081)
  ↓ documents table (with metadata.attachments)
  ↓ chunks table
  ↓ chunk_documents table
Worker Service
  ↓ EmbeddingSubmitRequest
  ↓ IntentSignalCreateRequest
Search Service (:8080)
  ↓ SearchDocument
  ↓ SearchChunk
```

---

## Database Schema

### Core Tables

#### documents

Primary table for all atomic units of information (messages, files, notes, reminders, etc.).

| Field | Type | Nullable | Description | Constraints |
|-------|------|----------|-------------|-------------|
| `doc_id` | UUID | NO | Primary key, auto-generated | PRIMARY KEY |
| `external_id` | TEXT | NO | Source-specific identifier | UNIQUE(source_type, source_provider, source_account_id, external_id, version_number) |
| `source_type` | TEXT | NO | Source system type | CHECK: imessage, sms, email, email_local, localfs, gdrive, note, reminder, macos_reminders, calendar_event, contact |
| `source_provider` | TEXT | YES | Provider name (e.g., "apple_messages", "gmail") | |
| `source_account_id` | TEXT | YES | Stable account identifier for multi-account sources | |
| `version_number` | INTEGER | NO | Document version (increments on edits) | DEFAULT 1 |
| `previous_version_id` | UUID | YES | Reference to previous version | FK → documents(doc_id) |
| `is_active_version` | BOOLEAN | NO | True for current version | DEFAULT true |
| `superseded_at` | TIMESTAMPTZ | YES | When this version was superseded | |
| `superseded_by_id` | UUID | YES | Reference to newer version | FK → documents(doc_id) |
| `title` | TEXT | YES | Document title/name | |
| `text` | TEXT | NO | Full searchable text content | |
| `text_sha256` | TEXT | NO | SHA256 hash of text for deduplication | |
| `mime_type` | TEXT | YES | MIME type of content | |
| `canonical_uri` | TEXT | YES | Canonical URL/path reference | |
| `content_timestamp` | TIMESTAMPTZ | NO | Primary timestamp (sent, created, modified, due) | |
| `content_timestamp_type` | TEXT | NO | Meaning of timestamp | CHECK: sent, received, modified, created, event_start, event_end, due, completed |
| `people` | JSONB | NO | Array of person identifiers | DEFAULT '[]'::jsonb |
| `thread_id` | UUID | YES | Reference to parent thread | FK → threads(thread_id) |
| `parent_doc_id` | UUID | YES | Reference to parent document | FK → documents(doc_id) |
| `source_doc_ids` | UUID[] | YES | Documents this came from | |
| `related_doc_ids` | UUID[] | YES | Related document references | |
| `has_attachments` | BOOLEAN | NO | True if document has attachments | DEFAULT false |
| `attachment_count` | INTEGER | NO | Number of attachments | DEFAULT 0 |
| `has_location` | BOOLEAN | NO | True if document has location data | DEFAULT false |
| `has_due_date` | BOOLEAN | NO | True if document has due date | DEFAULT false |
| `due_date` | TIMESTAMPTZ | YES | Due date for tasks/reminders | |
| `is_completed` | BOOLEAN | YES | Completion status for tasks | |
| `completed_at` | TIMESTAMPTZ | YES | When task was completed | |
| `metadata` | JSONB | NO | Type-specific structured metadata | DEFAULT '{}'::jsonb |
| `status` | TEXT | NO | Processing workflow status | CHECK: submitted, extracting, extracted, enriching, enriched, indexed, failed |
| `extraction_failed` | BOOLEAN | NO | True if text extraction failed | DEFAULT false |
| `enrichment_failed` | BOOLEAN | NO | True if enrichment failed | DEFAULT false |
| `error_details` | JSONB | YES | Error information if processing failed | |
| `intent` | JSONB | YES | Intent classification data | |
| `relevance_score` | FLOAT | YES | Relevance score (0.0-1.0) for noise filtering | |
| `intent_status` | TEXT | NO | Intent processing status | CHECK: pending, processing, processed, failed, skipped |
| `intent_processing_started_at` | TIMESTAMPTZ | YES | When intent processing started | |
| `intent_processing_completed_at` | TIMESTAMPTZ | YES | When intent processing completed | |
| `intent_processing_error` | TEXT | YES | Error message if intent processing failed | |
| `ingested_at` | TIMESTAMPTZ | NO | When document was ingested | DEFAULT NOW() |
| `created_at` | TIMESTAMPTZ | NO | Record creation timestamp | DEFAULT NOW() |
| `updated_at` | TIMESTAMPTZ | NO | Last update timestamp | DEFAULT NOW() |

**Indexes**:
- `idx_documents_source_type`: source_type
- `idx_documents_external_id`: external_id
- `idx_documents_source_account_id`: source_account_id (partial, WHERE source_account_id IS NOT NULL)
- `idx_documents_active_version`: is_active_version (partial, WHERE is_active_version = true)
- `idx_documents_thread`: thread_id (partial, WHERE thread_id IS NOT NULL)
- `idx_documents_content_timestamp`: content_timestamp DESC
- `idx_documents_status`: status
- `idx_documents_people`: people (GIN)
- `idx_documents_metadata`: metadata (GIN)
- `idx_documents_text_search`: to_tsvector('english', text) (GIN)
- `idx_documents_intent`: intent (GIN)
- `idx_documents_relevance_score`: relevance_score (partial, WHERE relevance_score IS NOT NULL)

#### threads

First-class entity for conversations, chat threads, email threads.

| Field | Type | Nullable | Description | Constraints |
|-------|------|----------|-------------|-------------|
| `thread_id` | UUID | NO | Primary key | PRIMARY KEY |
| `external_id` | TEXT | NO | Source-specific thread identifier | UNIQUE(source_type, source_provider, source_account_id, external_id) |
| `source_type` | TEXT | NO | Source system type | CHECK: imessage, sms, email, slack, whatsapp, signal |
| `source_provider` | TEXT | YES | Provider name | |
| `source_account_id` | TEXT | YES | Stable account identifier for multi-account sources | |
| `title` | TEXT | YES | Thread title/name | |
| `participants` | JSONB | NO | Array of participant identifiers | DEFAULT '[]'::jsonb |
| `thread_type` | TEXT | YES | Thread type classification | |
| `is_group` | BOOLEAN | YES | True for group conversations | |
| `participant_count` | INTEGER | YES | Number of participants | |
| `metadata` | JSONB | NO | Thread-specific metadata | DEFAULT '{}'::jsonb |
| `first_message_at` | TIMESTAMPTZ | YES | Timestamp of first message | |
| `last_message_at` | TIMESTAMPTZ | YES | Timestamp of last message | |
| `created_at` | TIMESTAMPTZ | NO | Record creation timestamp | DEFAULT NOW() |
| `updated_at` | TIMESTAMPTZ | NO | Last update timestamp | DEFAULT NOW() |

**Indexes**:
- `idx_threads_external_id`: external_id
- `idx_threads_source_type`: source_type
- `idx_threads_last_message`: last_message_at DESC
- `idx_threads_participants`: participants (GIN)
- `idx_threads_source_account_id`: source_account_id (partial, WHERE source_account_id IS NOT NULL)

**Note**: Files and document_files tables have been removed. All attachment/file data is now stored in `metadata.attachments` within the documents table.

#### chunks

Text segments for semantic search with embeddings.

| Field | Type | Nullable | Description | Constraints |
|-------|------|----------|-------------|-------------|
| `chunk_id` | UUID | NO | Primary key | PRIMARY KEY |
| `text` | TEXT | NO | Chunk text content | |
| `text_sha256` | TEXT | NO | SHA256 hash of chunk text | |
| `source_ref` | JSONB | YES | Source reference metadata (e.g., text span info) | |
| `embedding_status` | TEXT | NO | Embedding processing status | CHECK: pending, processing, embedded, failed, DEFAULT 'pending' |
| `embedding_model` | TEXT | YES | Model used for embedding | |
| `embedding_vector` | VECTOR(1024) | YES | Embedding vector | |
| `created_at` | TIMESTAMPTZ | NO | Record creation timestamp | DEFAULT NOW() |
| `updated_at` | TIMESTAMPTZ | NO | Last update timestamp | DEFAULT NOW() |

**Indexes**:
- `idx_chunks_embedding_status`: embedding_status
- `idx_chunks_text_search`: to_tsvector('english', text) (GIN)

#### chunk_documents

Junction table linking chunks to documents (many-to-many).

| Field | Type | Nullable | Description | Constraints |
|-------|------|----------|-------------|-------------|
| `chunk_id` | UUID | NO | Chunk reference | FK → chunks(chunk_id), PRIMARY KEY |
| `doc_id` | UUID | NO | Document reference | FK → documents(doc_id), PRIMARY KEY |
| `ordinal` | INTEGER | YES | Order within document | |
| `weight` | DECIMAL(3,2) | YES | Relevance weight (0.0-1.0) | CHECK: weight >= 0.0 AND weight <= 1.0 |
| `created_at` | TIMESTAMPTZ | NO | Record creation timestamp | DEFAULT NOW() |

**Indexes**:
- `idx_chunk_documents_chunk`: chunk_id
- `idx_chunk_documents_doc`: doc_id

#### ingest_submissions

Idempotency tracking for document ingestion.

| Field | Type | Nullable | Description | Constraints |
|-------|------|----------|-------------|-------------|
| `submission_id` | UUID | NO | Primary key | PRIMARY KEY |
| `idempotency_key` | TEXT | NO | Unique idempotency key | UNIQUE |
| `source_type` | TEXT | NO | Source system type | |
| `source_id` | TEXT | NO | Source-specific identifier | |
| `content_sha256` | TEXT | NO | SHA256 hash of content | |
| `status` | TEXT | NO | Submission status | CHECK: submitted, processing, cataloged, completed, failed, DEFAULT 'submitted' |
| `result_doc_id` | UUID | YES | Resulting document ID | FK → documents(doc_id) |
| `batch_id` | UUID | YES | Batch reference | FK → ingest_batches(batch_id) |
| `error_details` | JSONB | YES | Error information if failed | |
| `created_at` | TIMESTAMPTZ | NO | Record creation timestamp | DEFAULT NOW() |
| `updated_at` | TIMESTAMPTZ | NO | Last update timestamp | DEFAULT NOW() |

**Indexes**:
- `idx_ingest_submissions_status`: status
- `idx_ingest_submissions_source`: source_type, source_id
- `idx_ingest_submissions_batch_id`: batch_id

#### ingest_batches

Batch tracking for bulk ingestion operations.

| Field | Type | Nullable | Description | Constraints |
|-------|------|----------|-------------|-------------|
| `batch_id` | UUID | NO | Primary key | PRIMARY KEY |
| `idempotency_key` | TEXT | NO | Unique batch idempotency key | UNIQUE |
| `status` | TEXT | NO | Batch status | CHECK: submitted, processing, completed, partial, failed, DEFAULT 'submitted' |
| `total_count` | INTEGER | NO | Total items in batch | DEFAULT 0 |
| `success_count` | INTEGER | NO | Successful items | DEFAULT 0 |
| `failure_count` | INTEGER | NO | Failed items | DEFAULT 0 |
| `error_details` | JSONB | YES | Batch-level error information | |
| `created_at` | TIMESTAMPTZ | NO | Record creation timestamp | DEFAULT NOW() |
| `updated_at` | TIMESTAMPTZ | NO | Last update timestamp | DEFAULT NOW() |

**Indexes**:
- `idx_ingest_batches_status`: status
- `idx_ingest_batches_created_at`: created_at DESC

### People Normalization Tables

#### people

Canonical person records.

| Field | Type | Nullable | Description | Constraints |
|-------|------|----------|-------------|-------------|
| `person_id` | UUID | NO | Primary key | PRIMARY KEY |
| `display_name` | TEXT | NO | Display name | |
| `given_name` | TEXT | YES | Given/first name | |
| `family_name` | TEXT | YES | Family/last name | |
| `organization` | TEXT | YES | Organization name | |
| `nicknames` | TEXT[] | YES | Array of nicknames | DEFAULT '{}' |
| `notes` | TEXT | YES | Notes about person | |
| `photo_hash` | TEXT | YES | Hash of photo | |
| `source` | TEXT | NO | Source system | |
| `version` | INTEGER | NO | Version number | DEFAULT 1 |
| `deleted` | BOOLEAN | NO | Deletion flag | DEFAULT false |
| `merged_into` | UUID | YES | Reference to merged person | FK → people(person_id) |
| `created_at` | TIMESTAMPTZ | NO | Record creation timestamp | DEFAULT NOW() |
| `updated_at` | TIMESTAMPTZ | NO | Last update timestamp | DEFAULT NOW() |

#### person_identifiers

Normalized phone/email identifiers for people.

| Field | Type | Nullable | Description | Constraints |
|-------|------|----------|-------------|-------------|
| `person_id` | UUID | NO | Person reference | FK → people(person_id), PRIMARY KEY |
| `kind` | identifier_kind | NO | Identifier type | PRIMARY KEY |
| `value_raw` | TEXT | NO | Raw identifier value | PRIMARY KEY |
| `value_canonical` | TEXT | NO | Canonical (normalized) value | PRIMARY KEY |
| `label` | TEXT | YES | Label (home, work, mobile) | |
| `priority` | INTEGER | NO | Priority/order | DEFAULT 100 |
| `verified` | BOOLEAN | NO | Verification status | DEFAULT true |

**Enum**: `identifier_kind`: phone, email, imessage, shortcode, social

#### people_source_map

Maps external contact IDs to person_id.

| Field | Type | Nullable | Description | Constraints |
|-------|------|----------|-------------|-------------|
| `source` | TEXT | NO | Source system | PRIMARY KEY |
| `external_id` | TEXT | NO | External identifier | PRIMARY KEY |
| `person_id` | UUID | NO | Person reference | FK → people(person_id) |

### Intent Signals Tables

#### intent_signals

Intent signals extracted from documents.

| Field | Type | Nullable | Description | Constraints |
|-------|------|----------|-------------|-------------|
| `signal_id` | UUID | NO | Primary key | PRIMARY KEY |
| `artifact_id` | UUID | NO | Document reference | FK → documents(doc_id) |
| `taxonomy_version` | VARCHAR(50) | NO | Intent taxonomy version | |
| `parent_thread_id` | UUID | YES | Parent thread reference | FK → threads(thread_id) |
| `signal_data` | JSONB | NO | IntentSignalData structure | |
| `status` | VARCHAR(20) | NO | User feedback status | CHECK: pending, confirmed, edited, rejected, snoozed, DEFAULT 'pending' |
| `user_feedback` | JSONB | YES | User feedback data | |
| `conflict` | BOOLEAN | NO | Conflict flag | DEFAULT FALSE |
| `conflicting_fields` | TEXT[] | YES | Conflicting field names | |
| `created_at` | TIMESTAMPTZ | NO | Record creation timestamp | DEFAULT NOW() |
| `updated_at` | TIMESTAMPTZ | NO | Last update timestamp | DEFAULT NOW() |

**Indexes**:
- `idx_intent_signals_artifact`: artifact_id
- `idx_intent_signals_thread`: parent_thread_id (partial, WHERE parent_thread_id IS NOT NULL)
- `idx_intent_signals_status`: status
- `idx_intent_signals_data`: signal_data (GIN)

---

## API Models

### Envelope v2 Models (Preferred)

Standardized transport wrapper and payloads used across Haven.app → Gateway → Catalog.

#### Envelope

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | string | YES | Semantic version of envelope + payload schema (e.g., "2.0") |
| `kind` | string | YES | "document" or "person" |
| `source` | object | YES | `{ source_type, source_provider, source_account_id }` |
| `payload` | object | YES | Document or Person payload (see below) |

#### Document (payload)

Transport representation of a `documents` row plus structured metadata.

- Top-level fields: `external_id`, `version_number`, `title`, `text`, `text_sha256`, `mime_type`, `canonical_uri`, `content_timestamp`, `content_timestamp_type`, `people[]`, `thread`, `relationships`, `facets`, `metadata`, `intent`.
- Mappings match the Database Schema section; `metadata.attachments` is the sole owner of OCR/caption/vision/EXIF.

#### Person (payload)

Standardized person/contact object for people normalization.

- Core fields: `external_id`, `display_name`, `given_name`, `family_name`, `organization`, `nicknames[]`, `notes`, `photo_hash`, `change_token`, `version`, `deleted`, `identifiers[]`.
- Identifiers align with `person_identifiers` schema: `{ kind, value_raw, value_canonical, label, priority, verified }`.

#### Endpoints (Gateway)

- `POST /v2/ingest/document` — accepts `Envelope(kind=document)`.
- `POST /v2/ingest/person` — accepts `Envelope(kind=person)`.
- `POST /v2/ingest:batch` — array of envelopes.

Gateway validates envelopes, normalizes timestamps, computes idempotency, and forwards payloads unchanged to Catalog v2.

### Gateway API Models

> Note: This section documents legacy v1 request/response models. Prefer the v2 envelope models above for all new integrations.

#### IngestRequestModel

Request model for document ingestion via Gateway API.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source_type` | string | YES | Source system type |
| `source_id` | string | YES | Source-specific identifier |
| `source_provider` | string | NO | Provider name |
| `title` | string | NO | Document title |
| `canonical_uri` | string | NO | Canonical URL/path |
| `content` | IngestContentModel | YES | Content data |
| `metadata` | object | NO | Type-specific metadata |
| `content_timestamp` | datetime | NO | Primary timestamp |
| `content_timestamp_type` | string | NO | Timestamp type |
| `source_account_id` | string | NO | Account identifier for multi-account sources |
| `people` | DocumentPerson[] | NO | Person identifiers |
| `thread_id` | UUID | NO | Thread reference |
| `thread` | ThreadPayloadModel | NO | Thread payload |

#### IngestContentModel

Content data for ingestion.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `mime_type` | string | NO | MIME type (default: "text/plain") |
| `data` | string | YES | Base64-encoded content |
| `encoding` | string | NO | Encoding type |

#### DocumentPerson

Person identifier in document.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `identifier` | string | YES | Identifier value (phone, email, etc.) |
| `identifier_type` | string | NO | Type (phone, email, etc.) |
| `role` | string | NO | Role (sender, recipient, participant, mentioned) |
| `display_name` | string | NO | Display name |
| `metadata` | object | NO | Additional metadata |

#### ThreadPayloadModel

Thread payload for ingestion.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `external_id` | string | YES | Thread external ID |
| `source_type` | string | NO | Source type |
| `source_provider` | string | NO | Provider name |
| `title` | string | NO | Thread title |
| `participants` | DocumentPerson[] | NO | Participant list |
| `thread_type` | string | NO | Thread type |
| `is_group` | boolean | NO | Group conversation flag |
| `participant_count` | integer | NO | Participant count |
| `metadata` | object | NO | Thread metadata |
| `first_message_at` | datetime | NO | First message timestamp |
| `last_message_at` | datetime | NO | Last message timestamp |

#### IngestSubmissionResponse

Response from document ingestion.

| Field | Type | Description |
|-------|------|-------------|
| `submission_id` | UUID | Submission identifier |
| `doc_id` | UUID | Created document ID |
| `external_id` | string | Document external ID |
| `version_number` | integer | Document version |
| `status` | string | Submission status |
| `thread_id` | UUID | Thread ID (if created) |
| `file_ids` | UUID[] | Associated file IDs |
| `duplicate` | boolean | True if duplicate submission |
| `total_chunks` | integer | Number of chunks created |

### Catalog API Models

#### DocumentIngestRequest

Request model for Catalog API document ingestion.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `idempotency_key` | string | YES | Unique idempotency key |
| `source_type` | string | YES | Source system type |
| `source_provider` | string | NO | Provider name |
| `source_id` | string | YES | Source-specific identifier |
| `content_sha256` | string | YES | SHA256 hash of content |
| `external_id` | string | NO | External identifier |
| `title` | string | NO | Document title |
| `text` | string | YES | Text content |
| `mime_type` | string | NO | MIME type |
| `canonical_uri` | string | NO | Canonical URI |
| `metadata` | object | NO | Type-specific metadata |
| `content_timestamp` | datetime | YES | Primary timestamp |
| `content_timestamp_type` | string | YES | Timestamp type |
| `source_account_id` | string | NO | Account identifier for multi-account sources |
| `people` | PersonPayload[] | NO | Person identifiers |
| `thread_id` | UUID | NO | Thread reference |
| `thread` | ThreadPayload | NO | Thread payload |
| `parent_doc_id` | UUID | NO | Parent document reference |
| `source_doc_ids` | UUID[] | NO | Source document IDs |
| `related_doc_ids` | UUID[] | NO | Related document IDs |
| `has_location` | boolean | NO | Location flag |
| `has_due_date` | boolean | NO | Due date flag |
| `due_date` | datetime | NO | Due date |
| `is_completed` | boolean | NO | Completion status |
| `completed_at` | datetime | NO | Completion timestamp |
| `attachments` | DocumentFileLink[] | NO | File attachments |

#### DocumentFileLink

File attachment link (stored in metadata.attachments).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `index` | integer | YES | Attachment index |
| `kind` | string | YES | Kind (image, pdf, file, other) |
| `role` | string | YES | Role (attachment, inline, thumbnail, related) |
| `mime_type` | string | YES | MIME type |
| `size_bytes` | integer | NO | File size in bytes |
| `source_ref` | AttachmentSourceRef | NO | Source reference (path, message_attachment_id, page) |
| `ocr` | AttachmentOCR | NO | OCR results |
| `caption` | AttachmentCaption | NO | Caption results |
| `vision` | AttachmentVision | NO | Vision results (faces, objects, scene) |
| `exif` | AttachmentEXIF | NO | EXIF metadata |

**Note**: FileDescriptor model is deprecated. Attachments are now stored directly in metadata.attachments with full enrichment data (OCR, caption, vision, exif).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `content_sha256` | string | YES | SHA256 hash |
| `object_key` | string | YES | Storage object key |
| `storage_backend` | string | NO | Storage backend |
| `filename` | string | NO | Filename |
| `mime_type` | string | NO | MIME type |
| `size_bytes` | integer | NO | File size |
| `enrichment_status` | string | NO | Enrichment status |
| `enrichment` | object | NO | Enrichment data |

#### DocumentIngestResponse

Response from Catalog API document ingestion.

| Field | Type | Description |
|-------|------|-------------|
| `submission_id` | UUID | Submission identifier |
| `doc_id` | UUID | Created document ID |
| `external_id` | string | Document external ID |
| `version_number` | integer | Document version |
| `thread_id` | UUID | Thread ID (if created) |
| `file_ids` | UUID[] | Associated file IDs |
| `status` | string | Document status |
| `duplicate` | boolean | True if duplicate |

### Search Service Models

#### SearchDocument

Document model for search service.

| Field | Type | Description |
|-------|------|-------------|
| `doc_id` | UUID | Document ID |
| `external_id` | string | External ID |
| `source_type` | string | Source type |
| `source_provider` | string | Provider name |
| `title` | string | Document title |
| `canonical_uri` | string | Canonical URI |
| `mime_type` | string | MIME type |
| `content_timestamp` | datetime | Primary timestamp |
| `content_timestamp_type` | string | Timestamp type |
| `people` | SearchPerson[] | Person identifiers |
| `has_attachments` | boolean | Has attachments flag |
| `attachment_count` | integer | Attachment count |
| `has_location` | boolean | Has location flag |
| `has_due_date` | boolean | Has due date flag |
| `due_date` | datetime | Due date |
| `is_completed` | boolean | Completion status |
| `metadata` | object | Type-specific metadata |
| `thread_id` | UUID | Thread reference |

#### SearchChunk

Chunk model for search service.

| Field | Type | Description |
|-------|------|-------------|
| `chunk_id` | UUID | Chunk ID |
| `text` | string | Chunk text |
| `ordinal` | integer | Order index |

---

## Swift Data Structures

### CollectorDocument

Base document structure from collectors.

| Field | Type | Description |
|-------|------|-------------|
| `content` | String | Markdown text extracted from source |
| `sourceType` | String | Source system type |
| `externalId` | String | External identifier |
| `metadata` | DocumentMetadata | Document metadata |
| `images` | [ImageAttachment] | Array of extracted images (metadata only, files not retained) |
| `contentType` | DocumentContentType | Content type enum |
| `title` | String? | Document title |
| `canonicalUri` | String? | Canonical URI |

### DocumentMetadata

Document metadata structure.

| Field | Type | Description |
|-------|------|-------------|
| `contentHash` | String | Content hash |
| `mimeType` | String | MIME type |
| `timestamp` | Date? | Primary timestamp |
| `timestampType` | String? | Timestamp type |
| `createdAt` | Date? | Creation timestamp |
| `modifiedAt` | Date? | Modification timestamp |
| `additionalMetadata` | [String: String] | Additional metadata |

### EnrichedDocument

Enriched document with progressive enhancements.

| Field | Type | Description |
|-------|------|-------------|
| `base` | CollectorDocument | Base document |
| `documentEnrichment` | DocumentEnrichment? | Enrichment for primary document |
| `imageEnrichments` | [ImageEnrichment] | One per image, parallel to base.images array |

### DocumentEnrichment

Enrichment for the primary document (text content).

| Field | Type | Description |
|-------|------|-------------|
| `entities` | [Entity]? | Entities extracted from text + OCR text from all images |
| `enrichmentTimestamp` | Date | When enrichment was performed |

### ImageEnrichment

Enrichment for a single image attachment.

| Field | Type | Description |
|-------|------|-------------|
| `ocr` | OCRResult? | OCR results for this image |
| `faces` | FaceDetectionResult? | Face detection results for this image |
| `caption` | String? | Caption for this image (NOT enriched further) |
| `enrichmentTimestamp` | Date | When enrichment was performed |

### EmailDocumentMetadata

Email-specific metadata structure.

| Field | Type | Description |
|-------|------|-------------|
| `messageId` | String? | Email message ID |
| `subject` | String? | Email subject |
| `snippet` | String? | Email snippet |
| `listUnsubscribe` | String? | List unsubscribe header |
| `headers` | [String: String] | Email headers |
| `hasAttachments` | Bool | Has attachments flag |
| `attachmentCount` | Int | Attachment count |
| `contentHash` | String | Content hash |
| `references` | [String] | Email references |
| `inReplyTo` | String? | In-reply-to header |
| `intent` | EmailIntentPayload? | Intent classification |
| `relevanceScore` | Double? | Relevance score |
| `imageCaptions` | [String]? | Image captions |
| `bodyProcessed` | Bool? | Body processed flag |
| `enrichmentEntities` | [String: Any]? | Enrichment entities |

### EmailIntentPayload

Email intent classification payload.

| Field | Type | Description |
|-------|------|-------------|
| `primaryIntent` | String | Primary intent name |
| `confidence` | Double | Confidence score |
| `secondaryIntents` | [String] | Secondary intent names |
| `extractedEntities` | [String: String] | Extracted entities |

---

## Field Mappings Between Services

### Haven.app → Gateway API

| Haven.app Field | Gateway API Field | Transformation |
|----------------|------------------|----------------|
| `CollectorDocument.externalId` | `IngestRequestModel.source_id` | Direct mapping |
| `CollectorDocument.sourceType` | `IngestRequestModel.source_type` | Direct mapping |
| `CollectorDocument.content` | `IngestRequestModel.content.data` | Base64 encoded |
| `CollectorDocument.metadata.mimeType` | `IngestRequestModel.content.mime_type` | Direct mapping |
| `CollectorDocument.metadata.timestamp` | `IngestRequestModel.content_timestamp` | ISO8601 format |
| `CollectorDocument.metadata.timestampType` | `IngestRequestModel.content_timestamp_type` | Direct mapping |
| `CollectorDocument.metadata.timestamps.source_specific.*` | `IngestRequestModel.metadata.timestamps.source_specific.*` | Timestamps stored in metadata.timestamps.source_specific |
| `CollectorDocument.title` | `IngestRequestModel.title` | Direct mapping |
| `CollectorDocument.canonicalUri` | `IngestRequestModel.canonical_uri` | Direct mapping |
| `EnrichedDocument.base.images` | Not sent | Image files NOT sent to gateway (business rule) |
| `EnrichedDocument.imageEnrichments` | `IngestRequestModel.metadata.enrichment.images` | Embedded as metadata |
| `EnrichedDocument.documentEnrichment.entities` | `IngestRequestModel.metadata.enrichment.entities` | Embedded as metadata |

### Gateway API → Catalog API

| Gateway API Field | Catalog API Field | Transformation |
|------------------|------------------|----------------|
| `IngestRequestModel.source_id` | `DocumentIngestRequest.source_id` | Direct mapping |
| `IngestRequestModel.source_type` | `DocumentIngestRequest.source_type` | Direct mapping |
| `IngestRequestModel.content.data` | `DocumentIngestRequest.text` | Base64 decoded |
| `IngestRequestModel.content.mime_type` | `DocumentIngestRequest.mime_type` | Direct mapping |
| `IngestRequestModel.content_timestamp` | `DocumentIngestRequest.content_timestamp` | Direct mapping |
| `IngestRequestModel.content_timestamp_type` | `DocumentIngestRequest.content_timestamp_type` | Normalized to lowercase |
| `IngestRequestModel.people` | `DocumentIngestRequest.people` | Direct mapping |
| `IngestRequestModel.thread` | `DocumentIngestRequest.thread` | Direct mapping |
| `IngestRequestModel.metadata` | `DocumentIngestRequest.metadata` | Direct mapping |
| Generated `idempotency_key` | `DocumentIngestRequest.idempotency_key` | Generated from source_id + content_sha256 |
| Computed `content_sha256` | `DocumentIngestRequest.content_sha256` | SHA256 of text |

### Catalog API → Database

| Catalog API Field | Database Field | Transformation |
|------------------|----------------|----------------|
| `DocumentIngestRequest.source_id` | `documents.external_id` | Direct mapping |
| `DocumentIngestRequest.source_type` | `documents.source_type` | Direct mapping |
| `DocumentIngestRequest.text` | `documents.text` | Direct mapping |
| `DocumentIngestRequest.content_sha256` | `documents.text_sha256` | Direct mapping |
| `DocumentIngestRequest.content_timestamp` | `documents.content_timestamp` | Direct mapping |
| `DocumentIngestRequest.content_timestamp_type` | `documents.content_timestamp_type` | Normalized |
| `DocumentIngestRequest.people` | `documents.people` | JSONB array |
| `DocumentIngestRequest.thread` | `threads` table | Creates thread if not exists |
| `DocumentIngestRequest.thread.external_id` | `threads.external_id` | Direct mapping |
| `DocumentIngestRequest.thread.source_account_id` | `threads.source_account_id` | Direct mapping |
| `DocumentIngestRequest.source_account_id` | `documents.source_account_id` | Direct mapping |
| `DocumentIngestRequest.attachments[]` | `documents.metadata.attachments[]` | Stored in metadata.attachments array |
| `DocumentIngestRequest.attachments[].index` | `metadata.attachments[].index` | Direct mapping |
| `DocumentIngestRequest.attachments[].kind` | `metadata.attachments[].kind` | Direct mapping |
| `DocumentIngestRequest.attachments[].ocr` | `metadata.attachments[].ocr` | Direct mapping |
| `DocumentIngestRequest.attachments[].caption` | `metadata.attachments[].caption` | Direct mapping |
| `DocumentIngestRequest.attachments[].vision` | `metadata.attachments[].vision` | Direct mapping |
| `DocumentIngestRequest.attachments[].exif` | `metadata.attachments[].exif` | Direct mapping |

### Database → Search Service

| Database Field | Search Service Field | Transformation |
|---------------|---------------------|----------------|
| `documents.doc_id` | `SearchDocument.doc_id` | Direct mapping |
| `documents.external_id` | `SearchDocument.external_id` | Direct mapping |
| `documents.source_type` | `SearchDocument.source_type` | Direct mapping |
| `documents.title` | `SearchDocument.title` | Direct mapping |
| `documents.text` | `SearchDocument.raw_text` | Direct mapping |
| `documents.content_timestamp` | `SearchDocument.content_timestamp` | Direct mapping |
| `documents.people` | `SearchDocument.people` | Converted to SearchPerson[] |
| `chunks.chunk_id` | `SearchChunk.chunk_id` | Direct mapping |
| `chunks.text` | `SearchChunk.text` | Direct mapping |
| `chunk_documents.ordinal` | Order within document | Ordinal stored in chunk_documents, not chunks |

---

## Metadata Structure

The `documents.metadata` JSONB field has a fixed set of top-level keys to ensure consistent structure across all document types.

### Top-Level Metadata Keys

```json
{
  "ingested_at": "<ISO-8601 UTC timestamp>",
  "timestamps": { ... },
  "attachments": [ ... ],
  "source": { ... },
  "type": { ... },
  "enrichment": { ... },
  "extraction": { ... }
}
```

| Key | Type | Description |
|-----|------|-------------|
| `ingested_at` | string | ISO-8601 UTC timestamp when Catalog stored this document |
| `timestamps` | object | Timestamp structure (see Timestamps section) |
| `attachments` | array | Full description of attached images/files (see Attachments section) |
| `source` | object | Raw source-system oriented details |
| `type` | object | Normalized, type-specific semantics |
| `enrichment` | object | ML-derived enrichment over document text |
| `extraction` | object | Ingestion and parsing diagnostics |

### metadata.timestamps

The timestamps structure mirrors the document-level `content_timestamp` and `content_timestamp_type` fields.

```json
{
  "timestamps": {
    "primary": {
      "value": "<ISO-8601 UTC timestamp>",
      "type": "<enum string matching content_timestamp_type>"
    },
    "source_specific": {
      "<source_field_name>": "<ISO-8601 or raw string>",
      "...": "..."
    }
  }
}
```

**Rules**:
- `primary.value` must equal `content_timestamp`
- `primary.type` must equal `content_timestamp_type`
- `source_specific` keys are source-defined (e.g., `sent_at`, `received_at`, `internaldate`, `header_date`, `fs_created`, `fs_modified`, `exif_taken_at`)

### metadata.attachments

Attachments represent any file/image that is part of the document. All OCR, caption, face detection, and EXIF information is stored here.

See the [Attachments section](#documentfilelink) for the full schema.

**Note**: There is no separate `files` table; all file-level enrichment is embedded in `metadata.attachments`.

### metadata.source

Contains raw source-system details for debugging or advanced features.

**Examples**:
- **iMessage**: `{ "imessage": { "chat_guid": "...", "handle_id": 42, "service": "iMessage", "row_id": 123456 } }`
- **Email**: `{ "email": { "folder": "INBOX", "uid": 12345, "raw_flags": [...], "header_map": {...} } }`

### metadata.type

Exposes normalized semantics by document kind.

**Base structure**:
```json
{
  "type": {
    "kind": "email"  // or imessage | sms | note | reminder | calendar_event | file | ...
  }
}
```

**Type-specific examples**:
- **Email**: `{ "kind": "email", "email": { "subject": "...", "is_outbound": true, "in_reply_to_message_id": "..." } }`
- **iMessage**: `{ "kind": "imessage", "imessage": { "direction": "outgoing", "is_group": true } }`
- **Reminder**: `{ "kind": "reminder", "reminder": { "status": "open", "priority": 1, "due_date": "..." } }`

### metadata.enrichment

ML-derived document-level signals over text.

```json
{
  "enrichment": {
    "entities": [
      { "text": "Acme HVAC", "type": "organization", "offset": 10, "length": 9 }
    ],
    "classification": {
      "categories": [
        { "label": "home_maintenance", "confidence": 0.92 }
      ]
    }
  }
}
```

### metadata.extraction

Tracks how the document was ingested and processed (diagnostic information).

```json
{
  "extraction": {
    "collector_name": "imessage",
    "collector_version": "1.3.0",
    "hostagent_modules": ["ocr", "entities", "faces"],
    "warnings": [
      { "code": "ATTACHMENT_OCR_FAILED", "attachment_index": 2 }
    ]
  }
}
```

---

## Enrichment Metadata Structures

### Document Metadata Enrichment

Stored in `documents.metadata.enrichment` JSONB field.

```json
{
  "enrichment": {
    "entities": [
      {
        "type": "PERSON",
        "text": "John Doe",
        "start": 0,
        "end": 8,
        "confidence": 0.95
      }
    ],
    "captions": [
      "[Image: photo.jpg | A group of people | Extracted text from OCR]"
    ],
    "images": [
      {
        "filename": "photo.jpg",
        "caption": "A group of people standing in front of a building",
        "ocr": "Extracted text from image",
        "faces": [
          {
            "x": 0.1,
            "y": 0.2,
            "w": 0.15,
            "h": 0.2,
            "confidence": 0.92
          }
        ]
      }
    ]
  }
}
```

**Field Definitions**:

| Field | Type | Description |
|-------|------|-------------|
| `enrichment.entities` | array | Named entity recognition results |
| `enrichment.entities[].type` | string | Entity type (PERSON, ORGANIZATION, LOCATION, DATE, etc.) |
| `enrichment.entities[].text` | string | Entity text |
| `enrichment.entities[].start` | integer | Start offset in text |
| `enrichment.entities[].end` | integer | End offset in text |
| `enrichment.entities[].confidence` | float | Confidence score (0.0-1.0) |
| `enrichment.captions` | array | Image caption placeholders in text |
| `enrichment.images` | array | Image enrichment metadata |
| `enrichment.images[].filename` | string | Image filename |
| `enrichment.images[].caption` | string | Image caption |
| `enrichment.images[].ocr` | string | OCR extracted text |
| `enrichment.images[].faces` | array | Face detection results |
| `enrichment.images[].faces[].x` | float | Face bounding box x (normalized 0-1) |
| `enrichment.images[].faces[].y` | float | Face bounding box y (normalized 0-1) |
| `enrichment.images[].faces[].w` | float | Face bounding box width (normalized 0-1) |
| `enrichment.images[].faces[].h` | float | Face bounding box height (normalized 0-1) |
| `enrichment.images[].faces[].confidence` | float | Face detection confidence (0.0-1.0) |

### File Enrichment

Stored in `documents.metadata.attachments[].ocr`, `metadata.attachments[].caption`, `metadata.attachments[].vision`, `metadata.attachments[].exif` JSONB fields.

```json
{
  "ocr": {
    "text": "Extracted text from image",
    "confidence": 0.95,
    "language": "en",
    "boxes": [
      {
        "text": "specific text region",
        "x": 0.005,
        "y": 0.861,
        "w": 0.854,
        "h": 0.065,
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
      {
        "x": 0.1,
        "y": 0.2,
        "w": 0.15,
        "h": 0.2,
        "confidence": 0.92
      }
    ],
    "objects": [
      {
        "label": "person",
        "confidence": 0.95,
        "count": 3
      }
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

**Field Definitions**:

| Field | Type | Description |
|-------|------|-------------|
| `ocr.text` | string | Full OCR extracted text |
| `ocr.confidence` | float | Overall OCR confidence (0.0-1.0) |
| `ocr.language` | string | Detected language code |
| `ocr.boxes` | array | Text region bounding boxes |
| `ocr.boxes[].text` | string | Text in this region |
| `ocr.boxes[].x` | float | X coordinate (normalized 0-1) |
| `ocr.boxes[].y` | float | Y coordinate (normalized 0-1) |
| `ocr.boxes[].w` | float | Width (normalized 0-1) |
| `ocr.boxes[].h` | float | Height (normalized 0-1) |
| `ocr.boxes[].confidence` | float | Region confidence (0.0-1.0) |
| `ocr.entities` | object | Extracted entities from OCR text |
| `caption.text` | string | Image caption |
| `caption.model` | string | Model used for captioning |
| `caption.confidence` | float | Caption confidence (0.0-1.0) |
| `caption.generated_at` | string | ISO8601 timestamp |
| `vision.faces` | array | Face detection results |
| `vision.objects` | array | Object detection results |
| `vision.scene` | string | Scene classification |
| `vision.colors.dominant` | array | Dominant color hex codes |
| `exif.camera` | string | Camera model |
| `exif.taken_at` | string | ISO8601 timestamp |
| `exif.location.latitude` | float | GPS latitude |
| `exif.location.longitude` | float | GPS longitude |
| `exif.width` | integer | Image width in pixels |
| `exif.height` | integer | Image height in pixels |

### Type-Specific Metadata

#### iMessage/SMS Metadata

Stored in `documents.metadata` JSONB field.

```json
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

**Field Definitions**:

| Field | Type | Description |
|-------|------|-------------|
| `message.guid` | string | Source-specific message ID (matches external_id suffix) |
| `message.row_id` | integer | Original database row ID for lookups |
| `message.sent_at` | string | ISO8601 sent timestamp |
| `message.received_at` | string | ISO8601 received timestamp |
| `message.sender` | string | Sender identifier (phone/email) |
| `message.is_from_me` | boolean | True if sent by user |
| `message.service` | string | Service type (iMessage, SMS) |
| `message.direction` | string | Message direction (sent, received) |
| `message.read` | boolean | Read status |
| `reply_to_guid` | string | Parent message GUID for thread reconstruction |
| `associated_message_type` | integer | 1000 = sticker, 2000 = reaction |
| `associated_message_guid` | string | Parent message for stickers/reactions |
| `is_audio_message` | boolean | True for voice messages |
| `expire_state` | integer | Voice message expiration (1=expired, 3=saved) |
| `expressive_send_style_id` | integer | Message effects ID (Bloom, Echo, Confetti, etc.) |

#### Email Metadata

Stored in `documents.metadata` JSONB field.

```json
{
  "source": "email_local",
  "message_id": "message-id@example.com",
  "subject": "Email Subject",
  "snippet": "Email snippet text",
  "list_unsubscribe": "mailto:unsubscribe@example.com",
  "headers": {
    "From": "sender@example.com",
    "To": "recipient@example.com",
    "Date": "Mon, 1 Jan 2024 12:00:00 +0000"
  },
  "has_attachments": true,
  "attachment_count": 2,
  "content_hash": "sha256-hash",
  "references": ["ref1@example.com", "ref2@example.com"],
  "in_reply_to": "parent@example.com",
  "intent": {
    "primary_intent": "bill",
    "confidence": 0.85,
    "secondary_intents": ["receipt"],
    "extracted_entities": {
      "amount": "$123.45",
      "merchant": "Example Store"
    }
  },
  "relevance_score": 0.92,
  "image_captions": ["Caption 1", "Caption 2"],
  "body_processed": true,
  "enrichment_entities": {
    "PERSON": ["John Doe"],
    "ORGANIZATION": ["Example Corp"]
  }
}
```

**Field Definitions**:

| Field | Type | Description |
|-------|------|-------------|
| `message_id` | string | Email message ID header |
| `subject` | string | Email subject line |
| `snippet` | string | Email snippet/preview |
| `list_unsubscribe` | string | List unsubscribe header |
| `headers` | object | Email headers (key-value pairs) |
| `has_attachments` | boolean | Has attachments flag |
| `attachment_count` | integer | Number of attachments |
| `content_hash` | string | Content hash |
| `references` | array | Email references header |
| `in_reply_to` | string | In-reply-to header |
| `intent.primary_intent` | string | Primary intent (bill, receipt, appointment, etc.) |
| `intent.confidence` | float | Intent confidence (0.0-1.0) |
| `intent.secondary_intents` | array | Secondary intent names |
| `intent.extracted_entities` | object | Extracted entities from intent processing |
| `relevance_score` | float | Relevance score (0.0-1.0) |
| `image_captions` | array | Image captions |
| `body_processed` | boolean | Body processed flag |
| `enrichment_entities` | object | NER entities by type |

---

## Intent Signal Structures

### IntentSignalData

Complete intent signal schema stored in `intent_signals.signal_data` JSONB field.

```json
{
  "signal_id": "uuid",
  "artifact_id": "doc-uuid",
  "taxonomy_version": "1.0.0",
  "intents": [
    {
      "name": "bill",
      "confidence": 0.92,
      "slots": {
        "amount": "$123.45",
        "merchant": "Example Store",
        "due_date": "2024-12-31"
      },
      "missing_slots": ["account_number"],
      "follow_up_needed": true,
      "follow_up_reason": "Missing account number",
      "evidence": {
        "text_spans": [
          {
            "start_offset": 0,
            "end_offset": 50,
            "preview": "Your bill for $123.45 is due..."
          }
        ],
        "layout_refs": [
          {
            "attachment_id": "file-uuid",
            "page": 1,
            "block_id": "block-1",
            "line_id": "line-1"
          }
        ],
        "entity_refs": [
          {
            "type": "MONEY",
            "index": 0
          }
        ]
      }
    }
  ],
  "global_confidence": 0.92,
  "processing_notes": ["NER completed", "Slot filling completed"],
  "processing_timestamps": {
    "ner_started_at": "2024-01-01T12:00:00Z",
    "ner_completed_at": "2024-01-01T12:00:05Z",
    "received_at": "2024-01-01T12:00:00Z",
    "intent_started_at": "2024-01-01T12:00:05Z",
    "intent_completed_at": "2024-01-01T12:00:10Z",
    "emitted_at": "2024-01-01T12:00:10Z"
  },
  "provenance": {
    "ner_version": "1.0.0",
    "ner_framework": "spacy",
    "classifier_version": "1.0.0",
    "slot_filler_version": "1.0.0",
    "config_snapshot_id": "config-123",
    "processing_location": "server"
  },
  "parent_thread_id": "thread-uuid",
  "conflict": false,
  "conflicting_fields": []
}
```

**Field Definitions**:

| Field | Type | Description |
|-------|------|-------------|
| `signal_id` | string | Unique signal identifier |
| `artifact_id` | string | Document ID that generated this signal |
| `taxonomy_version` | string | Intent taxonomy version |
| `intents` | array | List of detected intents |
| `intents[].name` | string | Intent name (bill, receipt, appointment, etc.) |
| `intents[].confidence` | float | Intent confidence (0.0-1.0) |
| `intents[].slots` | object | Filled slot values |
| `intents[].missing_slots` | array | Required slots that are missing |
| `intents[].follow_up_needed` | boolean | True if follow-up needed |
| `intents[].follow_up_reason` | string | Reason for follow-up |
| `intents[].evidence` | object | Evidence supporting intent |
| `intents[].evidence.text_spans` | array | Text span evidence |
| `intents[].evidence.text_spans[].start_offset` | integer | Start character offset |
| `intents[].evidence.text_spans[].end_offset` | integer | End character offset |
| `intents[].evidence.text_spans[].preview` | string | Text preview |
| `intents[].evidence.layout_refs` | array | Layout/OCR evidence |
| `intents[].evidence.layout_refs[].attachment_id` | string | Attachment file ID |
| `intents[].evidence.layout_refs[].page` | integer | Page number |
| `intents[].evidence.layout_refs[].block_id` | string | Block identifier |
| `intents[].evidence.layout_refs[].line_id` | string | Line identifier |
| `intents[].evidence.entity_refs` | array | Entity references |
| `intents[].evidence.entity_refs[].type` | string | Entity type |
| `intents[].evidence.entity_refs[].index` | integer | Entity index |
| `global_confidence` | float | Overall confidence score |
| `processing_notes` | array | Processing notes |
| `processing_timestamps` | object | Timing information |
| `processing_timestamps.ner_started_at` | string | NER start timestamp |
| `processing_timestamps.ner_completed_at` | string | NER completion timestamp |
| `processing_timestamps.received_at` | string | When signal was received |
| `processing_timestamps.intent_started_at` | string | Intent processing start |
| `processing_timestamps.intent_completed_at` | string | Intent processing completion |
| `processing_timestamps.emitted_at` | string | When signal was emitted |
| `provenance` | object | Processing provenance |
| `provenance.ner_version` | string | NER model version |
| `provenance.ner_framework` | string | NER framework (spacy, etc.) |
| `provenance.classifier_version` | string | Intent classifier version |
| `provenance.slot_filler_version` | string | Slot filler version |
| `provenance.config_snapshot_id` | string | Config snapshot ID |
| `provenance.processing_location` | string | Processing location (client, server, hybrid) |
| `parent_thread_id` | string | Parent thread ID |
| `conflict` | boolean | True if conflicts with other signals |
| `conflicting_fields` | array | Conflicting field names |

### Document Intent Field

Stored in `documents.intent` JSONB field (simplified intent classification).

```json
{
  "primary_intent": "bill",
  "confidence": 0.85,
  "secondary_intents": ["receipt"],
  "extracted_entities": {
    "amount": "$123.45",
    "merchant": "Example Store"
  }
}
```

**Field Definitions**:

| Field | Type | Description |
|-------|------|-------------|
| `primary_intent` | string | Primary intent name |
| `confidence` | float | Confidence score (0.0-1.0) |
| `secondary_intents` | array | Secondary intent names |
| `extracted_entities` | object | Extracted entities from intent processing |

---

## People Normalization Structures

### Person Payload

Person identifier payload used in API requests.

| Field | Type | Description |
|-------|------|-------------|
| `identifier` | string | Identifier value (phone, email, etc.) |
| `identifier_type` | string | Type (phone, email, imessage, shortcode, social) |
| `role` | string | Role (sender, recipient, participant, mentioned, contact) |
| `display_name` | string | Display name |
| `metadata` | object | Additional metadata |

### People JSONB Array

Stored in `documents.people` JSONB field.

```json
[
  {
    "identifier": "+15551234567",
    "identifier_type": "phone",
    "role": "sender",
    "display_name": "John Doe",
    "metadata": {}
  },
  {
    "identifier": "user@example.com",
    "identifier_type": "email",
    "role": "recipient",
    "display_name": "Jane Smith",
    "metadata": {}
  }
]
```

### Contact Payload

Contact ingestion payload for people normalization.

| Field | Type | Description |
|-------|------|-------------|
| `external_id` | string | External contact ID |
| `display_name` | string | Display name |
| `given_name` | string | Given/first name |
| `family_name` | string | Family/last name |
| `organization` | string | Organization name |
| `nicknames` | array | Array of nicknames |
| `notes` | string | Notes |
| `photo_hash` | string | Photo hash |
| `emails` | ContactValue[] | Email addresses |
| `phones` | ContactValue[] | Phone numbers |
| `addresses` | ContactAddress[] | Addresses |
| `urls` | ContactUrl[] | URLs |
| `change_token` | string | Change token for incremental sync |
| `version` | integer | Version number |
| `deleted` | boolean | Deletion flag |

### ContactValue

Contact identifier value.

| Field | Type | Description |
|-------|------|-------------|
| `value` | string | Canonical value |
| `value_raw` | string | Raw value |
| `label` | string | Label (home, work, mobile) |
| `priority` | integer | Priority/order (default: 100) |
| `verified` | boolean | Verification status (default: true) |

### ContactAddress

Contact address.

| Field | Type | Description |
|-------|------|-------------|
| `label` | string | Label (home, work) |
| `street` | string | Street address |
| `city` | string | City |
| `region` | string | State/region |
| `postal_code` | string | Postal/ZIP code |
| `country` | string | Country |

### ContactUrl

Contact URL.

| Field | Type | Description |
|-------|------|-------------|
| `label` | string | Label (homepage, blog, etc.) |
| `url` | string | URL value |

---

## Summary

This data dictionary provides comprehensive definitions for all data structures used throughout the Haven platform. Key points:

1. **Universal Document Model**: All content (messages, files, notes, reminders) stored in unified `documents` table
2. **Deduplication**: Files deduplicated by SHA256, documents versioned with full history
3. **Progressive Enhancement**: Support for partial data with clear status tracking
4. **Enrichment**: OCR, face detection, entity extraction, and captioning stored in metadata
5. **Intent Signals**: Structured intent classification with evidence and provenance
6. **People Normalization**: Canonical person records with identifier mapping

For additional details, see:
- [Schema V2 Reference](./SCHEMA_V2_REFERENCE.md)
- [Gateway API Reference](./api/gateway.md)
- [Architecture Overview](../architecture/overview.md)

