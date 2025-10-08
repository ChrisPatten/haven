#!/usr/bin/env bash
# Run from repository root. Executes SQL inside the postgres container created by docker compose.
# - Previews affected rows
# - (Optional) creates a backup table and copies affected messages
# - Updates messages.sender to 'me' where is_from_me is true
# - Verifies results
#
# Usage: paste and run. It will prompt before making the change.

set -euo pipefail

COMPOSE_PROJECT_DIR="$(pwd)"
SERVICE_NAME="postgres"
PG_CONN="postgresql://postgres:postgres@postgres:5432/haven"

echo "Previewing rows that would be updated (is_from_me = true AND sender <> 'me')..."
docker compose exec -T ${SERVICE_NAME} psql "${PG_CONN}" -t -c "SELECT count(*) FROM messages WHERE is_from_me IS TRUE AND sender <> 'me';"

echo "Sample rows (limit 10):"
docker compose exec -T ${SERVICE_NAME} psql "${PG_CONN}" -c "SELECT doc_id, thread_id, sender, is_from_me, ts FROM messages WHERE is_from_me IS TRUE AND sender <> 'me' LIMIT 10;"

read -p "Proceed to create an optional backup of affected rows and apply the update? (y/N) " CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "Aborting. No changes made."
  exit 0
fi

echo "Creating backup (messages_backup_sender_fix) and applying update in a transaction..."
docker compose exec -T ${SERVICE_NAME} psql "${PG_CONN}" <<'SQL'
BEGIN;

-- Optional: make a backup table for affected rows (only created once, preserved for auditing)
CREATE TABLE IF NOT EXISTS messages_backup_sender_fix AS TABLE messages WITH NO DATA;

-- Insert snapshot of affected rows (avoid duplicating if run multiple times)
INSERT INTO messages_backup_sender_fix
SELECT * FROM messages
WHERE is_from_me IS TRUE AND sender <> 'me'
ON CONFLICT DO NOTHING;

-- Apply the sender fix
UPDATE messages
SET sender = 'me',
    updated_at = NOW()
WHERE is_from_me IS TRUE AND sender <> 'me';

COMMIT;
SQL

echo "Update applied. Verifying..."

echo "Remaining rows needing update:"
docker compose exec -T ${SERVICE_NAME} psql "${PG_CONN}" -t -c "SELECT count(*) FROM messages WHERE is_from_me IS TRUE AND sender <> 'me';"

echo "Sample updated rows:"
docker compose exec -T ${SERVICE_NAME} psql "${PG_CONN}" -c "SELECT doc_id, thread_id, sender, is_from_me, ts FROM messages WHERE is_from_me IS TRUE LIMIT 10;"

echo "Done. If you want to requeue embeddings for affected chunks, the script can do that next."
read -p "Requeue embeddings for affected docs (mark embed_index_state.status='pending')? (y/N) " REQUEUE
if [[ "${REQUEUE}" = "y" || "${REQUEUE}" = "Y" ]]; then
  echo "Marking related embed_index_state rows as pending for affected docs..."
  docker compose exec -T ${SERVICE_NAME} psql "${PG_CONN}" <<'SQL'
BEGIN;
WITH affected AS (
  SELECT doc_id FROM messages WHERE is_from_me IS TRUE
)
UPDATE embed_index_state e
SET status = 'pending', updated_at = NOW()
FROM chunks c
WHERE e.chunk_id = c.id
  AND c.doc_id IN (SELECT doc_id FROM affected);
COMMIT;
SQL
  echo "Affected chunks requeued. Worker should pick them up shortly."
else
  echo "Skipping requeue."
fi

echo "All done."