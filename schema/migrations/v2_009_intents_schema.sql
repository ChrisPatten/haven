-- Migration: v2_009_intents_schema.sql
-- Purpose: Add database schema for LLM-based Intents capability
-- Includes: intent_status columns on documents, intent_signals table, entity_cache, 
--           intent_taxonomies, intent_user_preferences, and intent_deduplication tables

BEGIN;

-- ============================================================================
-- DOCUMENTS TABLE UPDATES
-- ============================================================================

-- Add intent processing columns to documents table
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'documents' AND column_name = 'intent_status') THEN
        ALTER TABLE documents 
        ADD COLUMN intent_status TEXT NOT NULL DEFAULT 'pending';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'documents' AND column_name = 'intent_processing_started_at') THEN
        ALTER TABLE documents 
        ADD COLUMN intent_processing_started_at TIMESTAMPTZ;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'documents' AND column_name = 'intent_processing_completed_at') THEN
        ALTER TABLE documents 
        ADD COLUMN intent_processing_completed_at TIMESTAMPTZ;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'documents' AND column_name = 'intent_processing_error') THEN
        ALTER TABLE documents 
        ADD COLUMN intent_processing_error TEXT;
    END IF;
END $$;

-- Add constraint for valid intent_status values
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'documents_valid_intent_status'
    ) THEN
        ALTER TABLE documents
        ADD CONSTRAINT documents_valid_intent_status CHECK (
            intent_status IN ('pending', 'processing', 'processed', 'failed', 'skipped')
        );
    END IF;
END $$;

-- Index for worker polling (pending documents)
CREATE INDEX IF NOT EXISTS idx_documents_intent_status 
ON documents(intent_status, created_at) 
WHERE intent_status = 'pending';

-- Index for querying processed documents
CREATE INDEX IF NOT EXISTS idx_documents_intent_processed 
ON documents(intent_status, intent_processing_completed_at DESC)
WHERE intent_status = 'processed';

COMMENT ON COLUMN documents.intent_status IS 'Status of intent processing: pending, processing, processed, failed, skipped';
COMMENT ON COLUMN documents.intent_processing_started_at IS 'Timestamp when intent processing started';
COMMENT ON COLUMN documents.intent_processing_completed_at IS 'Timestamp when intent processing completed';
COMMENT ON COLUMN documents.intent_processing_error IS 'Error message if intent processing failed';

-- ============================================================================
-- INTENT SIGNALS TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS intent_signals (
    signal_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    artifact_id UUID NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    taxonomy_version VARCHAR(50) NOT NULL,
    parent_thread_id UUID REFERENCES threads(thread_id) ON DELETE SET NULL,
    
    -- Signal data (JSONB for flexibility, validated by application)
    signal_data JSONB NOT NULL,
    
    -- Status and feedback
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    user_feedback JSONB,  -- {action, corrected_slots, timestamp, user_id}
    
    -- Conflict handling
    conflict BOOLEAN NOT NULL DEFAULT FALSE,
    conflicting_fields TEXT[],
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT intent_signals_valid_status CHECK (
        status IN ('pending', 'confirmed', 'edited', 'rejected', 'snoozed')
    )
);

CREATE INDEX IF NOT EXISTS idx_intent_signals_artifact ON intent_signals(artifact_id);
CREATE INDEX IF NOT EXISTS idx_intent_signals_thread ON intent_signals(parent_thread_id) WHERE parent_thread_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_intent_signals_status ON intent_signals(status);
CREATE INDEX IF NOT EXISTS idx_intent_signals_taxonomy ON intent_signals(taxonomy_version);
CREATE INDEX IF NOT EXISTS idx_intent_signals_created ON intent_signals(created_at DESC);

-- GIN index for JSONB queries on signal_data
CREATE INDEX IF NOT EXISTS idx_intent_signals_data ON intent_signals USING GIN (signal_data);

COMMENT ON TABLE intent_signals IS 'Intent signals extracted from documents. Contains structured intent data with slots, evidence, and confidence scores.';
COMMENT ON COLUMN intent_signals.signal_id IS 'Unique identifier for the intent signal';
COMMENT ON COLUMN intent_signals.artifact_id IS 'Reference to the document that generated this signal';
COMMENT ON COLUMN intent_signals.taxonomy_version IS 'Version of the intent taxonomy used for classification';
COMMENT ON COLUMN intent_signals.parent_thread_id IS 'Reference to parent thread for thread-aware processing';
COMMENT ON COLUMN intent_signals.signal_data IS 'JSONB containing IntentSignal schema: intents, slots, evidence, confidence, timestamps, provenance';
COMMENT ON COLUMN intent_signals.status IS 'User feedback status: pending, confirmed, edited, rejected, snoozed';
COMMENT ON COLUMN intent_signals.user_feedback IS 'JSONB containing user feedback: action, corrected_slots, timestamp, user_id';
COMMENT ON COLUMN intent_signals.conflict IS 'True if this signal conflicts with another signal in the same thread';
COMMENT ON COLUMN intent_signals.conflicting_fields IS 'Array of field names that conflict with other signals';

