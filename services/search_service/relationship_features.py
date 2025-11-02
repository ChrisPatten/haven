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
    thread_participant_count: int = 1


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
        payload["avg_reply_latency_seconds"] = (
            round(self.avg_reply_latency_seconds, 2) if self.avg_reply_latency_seconds is not None else None
        )
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


def _reciprocal_counts_within(
    events: List[RelationshipEvent], since: datetime, reciprocal_window: timedelta
) -> tuple[int, int]:
    """Count messages and attachments within a window but only when the other party
    also posts in the same thread within +/- reciprocal_window of a message.

    This reduces inflation from broadcast/group messages where the two people
    are not interacting directly.
    Returns (message_count, attachment_count).
    """
    # Group events by thread_id (None-treated separately)
    thread_map: dict[Optional[UUID], List[RelationshipEvent]] = {}
    for evt in events:
        thread_map.setdefault(evt.thread_id, []).append(evt)

    msg_count = 0
    att_count = 0

    for thread_id, t_events in thread_map.items():
        # Sort events for the thread
        sorted_evts = sorted(t_events, key=lambda e: e.timestamp)

        # Determine participant count for the thread (all events in the thread share this)
        pcount = sorted_evts[0].thread_participant_count if sorted_evts else 0

        # If thread_id is None or only two people in the thread, treat as direct messages and count normally
        if thread_id is None or pcount <= 2:
            for e in sorted_evts:
                if e.timestamp >= since:
                    msg_count += 1
                    att_count += max(e.attachment_count, 0)
            continue

        # For threads with an id (possibly group chats), count an event only if
        # there exists at least one event from the opposite direction within
        # reciprocal_window of the event timestamp.
        for i, e in enumerate(sorted_evts):
            if e.timestamp < since:
                continue
            # look for any event in the thread with opposite direction within window
            lo = e.timestamp - reciprocal_window
            hi = e.timestamp + reciprocal_window
            reciprocal_found = False
            # Scan nearby events (small lists; scanning full thread acceptable)
            for other in sorted_evts:
                if other is e:
                    continue
                if other.direction == e.direction:
                    continue
                if lo <= other.timestamp <= hi:
                    reciprocal_found = True
                    break
            if reciprocal_found:
                msg_count += 1
                att_count += max(e.attachment_count, 0)

    return msg_count, att_count


def _messages_within(events: Iterable[RelationshipEvent], since: datetime) -> int:
    return sum(1 for event in events if event.timestamp >= since)


def _distinct_threads_within(events: Iterable[RelationshipEvent], since: datetime) -> int:
    threads = {evt.thread_id for evt in events if evt.thread_id and evt.timestamp >= since}
    return len(threads)


def _compute_relationship_score(summary: RelationshipFeatureSummary) -> float:
    """
    Compute relationship strength score from feature summary.
    
    Score is based on:
    - Recency: contacts with recent messages score higher
    - Frequency: more messages in 30d boost score
    - Depth: more distinct threads in 90d boost score
    - Engagement: attachments indicate richer communication
    
    Returns a score roughly 0.0-100.0 where higher = stronger relationship.
    """
    score = 0.0
    
    # Recency boost: strong weight on how recently we've communicated
    # If last contact was today: +50, this week: +40, this month: +20, etc.
    if summary.days_since_last_message < 1:
        score += 50.0
    elif summary.days_since_last_message < 3:
        score += 45.0
    elif summary.days_since_last_message < 7:
        score += 40.0
    elif summary.days_since_last_message < 14:
        score += 30.0
    elif summary.days_since_last_message < 30:
        score += 20.0
    elif summary.days_since_last_message < 90:
        score += 10.0
    else:
        score += 2.0  # minimal score for old contacts
    
    # Frequency boost: messages in last 30 days
    # 1+ msg = +5, 5+ msgs = +10, 20+ msgs = +15, 50+ msgs = +20
    if summary.messages_30d >= 50:
        score += 20.0
    elif summary.messages_30d >= 20:
        score += 15.0
    elif summary.messages_30d >= 5:
        score += 10.0
    elif summary.messages_30d >= 1:
        score += 5.0
    
    # Depth boost: distinct threads (indicates ongoing relationship across topics)
    # Each thread beyond first adds a small amount
    if summary.distinct_threads_90d >= 3:
        score += 15.0
    elif summary.distinct_threads_90d >= 2:
        score += 8.0
    elif summary.distinct_threads_90d >= 1:
        score += 3.0
    
    # Engagement boost: attachments indicate richer communication
    if summary.attachments_30d >= 5:
        score += 10.0
    elif summary.attachments_30d >= 2:
        score += 5.0
    elif summary.attachments_30d >= 1:
        score += 2.0
    
    # Reply latency penalty: slower replies indicate less engaged relationship
    if summary.avg_reply_latency_seconds is not None:
        hours_to_reply = summary.avg_reply_latency_seconds / 3600.0
        if hours_to_reply > 48:
            score *= 0.8  # slow responder
        elif hours_to_reply > 24:
            score *= 0.9  # somewhat slow
        # fast responders get no penalty
    
    return min(score, 100.0)  # cap at 100


