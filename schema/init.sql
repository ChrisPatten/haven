-- Haven Unified Schema v2.0 Initialization
-- This script resets the core catalog schema to match documentation/SCHEMA_unified_v2_ddl.sql.
-- It is safe to rerun; existing unified objects will be replaced to ensure consistency.

-- ============================================================================
-- EXTENSIONS
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- ============================================================================
-- LEGACY CLEANUP (drop obsolete objects from v1 schema)
-- ============================================================================
DROP VIEW IF EXISTS thread_summary;
DROP VIEW IF EXISTS documents_with_files;
DROP VIEW IF EXISTS active_documents;

DROP TABLE IF EXISTS search_deletes CASCADE;
DROP TABLE IF EXISTS search_ingest_log CASCADE;
DROP TABLE IF EXISTS search_chunks CASCADE;
DROP TABLE IF EXISTS search_documents CASCADE;
DROP TABLE IF EXISTS delete_jobs CASCADE;
DROP TABLE IF EXISTS embed_jobs CASCADE;
DROP TABLE IF EXISTS attachments CASCADE;
DROP TABLE IF EXISTS messages CASCADE;
DROP TABLE IF EXISTS person_urls CASCADE;
DROP TABLE IF EXISTS person_addresses CASCADE;
DROP TABLE IF EXISTS person_identifiers CASCADE;
DROP TABLE IF EXISTS people_source_map CASCADE;
DROP TABLE IF EXISTS people_conflict_log CASCADE;
DROP TABLE IF EXISTS people CASCADE;
DROP TABLE IF EXISTS source_change_tokens CASCADE;

DROP TYPE IF EXISTS identifier_kind;

-- Drop unified tables so they can be recreated cleanly
DROP TABLE IF EXISTS chunk_documents CASCADE;
DROP TABLE IF EXISTS chunks CASCADE;
DROP TABLE IF EXISTS document_files CASCADE;
DROP TABLE IF EXISTS files CASCADE;
DROP TABLE IF EXISTS documents CASCADE;
DROP TABLE IF EXISTS threads CASCADE;
DROP TABLE IF EXISTS ingest_submissions CASCADE;

-- ============================================================================
-- CORE TABLES
-- ============================================================================

-- Threads
CREATE TABLE threads (
    thread_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    external_id TEXT UNIQUE NOT NULL,
    source_type TEXT NOT NULL,
    source_provider TEXT,
    title TEXT,
    participants JSONB NOT NULL DEFAULT '[]'::jsonb,
    thread_type TEXT,
    is_group BOOLEAN,
    participant_count INTEGER,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    first_message_at TIMESTAMPTZ,
    last_message_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT threads_valid_source_type CHECK (
        source_type IN ('imessage', 'sms', 'email', 'slack', 'whatsapp', 'signal')
    )
);

-- Documents
CREATE TABLE documents (
    doc_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    external_id TEXT NOT NULL,
    source_type TEXT NOT NULL,
    source_provider TEXT,
    version_number INTEGER NOT NULL DEFAULT 1,
    previous_version_id UUID REFERENCES documents(doc_id),
    is_active_version BOOLEAN NOT NULL DEFAULT true,
    superseded_at TIMESTAMPTZ,
    superseded_by_id UUID REFERENCES documents(doc_id),
    title TEXT,
    text TEXT NOT NULL,
    text_sha256 TEXT NOT NULL,
    mime_type TEXT,
    canonical_uri TEXT,
    content_timestamp TIMESTAMPTZ NOT NULL,
    content_timestamp_type TEXT NOT NULL,
    content_created_at TIMESTAMPTZ,
    content_modified_at TIMESTAMPTZ,
    people JSONB NOT NULL DEFAULT '[]'::jsonb,
    thread_id UUID REFERENCES threads(thread_id),
    parent_doc_id UUID REFERENCES documents(doc_id),
    source_doc_ids UUID[],
    related_doc_ids UUID[],
    has_attachments BOOLEAN NOT NULL DEFAULT false,
    attachment_count INTEGER NOT NULL DEFAULT 0,
    has_location BOOLEAN NOT NULL DEFAULT false,
    has_due_date BOOLEAN NOT NULL DEFAULT false,
    due_date TIMESTAMPTZ,
    is_completed BOOLEAN,
    completed_at TIMESTAMPTZ,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL DEFAULT 'submitted',
    extraction_failed BOOLEAN NOT NULL DEFAULT false,
    enrichment_failed BOOLEAN NOT NULL DEFAULT false,
    error_details JSONB,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT documents_external_id_version_key UNIQUE (external_id, version_number),
    CONSTRAINT documents_valid_timestamp_type CHECK (
        content_timestamp_type IN ('sent', 'received', 'modified', 'created', 'event_start', 'event_end', 'due', 'completed')
    ),
    CONSTRAINT documents_valid_status CHECK (
        status IN ('submitted', 'extracting', 'extracted', 'enriching', 'enriched', 'indexed', 'failed')
    ),
    CONSTRAINT documents_valid_source_type CHECK (
        source_type IN ('imessage', 'sms', 'email', 'email_local', 'localfs', 'gdrive', 'note', 'reminder', 'calendar_event', 'contact')
    ),
    intent JSONB DEFAULT NULL,
    relevance_score FLOAT DEFAULT NULL
);

