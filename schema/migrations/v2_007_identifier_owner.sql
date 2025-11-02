-- Migration: v2_007_identifier_owner
-- Description: Add identifier_owner and append_audit tables for atomic ownership tracking and audit logging
-- Purpose: Enable atomic identifier claiming during ingestion and audit trail for append operations
-- Date: 2025-10-31
-- Bead: hv-8fa1

-- ============================================================================
-- 1. Create identifier_owner table
-- ============================================================================

CREATE TABLE IF NOT EXISTS identifier_owner (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    kind TEXT NOT NULL,
    value_canonical TEXT NOT NULL,
    owner_person_id UUID REFERENCES people(person_id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT identifier_owner_unique UNIQUE (kind, value_canonical)
);

-- ============================================================================
-- 2. Create indexes for identifier_owner table
-- ============================================================================

-- Primary lookup: find owner by identifier (kind, value_canonical)
CREATE INDEX IF NOT EXISTS idx_identifier_owner_lookup ON identifier_owner(kind, value_canonical);

-- Reverse lookup: find all identifiers owned by a person
CREATE INDEX IF NOT EXISTS idx_identifier_owner_person ON identifier_owner(owner_person_id) WHERE owner_person_id IS NOT NULL;

-- ============================================================================
-- 3. Create append_audit table
-- ============================================================================

CREATE TABLE IF NOT EXISTS append_audit (
    append_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    target_person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE RESTRICT,
    incoming_person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE RESTRICT,
    identifiers_appended JSONB DEFAULT '[]'::jsonb,
    justification TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- 4. Create indexes for append_audit table
-- ============================================================================

-- Lookup by target person (most common query: "what was appended to person X?")
CREATE INDEX IF NOT EXISTS idx_append_audit_target ON append_audit(target_person_id);

-- Lookup by timestamp (recent append operations)
CREATE INDEX IF NOT EXISTS idx_append_audit_created ON append_audit(created_at DESC);

-- Lookup by source and external_id (find audit for specific ingestion)
CREATE INDEX IF NOT EXISTS idx_append_audit_source ON append_audit(source, external_id);

-- ============================================================================
-- 5. Comments for documentation
-- ============================================================================

COMMENT ON TABLE identifier_owner IS 'Atomic ownership tracking for canonical identifiers during ingestion. Ensures only one person can own a canonical identifier at a time.';

COMMENT ON COLUMN identifier_owner.id IS 'UUID primary key for the identifier ownership record.';
COMMENT ON COLUMN identifier_owner.kind IS 'Type of identifier (phone, email, etc.). Matches identifier_kind enum or TEXT.';
COMMENT ON COLUMN identifier_owner.value_canonical IS 'Canonical (normalized) value of the identifier. Combined with kind forms unique identifier.';
COMMENT ON COLUMN identifier_owner.owner_person_id IS 'UUID reference to people table. NULL if identifier is unclaimed. ON DELETE SET NULL allows person deletion to clear ownership.';
COMMENT ON COLUMN identifier_owner.created_at IS 'TIMESTAMPTZ when the identifier ownership record was created.';
COMMENT ON COLUMN identifier_owner.updated_at IS 'TIMESTAMPTZ of the last update to this ownership record.';

COMMENT ON TABLE append_audit IS 'Audit trail for append operations (separate from contacts_merge_audit which tracks merges). Records when person data is appended to an existing person during ingestion.';

COMMENT ON COLUMN append_audit.append_id IS 'UUID primary key for the append audit record.';
COMMENT ON COLUMN append_audit.source IS 'Source system that triggered the append (e.g., "contacts", "email", "imessage").';
COMMENT ON COLUMN append_audit.external_id IS 'External ID from the source system that triggered the append.';
COMMENT ON COLUMN append_audit.target_person_id IS 'UUID reference to people table: the person that received the appended data.';
COMMENT ON COLUMN append_audit.incoming_person_id IS 'UUID reference to people table: the incoming person that was appended to the target.';
COMMENT ON COLUMN append_audit.identifiers_appended IS 'JSONB array of identifiers that were appended (e.g., [{"kind": "phone", "value_canonical": "+1234567890"}]).';
COMMENT ON COLUMN append_audit.justification IS 'Text explanation of why the append happened (e.g., "identifier match on phone +1234567890").';
COMMENT ON COLUMN append_audit.created_at IS 'TIMESTAMPTZ when the append operation occurred.';

-- ============================================================================
-- 6. Register updated_at trigger for identifier_owner
-- ============================================================================

DROP TRIGGER IF EXISTS trg_identifier_owner_set_updated ON identifier_owner;
CREATE TRIGGER trg_identifier_owner_set_updated
    BEFORE UPDATE ON identifier_owner
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- Verification queries (run these manually after migration)
-- ============================================================================

-- Verify identifier_owner table exists:
-- SELECT tablename FROM pg_tables WHERE tablename = 'identifier_owner';

-- Verify identifier_owner columns:
-- SELECT column_name, data_type, is_nullable FROM information_schema.columns 
-- WHERE table_name = 'identifier_owner' ORDER BY ordinal_position;

-- Verify identifier_owner constraints:
-- SELECT constraint_name, constraint_type FROM information_schema.table_constraints 
-- WHERE table_name = 'identifier_owner';

-- Verify identifier_owner indexes:
-- SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'identifier_owner' ORDER BY indexname;

-- Verify append_audit table exists:
-- SELECT tablename FROM pg_tables WHERE tablename = 'append_audit';

-- Verify append_audit columns:
-- SELECT column_name, data_type, is_nullable FROM information_schema.columns 
-- WHERE table_name = 'append_audit' ORDER BY ordinal_position;

-- Verify append_audit constraints:
-- SELECT constraint_name, constraint_type FROM information_schema.table_constraints 
-- WHERE table_name = 'append_audit';

-- Verify append_audit indexes:
-- SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'append_audit' ORDER BY indexname;

