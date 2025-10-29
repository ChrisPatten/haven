BEGIN;

CREATE TABLE IF NOT EXISTS ingest_batches (
    batch_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    idempotency_key TEXT UNIQUE NOT NULL,
    status TEXT NOT NULL DEFAULT 'submitted',
    total_count INTEGER NOT NULL DEFAULT 0,
    success_count INTEGER NOT NULL DEFAULT 0,
    failure_count INTEGER NOT NULL DEFAULT 0,
    error_details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ingest_batches_valid_status CHECK (
        status IN ('submitted', 'processing', 'completed', 'partial', 'failed')
    )
);

ALTER TABLE ingest_submissions
    ADD COLUMN IF NOT EXISTS batch_id UUID REFERENCES ingest_batches(batch_id);

CREATE INDEX IF NOT EXISTS idx_ingest_batches_status ON ingest_batches(status);
CREATE INDEX IF NOT EXISTS idx_ingest_batches_created_at ON ingest_batches(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ingest_submissions_batch_id ON ingest_submissions(batch_id);
CREATE INDEX IF NOT EXISTS idx_ingest_submissions_batch_status ON ingest_submissions(batch_id, status);

COMMIT;