-- Column comments for email collector fields
COMMENT ON COLUMN documents.intent IS 'JSONB field for email intent classification: bills, receipts, confirmations, appointments, action_requests, notifications, etc.';
COMMENT ON COLUMN documents.relevance_score IS 'Float score (0.0-1.0) for noise filtering; higher scores indicate more relevant/actionable content';

-- Files
CREATE TABLE files (
    file_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    content_sha256 TEXT UNIQUE NOT NULL,
    object_key TEXT NOT NULL,
    storage_backend TEXT NOT NULL DEFAULT 'minio',
    filename TEXT,
    mime_type TEXT,
    size_bytes BIGINT,
    enrichment_status TEXT NOT NULL DEFAULT 'pending',
    enrichment JSONB,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_enriched_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT files_valid_enrichment_status CHECK (
        enrichment_status IN ('pending', 'processing', 'enriched', 'failed', 'skipped')
    ),
    CONSTRAINT files_valid_storage_backend CHECK (
        storage_backend IN ('minio', 's3', 'local', 'gdrive')
    )
);

-- Document ↔ File junction
CREATE TABLE document_files (
    doc_id UUID NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    file_id UUID NOT NULL REFERENCES files(file_id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    attachment_index INTEGER,
    filename TEXT,
    caption TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (doc_id, file_id, role),
    CONSTRAINT document_files_valid_role CHECK (
        role IN ('attachment', 'extracted_from', 'thumbnail', 'preview', 'related')
    )
);

-- Chunks
CREATE TABLE chunks (
    chunk_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    text TEXT NOT NULL,
    text_sha256 TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    source_ref JSONB,
    embedding_status TEXT NOT NULL DEFAULT 'pending',
    embedding_model TEXT,
    embedding_vector VECTOR(1024),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chunks_valid_embedding_status CHECK (
        embedding_status IN ('pending', 'processing', 'embedded', 'failed')
    )
);

-- Chunk ↔ Document junction
CREATE TABLE chunk_documents (
    chunk_id UUID NOT NULL REFERENCES chunks(chunk_id) ON DELETE CASCADE,
    doc_id UUID NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    ordinal INTEGER,
    weight DECIMAL(3,2),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (chunk_id, doc_id),
    CONSTRAINT chunk_documents_valid_weight CHECK (
        weight IS NULL OR (weight >= 0.0 AND weight <= 1.0)
    )
);

-- Ingest submissions
CREATE TABLE ingest_batches (
    batch_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    idempotency_key TEXT UNIQUE NOT NULL,
    status TEXT NOT NULL DEFAULT 'submitted',
    total_count INTEGER NOT NULL DEFAULT 0,
    success_count INTEGER NOT NULL DEFAULT 0,
    failure_count INTEGER NOT NULL DEFAULT 0,
    error_details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ingest_batches_valid_status CHECK (
        status IN ('submitted', 'processing', 'completed', 'partial', 'failed')
    )
);

CREATE TABLE ingest_submissions (
    submission_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    idempotency_key TEXT UNIQUE NOT NULL,
    source_type TEXT NOT NULL,
    source_id TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'submitted',
    result_doc_id UUID REFERENCES documents(doc_id),
    batch_id UUID REFERENCES ingest_batches(batch_id),
    error_details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ingest_submissions_valid_status CHECK (
        status IN ('submitted', 'processing', 'cataloged', 'completed', 'failed')
    )
);

-- Contact / source change token tracking
CREATE TABLE source_change_tokens (
    source TEXT NOT NULL,
    device_id TEXT NOT NULL,
    change_token_b64 TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source, device_id)
);

