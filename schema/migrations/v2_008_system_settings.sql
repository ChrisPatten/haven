-- Migration: v2_008_system_settings.sql
-- Purpose: Add system_settings table for persisting system-wide configuration (e.g., self_person_id)

BEGIN;

-- Create system_settings table for storing system-wide key-value pairs
CREATE TABLE IF NOT EXISTS system_settings (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE system_settings IS 'System-wide settings stored as key-value pairs. Keys are strings, values are JSON objects. Used to persist configuration that applies to the entire Haven instance (e.g., self_person_id, system metadata).';
COMMENT ON COLUMN system_settings.key IS 'Unique setting key (e.g., "self_person_id", "system_version"). Primary key.';
COMMENT ON COLUMN system_settings.value IS 'JSON value for the setting. For self_person_id, contains {self_person_id: UUID, source: string, detected_at: ISO8601 timestamp}.';
COMMENT ON COLUMN system_settings.created_at IS 'Timestamp when the setting was first created.';
COMMENT ON COLUMN system_settings.updated_at IS 'Timestamp when the setting was last updated.';

-- Create trigger to auto-update updated_at on changes
CREATE OR REPLACE FUNCTION update_system_settings_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_system_settings_updated_at ON system_settings;
CREATE TRIGGER trg_system_settings_updated_at
  BEFORE UPDATE ON system_settings
  FOR EACH ROW
  EXECUTE FUNCTION update_system_settings_updated_at();

COMMIT;
