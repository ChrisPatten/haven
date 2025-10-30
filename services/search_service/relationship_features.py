from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Dict, Iterable, Iterator, List, Optional, Tuple
from uuid import UUID

try:  # pragma: no cover - optional dependency during unit tests
    import psycopg
    from psycopg.rows import dict_row
    from psycopg.types.json import Json
except ImportError:  # pragma: no cover
    psycopg = None  # type: ignore[assignment]
    dict_row = None  # type: ignore[assignment]
    Json = None  # type: ignore[assignment]

from shared.db import get_connection
from shared.logging import get_logger, setup_logging

logger = get_logger("search.relationship_features")


@dataclass(frozen=True, slots=True)
class RelationshipEvent:
    """Represents a single directional message event from the perspective of `self_person_id`."""

    self_person_id: UUID
    person_id: UUID
    timestamp: datetime
    thread_id: Optional[UUID]
    direction: str  # "inbound" | "outbound"
    attachment_count: int


@dataclass(frozen=True, slots=True)
class RelationshipFeatureSummary:
    last_contact_at: datetime
    days_since_last_message: float
    messages_30d: int
    distinct_threads_90d: int
    attachments_30d: int
    avg_reply_latency_seconds: Optional[float]
    decay_bucket: int

    def as_edge_features(self) -> Dict[str, object]:
        payload: Dict[str, object] = {
            "days_since_last_message": round(self.days_since_last_message, 2),
            "messages_30d": self.messages_30d,
            "distinct_threads_90d": self.distinct_threads_90d,
            "attachments_30d": self.attachments_30d,
        }
        if self.avg_reply_latency_seconds is not None:
            payload["avg_reply_latency_seconds"] = round(self.avg_reply_latency_seconds, 2)
        else:
            payload["avg_reply_latency_seconds"] = None
        return payload


def _default_now() -> datetime:
    return datetime.now(UTC)


def _compute_decay_bucket(delta: timedelta) -> int:
    days = delta.days
    if days <= 1:
        return 0  # today
    if days <= 7:
        return 1  # this week
    if days <= 30:
        return 2  # this month
    if days <= 90:
        return 3  # this quarter
    if days <= 180:
        return 4  # roughly half-year
    return 5  # stale


def _attachments_within(events: Iterable[RelationshipEvent], since: datetime) -> int:
    total = 0
    for event in events:
        if event.timestamp >= since:
            total += max(event.attachment_count, 0)
    return total


def _messages_within(events: Iterable[RelationshipEvent], since: datetime) -> int:
    return sum(1 for event in events if event.timestamp >= since)


def _distinct_threads_within(events: Iterable[RelationshipEvent], since: datetime) -> int:
    threads = {event.thread_id for event in events if event.thread_id and event.timestamp >= since}
    return len(threads)


def summarize_events(events: List[RelationshipEvent], *, now: Optional[datetime] = None) -> RelationshipFeatureSummary:
    if not events:
        raise ValueError("summarize_events requires at least one event")

    effective_now = now or _default_now()
    sorted_events = sorted(events, key=lambda evt: evt.timestamp)

    last_contact = sorted_events[-1].timestamp
    base_delta = effective_now - last_contact
    days_since_last = base_delta.total_seconds() / 86400.0

    thirty_days_ago = effective_now - timedelta(days=30)
    ninety_days_ago = effective_now - timedelta(days=90)

    messages_30d = _messages_within(sorted_events, thirty_days_ago)
    attachments_30d = _attachments_within(sorted_events, thirty_days_ago)
    distinct_threads_90d = _distinct_threads_within(sorted_events, ninety_days_ago)

    latencies: List[float] = []
    previous: Optional[RelationshipEvent] = None
    for event in sorted_events:
        if previous and previous.direction == "inbound" and event.direction == "outbound":
            delta = event.timestamp - previous.timestamp
            latencies.append(delta.total_seconds())
        previous = event

    avg_latency = sum(latencies) / len(latencies) if latencies else None
    decay_bucket = _compute_decay_bucket(base_delta)

    return RelationshipFeatureSummary(
        last_contact_at=last_contact,
        days_since_last_message=days_since_last,
        messages_30d=messages_30d,
        distinct_threads_90d=distinct_threads_90d,
        attachments_30d=attachments_30d,
        avg_reply_latency_seconds=avg_latency,
        decay_bucket=decay_bucket,
    )


