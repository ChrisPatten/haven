-- Migration: v2_004_document_people_junction
-- Description: Create document_people junction table to link documents to normalized person entities
-- Date: 2025-10-29
-- Bead: hv-109

BEGIN;

-- ============================================================================
-- Create document_people junction table
-- ============================================================================

CREATE TABLE IF NOT EXISTS document_people (
    doc_id UUID NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    PRIMARY KEY (doc_id, person_id),
    CONSTRAINT document_people_valid_role CHECK (
        role IN ('sender', 'recipient', 'participant', 'mentioned', 'contact')
    )
);

CREATE INDEX IF NOT EXISTS idx_document_people_person ON document_people(person_id);
CREATE INDEX IF NOT EXISTS idx_document_people_doc ON document_people(doc_id);
CREATE INDEX IF NOT EXISTS idx_document_people_role ON document_people(role);

COMMIT;


