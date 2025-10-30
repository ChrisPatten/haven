-- Migration: v2_005_crm_relationships
-- Description: Add CRM relationship scoring table with indexes for efficient top N queries
-- Date: 2025-10-30
-- Bead: hv-61

-- ============================================================================
-- 1. Create crm_relationships table
-- ============================================================================

CREATE TABLE crm_relationships (
    relationship_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    self_person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    score FLOAT NOT NULL,
    last_contact_at TIMESTAMPTZ NOT NULL,
    decay_bucket INT NOT NULL,
    edge_features JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT crm_relationships_unique UNIQUE (self_person_id, person_id),
    CONSTRAINT crm_relationships_valid_score CHECK (score >= 0.0),
    CONSTRAINT crm_relationships_valid_decay_bucket CHECK (decay_bucket >= 0)
);

-- ============================================================================
-- 2. Add comments for documentation
-- ============================================================================

COMMENT ON TABLE crm_relationships IS 'Relationship strength scores between people. Directional: (self_person_id, person_id) represents "my relationship with contact".';
COMMENT ON COLUMN crm_relationships.relationship_id IS 'Immutable UUID primary key for the relationship edge.';
COMMENT ON COLUMN crm_relationships.self_person_id IS 'UUID reference to people table (FK): "me", the observer/subject.';
COMMENT ON COLUMN crm_relationships.person_id IS 'UUID reference to people table (FK): "contact", the other party in the relationship.';
COMMENT ON COLUMN crm_relationships.score IS 'Float score (0.0 and above) representing relationship strength. Exact range and normalization determined by hv-62.';
COMMENT ON COLUMN crm_relationships.last_contact_at IS 'TIMESTAMPTZ of the most recent message/contact with this person.';
COMMENT ON COLUMN crm_relationships.decay_bucket IS 'Integer temporal bucket for efficient time-windowed queries: 0=today, 1=week, 2=month, 3=quarter, etc.';
COMMENT ON COLUMN crm_relationships.edge_features IS 'JSONB object storing computed edge metrics: days_since_contact, message_count_30d, message_count_90d, etc. Used for debugging and analytics.';
COMMENT ON COLUMN crm_relationships.created_at IS 'TIMESTAMPTZ when the relationship record was created.';
COMMENT ON COLUMN crm_relationships.updated_at IS 'TIMESTAMPTZ of the last update to this relationship.';

-- ============================================================================
-- 3. Create indexes for query patterns
-- ============================================================================

-- Primary query pattern: get top N relationships for person X within time window Y
-- Index: (self_person_id, score DESC, last_contact_at DESC)
-- Supports: WHERE self_person_id = ? ORDER BY score DESC, last_contact_at DESC LIMIT N
CREATE INDEX idx_crm_relationships_top_score ON crm_relationships(
    self_person_id,
    score DESC,
    last_contact_at DESC
);
COMMENT ON INDEX idx_crm_relationships_top_score IS 'Primary index for top N relationships query pattern. Supports efficiently finding strongest relationships for a given person.';

-- Secondary pattern: time-windowed queries (e.g., "recent contacts")
-- Index: (self_person_id, last_contact_at DESC)
-- Supports: WHERE self_person_id = ? AND last_contact_at > ? ORDER BY last_contact_at DESC
CREATE INDEX idx_crm_relationships_recent_contacts ON crm_relationships(
    self_person_id,
    last_contact_at DESC
);
COMMENT ON INDEX idx_crm_relationships_recent_contacts IS 'Index for time-windowed queries. Supports efficiently finding recent contacts for a given person.';

-- Tertiary pattern: reverse lookup (who has me as a relationship)
-- Index: (person_id)
-- Supports: WHERE person_id = ? (e.g., finding all people who have X in their relationship list)
CREATE INDEX idx_crm_relationships_person_lookup ON crm_relationships(person_id);
COMMENT ON INDEX idx_crm_relationships_person_lookup IS 'Reverse lookup index. Supports finding all relationships where this person is the contact.';

-- Partial index on decay_bucket for common time windows (for future optimization)
-- Example: decay_bucket IN (0, 1, 2) represents today, week, month
CREATE INDEX idx_crm_relationships_decay_bucket_recent ON crm_relationships(
    self_person_id,
    score DESC
)
WHERE decay_bucket IN (0, 1, 2);
COMMENT ON INDEX idx_crm_relationships_decay_bucket_recent IS 'Partial index for recent relationships (today through month). Optimizes common time-window queries.';

-- ============================================================================
-- 4. Register update_at trigger
-- ============================================================================

DROP TRIGGER IF EXISTS trg_crm_relationships_set_updated ON crm_relationships;
CREATE TRIGGER trg_crm_relationships_set_updated
    BEFORE UPDATE ON crm_relationships
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- Verification queries (run these manually after migration)
-- ============================================================================

-- Verify table exists:
-- SELECT tablename FROM pg_tables WHERE tablename = 'crm_relationships';

-- Verify columns:
-- SELECT column_name, data_type, is_nullable FROM information_schema.columns 
-- WHERE table_name = 'crm_relationships' ORDER BY ordinal_position;

-- Verify constraints:
-- SELECT constraint_name, constraint_type FROM information_schema.table_constraints 
-- WHERE table_name = 'crm_relationships';

-- Verify indexes:
-- SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'crm_relationships' ORDER BY indexname;

-- Example insert test (assuming people with given UUIDs exist):
-- INSERT INTO crm_relationships (self_person_id, person_id, score, last_contact_at, decay_bucket)
-- VALUES (
--     '550e8400-e29b-41d4-a716-446655440000'::uuid,
--     '550e8400-e29b-41d4-a716-446655440001'::uuid,
--     85.5,
--     NOW() - interval '3 days',
--     1
-- );