_EVENT_QUERY = """
WITH base AS (
    SELECT
        d.doc_id,
        d.thread_id,
        d.content_timestamp,
        d.has_attachments,
        COALESCE(d.attachment_count, 0) AS attachment_count,
        sender.person_id AS sender_person_id,
        recipient.person_id AS recipient_person_id
    FROM documents d
    JOIN document_people sender
      ON sender.doc_id = d.doc_id
     AND sender.role = 'sender'
    JOIN document_people recipient
      ON recipient.doc_id = d.doc_id
     AND recipient.person_id <> sender.person_id
     AND recipient.role IN ('recipient', 'participant', 'contact')
    WHERE d.is_active_version = TRUE
      AND d.status NOT IN ('failed')
      AND d.content_timestamp IS NOT NULL
      AND d.source_type IN ('imessage', 'sms', 'email', 'email_local')
),
events AS (
    SELECT
        b.sender_person_id AS self_person_id,
        b.recipient_person_id AS person_id,
        'outbound'::text AS direction,
        b.content_timestamp,
        b.thread_id,
        CASE WHEN b.has_attachments THEN b.attachment_count ELSE 0 END AS attachment_count
    FROM base b
    UNION ALL
    SELECT
        b.recipient_person_id AS self_person_id,
        b.sender_person_id AS person_id,
        'inbound'::text AS direction,
        b.content_timestamp,
        b.thread_id,
        CASE WHEN b.has_attachments THEN b.attachment_count ELSE 0 END AS attachment_count
    FROM base b
)
SELECT
    self_person_id,
    person_id,
    direction,
    content_timestamp,
    thread_id,
    attachment_count
FROM events
WHERE self_person_id <> person_id
ORDER BY self_person_id, person_id, content_timestamp
"""


class RelationshipFeatureAggregator:
    """Loads message interactions from Postgres and persists aggregated relationship features."""

    def __init__(self, conn: "psycopg.Connection[Any]") -> None:
        if psycopg is None:  # pragma: no cover - guard when psycopg missing
            raise RuntimeError("psycopg is required to use RelationshipFeatureAggregator")
        self.conn = conn

    def load_events(self) -> Iterator[RelationshipEvent]:
        if dict_row is None:  # pragma: no cover - guard when psycopg missing
            raise RuntimeError("psycopg row_factory is unavailable")

        with self.conn.cursor(row_factory=dict_row) as cur:
            cur.execute(_EVENT_QUERY)
            for row in cur:
                timestamp = row["content_timestamp"]
                if not isinstance(timestamp, datetime):
                    continue
                yield RelationshipEvent(
                    self_person_id=row["self_person_id"],
                    person_id=row["person_id"],
                    timestamp=timestamp,
                    thread_id=row.get("thread_id"),
                    direction=str(row["direction"]),
                    attachment_count=int(row.get("attachment_count") or 0),
                )

    def compute(self, *, now: Optional[datetime] = None) -> Dict[Tuple[UUID, UUID], RelationshipFeatureSummary]:
        feature_map: Dict[Tuple[UUID, UUID], List[RelationshipEvent]] = {}
        for event in self.load_events():
            feature_map.setdefault((event.self_person_id, event.person_id), []).append(event)

        summaries: Dict[Tuple[UUID, UUID], RelationshipFeatureSummary] = {}
        for key, events in feature_map.items():
            try:
                summaries[key] = summarize_events(events, now=now)
            except Exception:  # pragma: no cover - defensive logging
                logger.exception(
                    "relationship_feature_compute_failed",
                    self_person_id=str(key[0]),
                    person_id=str(key[1]),
                    event_count=len(events),
                )
        return summaries

    def persist(self, summaries: Dict[Tuple[UUID, UUID], RelationshipFeatureSummary]) -> int:
        if not summaries:
            return 0
        if Json is None:  # pragma: no cover - guard when psycopg missing
            raise RuntimeError("psycopg Json wrapper is required to persist summaries")

        parameters = []
        for (self_id, person_id), summary in summaries.items():
            edge_payload = summary.as_edge_features()
            parameters.append(
                {
                    "self_person_id": self_id,
                    "person_id": person_id,
                    "score": 0.0,
                    "last_contact_at": summary.last_contact_at,
                    "decay_bucket": summary.decay_bucket,
                    "edge_features": Json(edge_payload),
                }
            )

        sql = """
            INSERT INTO crm_relationships (self_person_id, person_id, score, last_contact_at, decay_bucket, edge_features)
            VALUES (%(self_person_id)s, %(person_id)s, %(score)s, %(last_contact_at)s, %(decay_bucket)s, %(edge_features)s)
            ON CONFLICT (self_person_id, person_id)
            DO UPDATE SET
                last_contact_at = EXCLUDED.last_contact_at,
                decay_bucket = EXCLUDED.decay_bucket,
                edge_features = EXCLUDED.edge_features
        """
        with self.conn.cursor() as cur:
            cur.executemany(sql, parameters)
        logger.info("relationship_features_persisted", count=len(parameters))
        return len(parameters)

    def run(self, *, now: Optional[datetime] = None) -> int:
        summaries = self.compute(now=now)
        return self.persist(summaries)


def run_once(*, now: Optional[datetime] = None) -> int:
    """Helper to run aggregation with managed connection."""
    if psycopg is None:  # pragma: no cover - guard when psycopg missing
        raise RuntimeError("psycopg is required to compute relationship features")

    with get_connection(autocommit=False) as conn:
        aggregator = RelationshipFeatureAggregator(conn)
        try:
            count = aggregator.run(now=now)
            conn.commit()
            return count
        except Exception:
            conn.rollback()
            raise


def main() -> None:  # pragma: no cover - simple CLI wrapper
    setup_logging()
    updated = run_once()
    print(json.dumps({"relationships_updated": updated}))


if __name__ == "__main__":  # pragma: no cover
    main()
