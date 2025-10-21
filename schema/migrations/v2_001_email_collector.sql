-- Migration: v2_001_email_collector
-- Description: Add email_local source type and intent/relevance fields for email collector
-- Date: 2025-10-20
-- Bead: haven-27

-- ============================================================================
-- 1. Update CHECK constraints to include email_local
-- ============================================================================

-- Add email_local to documents.source_type constraint
ALTER TABLE documents DROP CONSTRAINT IF EXISTS documents_valid_source_type;
ALTER TABLE documents ADD CONSTRAINT documents_valid_source_type CHECK (
    source_type IN ('imessage', 'sms', 'email', 'email_local', 'localfs', 'gdrive', 'note', 'reminder', 'calendar_event', 'contact')
);

-- Add email to threads.source_type constraint (if not already present)
-- Note: email was already in the original constraint, but email_local is document-level only
ALTER TABLE threads DROP CONSTRAINT IF EXISTS threads_valid_source_type;
ALTER TABLE threads ADD CONSTRAINT threads_valid_source_type CHECK (
    source_type IN ('imessage', 'sms', 'email', 'slack', 'whatsapp', 'signal')
);

-- ============================================================================
-- 2. Add intent and relevance_score columns to documents
-- ============================================================================

-- Add intent column for classification (bills, receipts, confirmations, etc.)
ALTER TABLE documents ADD COLUMN IF NOT EXISTS intent JSONB DEFAULT NULL;

-- Add relevance_score for noise filtering
ALTER TABLE documents ADD COLUMN IF NOT EXISTS relevance_score FLOAT DEFAULT NULL;

-- Add comments for documentation
COMMENT ON COLUMN documents.intent IS 'JSONB field for email intent classification: bills, receipts, confirmations, appointments, action_requests, notifications, etc.';
COMMENT ON COLUMN documents.relevance_score IS 'Float score (0.0-1.0) for noise filtering; higher scores indicate more relevant/actionable content';

-- ============================================================================
-- 3. Create indexes for performance
-- ============================================================================

-- GIN index for JSONB intent queries (e.g., WHERE intent @> '{"type": "bill"}')
CREATE INDEX IF NOT EXISTS idx_documents_intent ON documents USING GIN(intent);

-- Partial index on relevance_score (only when set)
CREATE INDEX IF NOT EXISTS idx_documents_relevance_score ON documents(relevance_score) 
WHERE relevance_score IS NOT NULL;

-- Composite index for email_local queries (source_type + timestamp)
CREATE INDEX IF NOT EXISTS idx_documents_email_local ON documents(source_type, content_timestamp DESC) 
WHERE source_type = 'email_local';

-- ============================================================================
-- Verification queries (run these manually after migration)
-- ============================================================================

-- Verify constraint updates:
-- SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'documents'::regclass AND conname = 'documents_valid_source_type';
-- SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'threads'::regclass AND conname = 'threads_valid_source_type';

-- Verify new columns:
-- SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = 'documents' AND column_name IN ('intent', 'relevance_score');

-- Verify indexes:
-- SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'documents' AND indexname IN ('idx_documents_intent', 'idx_documents_relevance_score', 'idx_documents_email_local');

-- Example insert test:
-- INSERT INTO documents (external_id, source_type, text, text_sha256, content_timestamp, content_timestamp_type, intent, relevance_score)
-- VALUES ('test:email:1', 'email_local', 'Test email body', encode(sha256('Test email body'::bytea), 'hex'), NOW(), 'received', '{"type": "bill", "entities": {"amount": 49.99}}'::jsonb, 0.85);
