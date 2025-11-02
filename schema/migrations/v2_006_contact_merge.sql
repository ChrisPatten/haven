-- Migration: v2_006_contact_merge
-- Description: Add contact merge support with merged_into tracking and audit logging
-- Purpose: Enable duplicate contact detection and merging by phone/email identifiers

-- ============================================================================
-- 1. Add merged_into field to people table
-- ============================================================================

ALTER TABLE people ADD COLUMN IF NOT EXISTS merged_into UUID REFERENCES people(person_id) ON DELETE SET NULL;

-- Create index for efficient lookups of merged records
CREATE INDEX IF NOT EXISTS idx_people_merged_into ON people(merged_into) WHERE merged_into IS NOT NULL;

-- ============================================================================
-- 2. Create contacts_merge_audit table for audit trail
-- ============================================================================

CREATE TABLE IF NOT EXISTS contacts_merge_audit (
    merge_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    target_person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE RESTRICT,
    source_person_ids UUID[] NOT NULL,
    actor TEXT NOT NULL,
    strategy TEXT NOT NULL,
    merge_metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Create indexes for audit queries
CREATE INDEX IF NOT EXISTS idx_contacts_merge_audit_target ON contacts_merge_audit(target_person_id);
CREATE INDEX IF NOT EXISTS idx_contacts_merge_audit_created ON contacts_merge_audit(created_at DESC);

-- ============================================================================
-- 3. Comments for documentation
-- ============================================================================

COMMENT ON COLUMN people.merged_into IS 'UUID reference to the person_id this record was merged into. NULL if not merged (active record). Used for soft-delete and audit trail.';

COMMENT ON TABLE contacts_merge_audit IS 'Audit log for contact merge operations. Records all merge activities with source/target IDs, strategy, and metadata.';

COMMENT ON COLUMN contacts_merge_audit.target_person_id IS 'The surviving person_id that other records were merged into.';
COMMENT ON COLUMN contacts_merge_audit.source_person_ids IS 'Array of person_ids that were merged into the target.';
COMMENT ON COLUMN contacts_merge_audit.actor IS 'Who performed the merge (system, admin_user_id, script_name, etc.).';
COMMENT ON COLUMN contacts_merge_audit.strategy IS 'The merge strategy used (prefer_target, prefer_source, merge_non_null).';
COMMENT ON COLUMN contacts_merge_audit.merge_metadata IS 'Additional context about the merge (e.g., reason, conflict_resolution_details).';