def summarize_events(events: List[RelationshipEvent], *, now: Optional[datetime] = None) -> RelationshipFeatureSummary:
    if not events:
        raise ValueError("summarize_events requires at least one event")

    effective_now = now or _default_now()
    ordered = sorted(events, key=lambda evt: evt.timestamp)

    last_contact = ordered[-1].timestamp
    base_delta = effective_now - last_contact
    days_since_last = base_delta.total_seconds() / 86400.0

    thirty_days_ago = effective_now - timedelta(days=30)
    ninety_days_ago = effective_now - timedelta(days=90)
    # Reciprocal window: consider replies/interaction within 48 hours in group threads
    reciprocal_window = timedelta(hours=48)
    messages_30d, attachments_30d = _reciprocal_counts_within(ordered, thirty_days_ago, reciprocal_window)
    distinct_threads_90d = _distinct_threads_within(ordered, ninety_days_ago)

    latencies: List[float] = []
    previous: Optional[RelationshipEvent] = None
    for event in ordered:
        if previous and previous.direction == "inbound" and event.direction == "outbound":
            latencies.append((event.timestamp - previous.timestamp).total_seconds())
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
        COALESCE(t.participant_count, 1) AS thread_participant_count,
        sender.person_id AS sender_person_id,
        recipient.person_id AS recipient_person_id
    FROM documents d
    LEFT JOIN (
        SELECT d2.thread_id, COUNT(DISTINCT dp.person_id) AS participant_count
        FROM documents d2
        JOIN document_people dp ON dp.doc_id = d2.doc_id
        WHERE d2.thread_id IS NOT NULL
        GROUP BY d2.thread_id
    ) t ON t.thread_id = d.thread_id
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
        CASE WHEN b.has_attachments THEN b.attachment_count ELSE 0 END AS attachment_count,
        b.thread_participant_count
    FROM base b
    UNION ALL
    SELECT
        b.recipient_person_id AS self_person_id,
        b.sender_person_id AS person_id,
        'inbound'::text AS direction,
        b.content_timestamp,
        b.thread_id,
        CASE WHEN b.has_attachments THEN b.attachment_count ELSE 0 END AS attachment_count,
        b.thread_participant_count
    FROM base b
)
SELECT
    self_person_id,
    person_id,
    direction,
    content_timestamp,
    thread_id,
    attachment_count
    , thread_participant_count
FROM events
WHERE self_person_id <> person_id
ORDER BY self_person_id, person_id, content_timestamp
"""


class RelationshipFeatureAggregator:
    """Loads message interactions from Postgres and persists aggregated relationship features."""

    def __init__(self, conn: Any) -> None:
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
                    thread_participant_count=int(row.get("thread_participant_count") or 1),
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

        payloads = []
        for (self_id, person_id), summary in summaries.items():
            payloads.append(
                {
                    "self_person_id": self_id,
                    "person_id": person_id,
                    "score": _compute_relationship_score(summary),
                    "last_contact_at": summary.last_contact_at,
                    "decay_bucket": summary.decay_bucket,
                    "edge_features": Json(summary.as_edge_features()),
                }
            )

        sql = """
            INSERT INTO crm_relationships (self_person_id, person_id, score, last_contact_at, decay_bucket, edge_features)
            VALUES (%(self_person_id)s, %(person_id)s, %(score)s, %(last_contact_at)s, %(decay_bucket)s, %(edge_features)s)
            ON CONFLICT (self_person_id, person_id)
            DO UPDATE SET
                score = EXCLUDED.score,
                last_contact_at = EXCLUDED.last_contact_at,
                decay_bucket = EXCLUDED.decay_bucket,
                edge_features = EXCLUDED.edge_features,
                updated_at = NOW()
        """
        with self.conn.cursor() as cur:
            cur.executemany(sql, payloads)
        logger.info("relationship_features_persisted", count=len(payloads))
        return len(payloads)

    def run(self, *, now: Optional[datetime] = None) -> int:
        summaries = self.compute(now=now)
        return self.persist(summaries)


def run_once(*, now: Optional[datetime] = None) -> int:
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
