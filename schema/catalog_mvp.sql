-- Catalog MVP schema for Haven PDP
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE TABLE IF NOT EXISTS threads (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    participants JSONB NOT NULL DEFAULT '[]'::jsonb,
    title TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS messages (
    doc_id TEXT PRIMARY KEY,
    thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    message_guid TEXT NOT NULL,
    ts TIMESTAMPTZ NOT NULL,
    sender TEXT NOT NULL,
    sender_service TEXT,
    is_from_me BOOLEAN NOT NULL,
    text TEXT NOT NULL,
    attrs JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    tsv tsvector
);

CREATE INDEX IF NOT EXISTS idx_messages_thread_ts ON messages(thread_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_messages_tsv ON messages USING GIN (tsv);

CREATE TABLE IF NOT EXISTS ingest_submissions (
    submission_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    idempotency_key TEXT NOT NULL UNIQUE,
    source_type TEXT NOT NULL,
    source_id TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'submitted',
    error_json JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS documents (
    doc_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    submission_id UUID NOT NULL REFERENCES ingest_submissions(submission_id) ON DELETE CASCADE,
    canonical_uri TEXT,
    mime_type TEXT,
    title TEXT,
    text TEXT NOT NULL,
    text_sha256 TEXT NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL DEFAULT 'submitted',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_documents_submission ON documents(submission_id);

CREATE TABLE IF NOT EXISTS chunks (
    chunk_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    doc_id UUID NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    ord INTEGER NOT NULL,
    text TEXT NOT NULL,
    text_sha256 TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (doc_id, ord)
);

CREATE TABLE IF NOT EXISTS embed_jobs (
    chunk_id UUID PRIMARY KEY REFERENCES chunks(chunk_id) ON DELETE CASCADE,
    tries INTEGER NOT NULL DEFAULT 0,
    last_error JSONB,
    locked_by TEXT,
    locked_at TIMESTAMPTZ,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_embed_jobs_next_attempt ON embed_jobs(next_attempt_at);

CREATE TABLE IF NOT EXISTS delete_jobs (
    doc_id UUID PRIMARY KEY REFERENCES documents(doc_id) ON DELETE CASCADE,
    tries INTEGER NOT NULL DEFAULT 0,
    last_error JSONB,
    locked_by TEXT,
    locked_at TIMESTAMPTZ,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_message_tsv()
RETURNS TRIGGER AS $$
BEGIN
    NEW.tsv = to_tsvector('english', coalesce(unaccent(NEW.text), ''));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_messages_set_updated ON messages;
CREATE TRIGGER trg_messages_set_updated
BEFORE UPDATE ON messages
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_threads_set_updated ON threads;
CREATE TRIGGER trg_threads_set_updated
BEFORE UPDATE ON threads
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_ingest_submissions_set_updated ON ingest_submissions;
CREATE TRIGGER trg_ingest_submissions_set_updated
BEFORE UPDATE ON ingest_submissions
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_documents_set_updated ON documents;
CREATE TRIGGER trg_documents_set_updated
BEFORE UPDATE ON documents
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_chunks_set_updated ON chunks;
CREATE TRIGGER trg_chunks_set_updated
BEFORE UPDATE ON chunks
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_messages_update_tsv ON messages;
CREATE TRIGGER trg_messages_update_tsv
BEFORE INSERT OR UPDATE ON messages
FOR EACH ROW
EXECUTE FUNCTION update_message_tsv();


CREATE TABLE IF NOT EXISTS search_documents (
    document_id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    title TEXT,
    url TEXT,
    mime_type TEXT,
    author TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    facets JSONB NOT NULL DEFAULT '[]'::jsonb,
    tags TEXT[] NOT NULL DEFAULT '{}',
    acl JSONB NOT NULL,
    raw_text BYTEA,
    chunk_count INTEGER NOT NULL DEFAULT 0,
    embedding_model TEXT,
    created_at_system TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at_system TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS search_chunks (
    chunk_id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES search_documents(document_id) ON DELETE CASCADE,
    org_id TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    text TEXT NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    facets JSONB NOT NULL DEFAULT '[]'::jsonb,
    embedding_status TEXT NOT NULL DEFAULT 'pending',
    embedding_error TEXT,
    tsv tsvector,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_search_chunks_doc_ord ON search_chunks(document_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_search_chunks_org ON search_chunks(org_id);
CREATE INDEX IF NOT EXISTS idx_search_chunks_tsv ON search_chunks USING GIN (tsv);
CREATE INDEX IF NOT EXISTS idx_search_docs_org ON search_documents(org_id);

CREATE TABLE IF NOT EXISTS search_ingest_log (
    id SERIAL PRIMARY KEY,
    org_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    document_id TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (org_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS search_deletes (
    id SERIAL PRIMARY KEY,
    org_id TEXT NOT NULL,
    selector JSONB NOT NULL,
    deleted_count INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION update_search_chunk_tsv()
RETURNS TRIGGER AS $$
BEGIN
    NEW.tsv = to_tsvector('english', coalesce(unaccent(NEW.text), ''));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_search_chunks_update_tsv ON search_chunks;
CREATE TRIGGER trg_search_chunks_update_tsv
BEFORE INSERT OR UPDATE ON search_chunks
FOR EACH ROW
EXECUTE FUNCTION update_search_chunk_tsv();
