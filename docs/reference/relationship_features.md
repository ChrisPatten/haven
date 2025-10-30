# Relationship Feature Aggregation

The relationship feature aggregation job (hv-62) enriches the `crm_relationships`
table with directional metrics for each `(self_person_id, person_id)` pairing.
These metrics are used by downstream scoring (hv-63) and APIs (hv-64).

## Overview

The aggregator reads message activity from Postgres (`documents` +
`document_people`) and materialises summary statistics back into
`crm_relationships.edge_features`. Each row represents the relationship from
`self_person_id` (the subject) to `person_id` (the contact).

```bash
python -m services.search_service.relationship_features
```

The CLI prints the number of relationships updated and can be scheduled
independently (hv-63 will introduce orchestration).

## Feature Definitions

| Feature Key | Description |
| ----------- | ----------- |
| `days_since_last_message` | Days (float) since the most recent message between self and contact |
| `messages_30d` | Messages exchanged in the last 30 days (inbound + outbound) |
| `distinct_threads_90d` | Unique thread IDs observed in the last 90 days |
| `attachments_30d` | Total attachment count exchanged in the last 30 days |
| `avg_reply_latency_seconds` | Average seconds between an inbound message and the next outbound reply by `self_person_id` |

All timestamps are evaluated relative to `NOW()` (UTC). Attachment counts use
`documents.attachment_count`.

## Decay Buckets

`crm_relationships.decay_bucket` is recomputed alongside features using:

| Bucket | Range | Meaning |
| ------ | ----- | ------- |
| `0` | ≤ 1 day | Today / very recent |
| `1` | ≤ 7 days | Within the current week |
| `2` | ≤ 30 days | Within the last month |
| `3` | ≤ 90 days | Within the last quarter |
| `4` | ≤ 180 days | Approximately half-year |
| `5` | > 180 days | Stale |

These buckets power partial indexes defined in `hv-61`.

## Data Flow

1. Load directional events from `documents` joined with `document_people`.
   - Messages are considered if `source_type` ∈ `{imessage, sms, email, email_local}`,
     `is_active_version = true`, and `status ≠ 'failed'`.
   - Each message yields two events: `(sender → recipient)` and `(recipient ← sender)`
     so both perspectives capture history.
2. Group events by `(self_person_id, person_id)` and compute feature summary.
3. Upsert summaries into `crm_relationships`:
   - `score` remains untouched for existing rows (hv-63 will update it).
   - `edge_features` is rewritten with the new JSON payload.
   - `last_contact_at` and `decay_bucket` are refreshed.

## Testing

Unit coverage lives in `tests/test_relationship_features.py` and validates:

* Metric calculations (counts, attachment totals, thread visitation).
* Reply latency detection between inbound and outbound message sequences.
* Decay bucket assignment for recent interactions.

Add integration tests once job orchestration (hv-63) lands to exercise the full
database pipeline end-to-end.
