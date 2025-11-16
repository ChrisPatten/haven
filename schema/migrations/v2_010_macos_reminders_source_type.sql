-- Migration: v2_010_macos_reminders_source_type
-- Description: Add macos_reminders source type to documents constraint
-- Date: 2025-11-10

-- ============================================================================
-- Update CHECK constraint to include macos_reminders
-- ============================================================================

-- Add macos_reminders to documents.source_type constraint
ALTER TABLE documents DROP CONSTRAINT IF EXISTS documents_valid_source_type;
ALTER TABLE documents ADD CONSTRAINT documents_valid_source_type CHECK (
    source_type IN ('imessage', 'sms', 'email', 'email_local', 'localfs', 'gdrive', 'note', 'reminder', 'macos_reminders', 'calendar_event', 'contact')
);

-- ============================================================================
-- Verification query (run this manually after migration)
-- ============================================================================

-- Verify constraint update:
-- SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'documents'::regclass AND conname = 'documents_valid_source_type';

