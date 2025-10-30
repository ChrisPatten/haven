-- Migration: v2_003_restore_people_tables
-- Description: Restore people normalization tables that were removed in v2 schema migration
-- Date: 2025-10-29
-- Bead: hv-108

BEGIN;

-- ============================================================================
-- 1. Create identifier_kind enum type
-- ============================================================================

-- Drop the type if it exists (e.g., from a previous incomplete migration)
-- This is safe because init.sql also drops it
DROP TYPE IF EXISTS identifier_kind CASCADE;

CREATE TYPE identifier_kind AS ENUM ('phone', 'email', 'imessage', 'shortcode', 'social');

-- ============================================================================
-- 2. Create people table (canonical person records)
-- ============================================================================

CREATE TABLE IF NOT EXISTS people (
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

CREATE INDEX IF NOT EXISTS idx_people_display_name ON people(display_name);
CREATE INDEX IF NOT EXISTS idx_people_deleted ON people(deleted) WHERE deleted = false;
CREATE INDEX IF NOT EXISTS idx_people_source ON people(source);

-- ============================================================================
-- 3. Create person_identifiers table (normalized phone/email identifiers)
-- ============================================================================

CREATE TABLE IF NOT EXISTS person_identifiers (
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    kind identifier_kind NOT NULL,
    value_raw TEXT NOT NULL,
    value_canonical TEXT NOT NULL,
    label TEXT,
    priority INTEGER NOT NULL DEFAULT 100,
    verified BOOLEAN NOT NULL DEFAULT true,
    CONSTRAINT person_identifiers_unique UNIQUE (person_id, kind, value_canonical)
);

CREATE INDEX IF NOT EXISTS idx_person_identifiers_lookup ON person_identifiers(kind, value_canonical);
CREATE INDEX IF NOT EXISTS idx_person_identifiers_person_id ON person_identifiers(person_id);

-- ============================================================================
-- 4. Create people_source_map table (maps external contact IDs to person_id)
-- ============================================================================

CREATE TABLE IF NOT EXISTS people_source_map (
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    CONSTRAINT people_source_map_unique UNIQUE (source, external_id)
);

CREATE INDEX IF NOT EXISTS idx_people_source_map_lookup ON people_source_map(source, external_id);
CREATE INDEX IF NOT EXISTS idx_people_source_map_person_id ON people_source_map(person_id);

-- ============================================================================
-- 5. Create person_addresses table (contact addresses)
-- ============================================================================

CREATE TABLE IF NOT EXISTS person_addresses (
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    street TEXT,
    city TEXT,
    region TEXT,
    postal_code TEXT,
    country TEXT,
    CONSTRAINT person_addresses_unique UNIQUE (person_id, label)
);

CREATE INDEX IF NOT EXISTS idx_person_addresses_person_id ON person_addresses(person_id);

-- ============================================================================
-- 6. Create person_urls table (contact URLs)
-- ============================================================================

CREATE TABLE IF NOT EXISTS person_urls (
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    url TEXT NOT NULL,
    CONSTRAINT person_urls_unique UNIQUE (person_id, label)
);

CREATE INDEX IF NOT EXISTS idx_person_urls_person_id ON person_urls(person_id);

-- ============================================================================
-- 7. Create people_conflict_log table (identifier conflict tracking)
-- ============================================================================

CREATE TABLE IF NOT EXISTS people_conflict_log (
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    kind identifier_kind NOT NULL,
    value_canonical TEXT NOT NULL,
    existing_person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    incoming_person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_people_conflict_log_source ON people_conflict_log(source, external_id);
CREATE INDEX IF NOT EXISTS idx_people_conflict_log_created_at ON people_conflict_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_people_conflict_log_identifier ON people_conflict_log(kind, value_canonical);

COMMIT;

