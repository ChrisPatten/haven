# Relationship Feature Aggregation

The relationship feature aggregation job (hv-62) enriches directional edges in
`crm_relationships` with raw communication metrics. These features are consumed
by hv-63 for scoring and hv-64 for API exposure.

## Overview

The job queries message activity from Postgres (`documents` joined with
`document_people`) and updates `crm_relationships.edge_features`, along with the
latest contact timestamp and decay bucket.

```bash
python -m services.search_service.relationship_features
```

Running the module prints the number of relationships updated. Schedule it via
cron or a worker once hv-63 lands.

## Feature Definitions

| Feature Key | Description |
| ----------- | ----------- |
| `days_since_last_message` | Days since the most recent contact (floating point) |
| `messages_30d` | Total messages exchanged in the last 30 days |
| `distinct_threads_90d` | Unique thread IDs seen in the last 90 days |
| `attachments_30d` | Attachment count exchanged in the last 30 days |
| `avg_reply_latency_seconds` | Average seconds from inbound message → outbound reply by `self_person_id` |

Attachment totals are based on `documents.attachment_count`. Events include both
inbound and outbound directions so every `(self_person_id, person_id)` pair
captures bi-directional history.

## Decay Buckets

`decay_bucket` is recalculated alongside edge features:

| Bucket | Range | Meaning |
| ------ | ----- | ------- |
| `0` | ≤ 1 day | Very recent |
| `1` | ≤ 7 days | Within the current week |
| `2` | ≤ 30 days | Within the last month |
| `3` | ≤ 90 days | Within the last quarter |
| `4` | ≤ 180 days | ~Half-year |
| `5` | > 180 days | Stale |

These buckets align with indexes defined in hv-61.

## Data Flow

1. Load message events from `documents` + `document_people`
   * Filters to active versions, non-failed statuses, and supported message sources.
   * Emits outbound events from sender → recipient(s) and inbound events from
     recipient → sender.
2. Group events for each `(self_person_id, person_id)`.
3. Compute feature summary via `summarize_events`.
4. Upsert results into `crm_relationships` with JSON edge metrics and updated
   `last_contact_at` / `decay_bucket`.

## Gateway Endpoint: Top Relationships

`GET /v1/crm/relationships/top` exposes the computed data through the Gateway.
Clients supply an optional `self_person_id` (UUID) and `window` (`"<days>d"`,
defaults to `90d`). If `self_person_id` is omitted, Gateway falls back to the
stored value in `system_settings` when available. Pagination uses `limit`
(1–500, default 50) and `offset` (default 0).

The response includes:
- `relationships[*].person_id`: Contact UUID.
- `relationships[*].score`: Latest computed score for the `(self, person)` pair.
- `relationships[*].last_contact_at`: ISO8601 timestamp of the most recent interaction.
- `relationships[*].display_name` / `organization`: Metadata from `people`.
- `relationships[*].emails` / `phones`: Canonical identifiers sourced from `person_identifiers`.
- `window_start` / `window_end`: Temporal bounds applied to the query.

Example request:

```bash
curl -H "Authorization: Bearer $HAVEN_API_TOKEN" \
     "http://localhost:8085/v1/crm/relationships/top?window=30d&limit=10"
```

Use the response `total_count` to drive pagination UI and follow the provided
`window_start`/`window_end` timestamps when presenting the data to users.

## Testing

Unit coverage in `tests/test_relationship_features.py` verifies:

* Correct message/attachment counts within time windows.
* Thread deduplication behaviour.
* Reply latency averaging between inbound/outbound pairs.
* Guards against empty event collections.

Add integration coverage once hv-63 orchestrates database execution end-to-end.
