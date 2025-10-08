-- Contacts ingestion schema additions for Haven catalog
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'identifier_kind') THEN
        CREATE TYPE identifier_kind AS ENUM ('phone', 'email', 'imessage', 'shortcode', 'social');
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS people (
    person_id UUID PRIMARY KEY,
    display_name TEXT NOT NULL,
    given_name TEXT,
    family_name TEXT,
    organization TEXT,
    nicknames TEXT[] DEFAULT '{}',
    notes TEXT,
    photo_hash TEXT,
    source TEXT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    deleted BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS people_source_map (
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    PRIMARY KEY (source, external_id)
);

CREATE TABLE IF NOT EXISTS person_identifiers (
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    kind identifier_kind NOT NULL,
    value_raw TEXT NOT NULL,
    value_canonical TEXT NOT NULL,
    label TEXT,
    priority INT NOT NULL DEFAULT 100,
    verified BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (person_id, kind, value_canonical)
);

CREATE TABLE IF NOT EXISTS person_addresses (
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    label TEXT NOT NULL DEFAULT 'other',
    street TEXT,
    city TEXT,
    region TEXT,
    postal_code TEXT,
    country TEXT,
    PRIMARY KEY (person_id, label)
);

CREATE TABLE IF NOT EXISTS person_urls (
    person_id UUID NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
    label TEXT NOT NULL DEFAULT 'other',
    url TEXT,
    PRIMARY KEY (person_id, label)
);

CREATE TABLE IF NOT EXISTS source_change_tokens (
    source TEXT NOT NULL,
    device_id TEXT NOT NULL,
    change_token_b64 TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source, device_id)
);

CREATE TABLE IF NOT EXISTS people_conflict_log (
    conflict_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    kind identifier_kind NOT NULL,
    value_canonical TEXT NOT NULL,
    existing_person_id UUID,
    incoming_person_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notes TEXT
);

CREATE INDEX IF NOT EXISTS people_display_trgm_idx
    ON people USING gin (display_name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS people_name_search_idx
    ON people USING gin ((coalesce(given_name,'') || ' ' || coalesce(family_name,'') || ' ' || coalesce(organization,'')) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS person_addresses_city_idx ON person_addresses (city);
CREATE INDEX IF NOT EXISTS person_addresses_region_idx ON person_addresses (region);
CREATE INDEX IF NOT EXISTS person_addresses_country_idx ON person_addresses (country);
CREATE INDEX IF NOT EXISTS person_identifiers_kind_idx ON person_identifiers (kind);
CREATE INDEX IF NOT EXISTS person_identifiers_label_idx ON person_identifiers (label);

CREATE UNIQUE INDEX IF NOT EXISTS person_identifiers_lookup_idx
    ON person_identifiers (kind, value_canonical);

CREATE OR REPLACE FUNCTION set_people_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_people_set_updated ON people;
CREATE TRIGGER trg_people_set_updated
BEFORE UPDATE ON people
FOR EACH ROW EXECUTE FUNCTION set_people_updated_at();

DROP TRIGGER IF EXISTS trg_person_identifiers_set_updated ON person_identifiers;
CREATE TRIGGER trg_person_identifiers_set_updated
BEFORE UPDATE ON person_identifiers
FOR EACH ROW EXECUTE FUNCTION set_people_updated_at();