-- ============================================================================
-- PEOPLE NORMALIZATION TABLES
-- ============================================================================

-- Identifier kind enum type
CREATE TYPE identifier_kind AS ENUM ('phone', 'email', 'imessage', 'shortcode', 'social');

-- People (canonical person records)
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
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Person identifiers (normalized phone/email identifiers)
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

-- People source map (maps external contact IDs to person_id)
CREATE TABLE people_source_map (
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    CONSTRAINT people_source_map_unique UNIQUE (source, external_id)
);

-- Person addresses (contact addresses)
CREATE TABLE person_addresses (
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    street TEXT,
    city TEXT,
    region TEXT,
    postal_code TEXT,
    country TEXT,
    CONSTRAINT person_addresses_unique UNIQUE (person_id, label)
);

-- Person URLs (contact URLs)
CREATE TABLE person_urls (
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    url TEXT NOT NULL,
    CONSTRAINT person_urls_unique UNIQUE (person_id, label)
);

-- People conflict log (identifier conflict tracking)
CREATE TABLE people_conflict_log (
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    kind identifier_kind NOT NULL,
    value_canonical TEXT NOT NULL,
    existing_person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    incoming_person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Document ↔ People junction table (links documents to normalized person entities)
CREATE TABLE document_people (
    doc_id UUID NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    PRIMARY KEY (doc_id, person_id),
    CONSTRAINT document_people_valid_role CHECK (
        role IN ('sender', 'recipient', 'participant', 'mentioned', 'contact')
    )
);

-- ============================================================================
-- INDEXES
-- ============================================================================

-- Documents
CREATE INDEX IF NOT EXISTS idx_documents_source_type ON documents(source_type);
CREATE INDEX IF NOT EXISTS idx_documents_external_id ON documents(external_id);
CREATE INDEX IF NOT EXISTS idx_documents_active_version ON documents(is_active_version) WHERE is_active_version = true;
CREATE INDEX IF NOT EXISTS idx_documents_thread ON documents(thread_id) WHERE thread_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_documents_content_timestamp ON documents(content_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_documents_status ON documents(status);
CREATE INDEX IF NOT EXISTS idx_documents_ingested_at ON documents(ingested_at DESC);
CREATE INDEX IF NOT EXISTS idx_documents_people ON documents USING GIN(people);
CREATE INDEX IF NOT EXISTS idx_documents_metadata ON documents USING GIN(metadata);
CREATE INDEX IF NOT EXISTS idx_documents_text_search ON documents USING GIN(to_tsvector('english', text));
CREATE INDEX IF NOT EXISTS idx_documents_source_timestamp ON documents(source_type, content_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_documents_thread_active ON documents(thread_id, is_active_version)
    WHERE is_active_version = true AND thread_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_documents_has_attachments ON documents(has_attachments) WHERE has_attachments = true;
CREATE INDEX IF NOT EXISTS idx_documents_has_location ON documents(has_location) WHERE has_location = true;
CREATE INDEX IF NOT EXISTS idx_documents_due_date ON documents(due_date) WHERE due_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_documents_is_completed ON documents(is_completed) WHERE is_completed = true;
CREATE INDEX IF NOT EXISTS idx_documents_upcoming_incomplete ON documents(due_date)
    WHERE has_due_date = true AND (is_completed IS NULL OR is_completed = false);
CREATE INDEX IF NOT EXISTS idx_documents_intent ON documents USING GIN(intent);
CREATE INDEX IF NOT EXISTS idx_documents_relevance_score ON documents(relevance_score) 
    WHERE relevance_score IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_documents_email_local ON documents(source_type, content_timestamp DESC) 
    WHERE source_type = 'email_local';

-- Batches
CREATE INDEX IF NOT EXISTS idx_ingest_batches_status ON ingest_batches(status);
CREATE INDEX IF NOT EXISTS idx_ingest_batches_created_at ON ingest_batches(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ingest_submissions_batch_id ON ingest_submissions(batch_id);
CREATE INDEX IF NOT EXISTS idx_ingest_submissions_batch_status ON ingest_submissions(batch_id, status);

-- Threads
CREATE INDEX IF NOT EXISTS idx_threads_external_id ON threads(external_id);
CREATE INDEX IF NOT EXISTS idx_threads_source_type ON threads(source_type);
CREATE INDEX IF NOT EXISTS idx_threads_last_message ON threads(last_message_at DESC);
CREATE INDEX IF NOT EXISTS idx_threads_participants ON threads USING GIN(participants);

-- Files
CREATE INDEX IF NOT EXISTS idx_files_content_sha256 ON files(content_sha256);
CREATE INDEX IF NOT EXISTS idx_files_enrichment_status ON files(enrichment_status);
CREATE INDEX IF NOT EXISTS idx_files_mime_type ON files(mime_type);
CREATE INDEX IF NOT EXISTS idx_files_enrichment ON files USING GIN(enrichment);

-- Document ↔ File
CREATE INDEX IF NOT EXISTS idx_document_files_doc ON document_files(doc_id);
CREATE INDEX IF NOT EXISTS idx_document_files_file ON document_files(file_id);
CREATE INDEX IF NOT EXISTS idx_document_files_role ON document_files(role);

-- Chunks
CREATE INDEX IF NOT EXISTS idx_chunks_embedding_status ON chunks(embedding_status);
CREATE INDEX IF NOT EXISTS idx_chunks_text_search ON chunks USING GIN(to_tsvector('english', text));

-- Chunk ↔ Document
CREATE INDEX IF NOT EXISTS idx_chunk_documents_chunk ON chunk_documents(chunk_id);
CREATE INDEX IF NOT EXISTS idx_chunk_documents_doc ON chunk_documents(doc_id);

-- Ingest submissions
CREATE INDEX IF NOT EXISTS idx_ingest_submissions_status ON ingest_submissions(status);
CREATE INDEX IF NOT EXISTS idx_ingest_submissions_source ON ingest_submissions(source_type, source_id);

-- Source change tokens
CREATE INDEX IF NOT EXISTS idx_source_change_tokens_updated ON source_change_tokens(updated_at);

-- People
CREATE INDEX IF NOT EXISTS idx_people_display_name ON people(display_name);
CREATE INDEX IF NOT EXISTS idx_people_deleted ON people(deleted) WHERE deleted = false;
CREATE INDEX IF NOT EXISTS idx_people_source ON people(source);

-- Person identifiers
CREATE INDEX IF NOT EXISTS idx_person_identifiers_lookup ON person_identifiers(kind, value_canonical);
CREATE INDEX IF NOT EXISTS idx_person_identifiers_person_id ON person_identifiers(person_id);

-- People source map
CREATE INDEX IF NOT EXISTS idx_people_source_map_lookup ON people_source_map(source, external_id);
CREATE INDEX IF NOT EXISTS idx_people_source_map_person_id ON people_source_map(person_id);

-- Person addresses
CREATE INDEX IF NOT EXISTS idx_person_addresses_person_id ON person_addresses(person_id);

-- Person URLs
CREATE INDEX IF NOT EXISTS idx_person_urls_person_id ON person_urls(person_id);

-- People conflict log
CREATE INDEX IF NOT EXISTS idx_people_conflict_log_source ON people_conflict_log(source, external_id);
CREATE INDEX IF NOT EXISTS idx_people_conflict_log_created_at ON people_conflict_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_people_conflict_log_identifier ON people_conflict_log(kind, value_canonical);

-- Document ↔ People junction
CREATE INDEX IF NOT EXISTS idx_document_people_person ON document_people(person_id);
CREATE INDEX IF NOT EXISTS idx_document_people_doc ON document_people(doc_id);
CREATE INDEX IF NOT EXISTS idx_document_people_role ON document_people(role);

-- ============================================================================
-- FUNCTIONS & TRIGGERS
-- ============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_documents_set_updated ON documents;
CREATE TRIGGER trg_documents_set_updated
    BEFORE UPDATE ON documents
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_threads_set_updated ON threads;
CREATE TRIGGER trg_threads_set_updated
    BEFORE UPDATE ON threads
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_files_set_updated ON files;
CREATE TRIGGER trg_files_set_updated
    BEFORE UPDATE ON files
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_chunks_set_updated ON chunks;
CREATE TRIGGER trg_chunks_set_updated
    BEFORE UPDATE ON chunks
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_ingest_submissions_set_updated ON ingest_submissions;
CREATE TRIGGER trg_ingest_submissions_set_updated
    BEFORE UPDATE ON ingest_submissions
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_source_change_tokens_set_updated ON source_change_tokens;
CREATE TRIGGER trg_source_change_tokens_set_updated
    BEFORE UPDATE ON source_change_tokens
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_people_set_updated ON people;
CREATE TRIGGER trg_people_set_updated
    BEFORE UPDATE ON people
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- VIEWS
-- ============================================================================

CREATE OR REPLACE VIEW active_documents AS
SELECT *
FROM documents
WHERE is_active_version = true;

CREATE OR REPLACE VIEW documents_with_files AS
SELECT
    d.*,
    df.role AS file_role,
    df.attachment_index,
    f.file_id,
    f.filename AS file_filename,
    f.mime_type AS file_mime_type,
    f.size_bytes AS file_size,
    f.enrichment_status AS file_enrichment_status,
    f.enrichment AS file_enrichment
FROM documents d
JOIN document_files df ON d.doc_id = df.doc_id
JOIN files f ON df.file_id = f.file_id
WHERE d.is_active_version = true;

CREATE OR REPLACE VIEW thread_summary AS
SELECT
    t.thread_id,
    t.external_id,
    t.title,
    t.source_type,
    t.participant_count,
    t.first_message_at,
    t.last_message_at,
    COUNT(d.doc_id) AS message_count,
    SUM(CASE WHEN d.has_attachments THEN 1 ELSE 0 END) AS attachment_count
FROM threads t
LEFT JOIN documents d ON t.thread_id = d.thread_id AND d.is_active_version = true
GROUP BY t.thread_id, t.external_id, t.title, t.source_type, t.participant_count, t.first_message_at, t.last_message_at;

-- ============================================================================
-- SEARCH SERVICE TABLES
-- ============================================================================

-- Search documents table for the search service
CREATE TABLE search_documents (
    document_id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    title TEXT,
    url TEXT,
    mime_type TEXT,
    author TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    metadata JSONB DEFAULT '{}'::jsonb,
    facets JSONB DEFAULT '[]'::jsonb,
    tags TEXT[] DEFAULT ARRAY[]::TEXT[],
    acl JSONB DEFAULT '{}'::jsonb,
    raw_text BYTEA,
    chunk_count INTEGER DEFAULT 0,
    embedding_model TEXT,
    updated_at_system TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at_system TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_search_documents_org_id ON search_documents(org_id);
CREATE INDEX idx_search_documents_source_id ON search_documents(source_id);
CREATE INDEX idx_search_documents_created_at ON search_documents(created_at);

-- Search chunks table for the search service
CREATE TABLE search_chunks (
    chunk_id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES search_documents(document_id) ON DELETE CASCADE,
    org_id TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    text TEXT NOT NULL,
    metadata JSONB DEFAULT '{}'::jsonb,
    facets JSONB DEFAULT '[]'::jsonb,
    embedding vector(768),
    embedding_status TEXT NOT NULL DEFAULT 'pending',
    embedding_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_search_chunks_document_id ON search_chunks(document_id);
CREATE INDEX idx_search_chunks_org_id ON search_chunks(org_id);
CREATE INDEX idx_search_chunks_embedding_status ON search_chunks(embedding_status);

-- Search ingest log for idempotency
CREATE TABLE search_ingest_log (
    org_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    document_id TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (org_id, idempotency_key)
);

CREATE INDEX idx_search_ingest_log_document_id ON search_ingest_log(document_id);

-- Search deletes log (optional, for tracking deletions)
CREATE TABLE search_deletes (
    delete_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    org_id TEXT NOT NULL,
    document_id TEXT NOT NULL,
    deleted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_search_deletes_org_id ON search_deletes(org_id);
CREATE INDEX idx_search_deletes_deleted_at ON search_deletes(deleted_at);