-- ============================================================================
-- ENTITY CACHE TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS entity_cache (
    cache_key VARCHAR(255) PRIMARY KEY,  -- hash(artifact_id + text_hash)
    artifact_id UUID NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    entity_set JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_entity_cache_expires ON entity_cache(expires_at);
CREATE INDEX IF NOT EXISTS idx_entity_cache_artifact ON entity_cache(artifact_id);

COMMENT ON TABLE entity_cache IS 'TTL-based cache for entity extraction results. Reduces redundant NER processing.';
COMMENT ON COLUMN entity_cache.cache_key IS 'Hash key combining artifact_id and text_hash for cache lookup';
COMMENT ON COLUMN entity_cache.artifact_id IS 'Reference to the document whose entities are cached';
COMMENT ON COLUMN entity_cache.entity_set IS 'JSONB containing EntitySet schema: detected_languages, people, dates, locations, etc.';
COMMENT ON COLUMN entity_cache.expires_at IS 'Timestamp when cache entry expires (TTL-based cleanup)';

-- ============================================================================
-- INTENT TAXONOMIES TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS intent_taxonomies (
    version VARCHAR(50) PRIMARY KEY,
    taxonomy_data JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by VARCHAR(255),
    change_notes TEXT
);

CREATE INDEX IF NOT EXISTS idx_intent_taxonomies_created ON intent_taxonomies(created_at DESC);

COMMENT ON TABLE intent_taxonomies IS 'Versioned storage for intent taxonomy definitions. Contains intent definitions, slot schemas, and validation rules.';
COMMENT ON COLUMN intent_taxonomies.version IS 'Version identifier (e.g., "1.0.0")';
COMMENT ON COLUMN intent_taxonomies.taxonomy_data IS 'JSONB containing IntentTaxonomy schema: version, intents, slot definitions, constraints';
COMMENT ON COLUMN intent_taxonomies.created_by IS 'User or system that created this taxonomy version';
COMMENT ON COLUMN intent_taxonomies.change_notes IS 'Description of changes in this taxonomy version';

-- ============================================================================
-- INTENT USER PREFERENCES TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS intent_user_preferences (
    user_id VARCHAR(255) PRIMARY KEY,  -- For multi-user support, 'default' for single user
    preferences JSONB NOT NULL DEFAULT '{}'::jsonb,  -- {intent_name: {automation_level, thresholds}, ...}
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_intent_user_preferences_updated ON intent_user_preferences(updated_at DESC);

COMMENT ON TABLE intent_user_preferences IS 'User-specific preferences for intent automation levels and confidence thresholds';
COMMENT ON COLUMN intent_user_preferences.user_id IS 'User identifier, or "default" for single-user instances';
COMMENT ON COLUMN intent_user_preferences.preferences IS 'JSONB containing per-intent preferences: automation_level, confidence_threshold, etc.';

-- ============================================================================
-- INTENT DEDUPLICATION TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS intent_deduplication (
    dedupe_key VARCHAR(255) PRIMARY KEY,  -- hash(thread_id + intent_name + normalized_slots)
    signal_id UUID NOT NULL REFERENCES intent_signals(signal_id) ON DELETE CASCADE,
    thread_id UUID REFERENCES threads(thread_id) ON DELETE CASCADE,
    intent_name VARCHAR(100) NOT NULL,
    normalized_slots_hash VARCHAR(64) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    window_end_at TIMESTAMPTZ NOT NULL  -- For TTL-based cleanup
);

CREATE INDEX IF NOT EXISTS idx_intent_dedup_window ON intent_deduplication(window_end_at);
CREATE INDEX IF NOT EXISTS idx_intent_dedup_thread ON intent_deduplication(thread_id) WHERE thread_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_intent_dedup_signal ON intent_deduplication(signal_id);

COMMENT ON TABLE intent_deduplication IS 'Thread-aware deduplication tracking. Prevents duplicate signals within a time window.';
COMMENT ON COLUMN intent_deduplication.dedupe_key IS 'Hash key combining thread_id, intent_name, and normalized_slots for duplicate detection';
COMMENT ON COLUMN intent_deduplication.signal_id IS 'Reference to the intent signal being tracked';
COMMENT ON COLUMN intent_deduplication.thread_id IS 'Reference to thread for thread-aware deduplication';
COMMENT ON COLUMN intent_deduplication.intent_name IS 'Name of the intent being deduplicated';
COMMENT ON COLUMN intent_deduplication.normalized_slots_hash IS 'Hash of normalized slot values for comparison';
COMMENT ON COLUMN intent_deduplication.window_end_at IS 'Timestamp when deduplication window expires (TTL-based cleanup)';

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Trigger to auto-update updated_at on intent_signals
DROP TRIGGER IF EXISTS trg_intent_signals_set_updated ON intent_signals;
CREATE TRIGGER trg_intent_signals_set_updated
    BEFORE UPDATE ON intent_signals
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Trigger to auto-update updated_at on intent_user_preferences
DROP TRIGGER IF EXISTS trg_intent_user_preferences_set_updated ON intent_user_preferences;
CREATE TRIGGER trg_intent_user_preferences_set_updated
    BEFORE UPDATE ON intent_user_preferences
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMIT;

