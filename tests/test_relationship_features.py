from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from services.search_service.relationship_features import RelationshipEvent, summarize_events


def make_event(
    *,
    self_person_id=None,
    person_id=None,
    timestamp: datetime,
    direction: str,
    thread_id=None,
    attachment_count: int = 0,
) -> RelationshipEvent:
    return RelationshipEvent(
        self_person_id=self_person_id or uuid4(),
        person_id=person_id or uuid4(),
        timestamp=timestamp,
        thread_id=thread_id,
        direction=direction,
        attachment_count=attachment_count,
    )


def test_summarize_events_basic_metrics():
    now = datetime(2024, 7, 1, tzinfo=UTC)
    self_id = uuid4()
    other_id = uuid4()
    thread_a = uuid4()
    thread_b = uuid4()

    events = [
        make_event(
            self_person_id=self_id,
            person_id=other_id,
            timestamp=now - timedelta(days=10),
            direction="inbound",
            thread_id=thread_a,
            attachment_count=1,
        ),
        make_event(
            self_person_id=self_id,
            person_id=other_id,
            timestamp=now - timedelta(days=9),
            direction="outbound",
            thread_id=thread_a,
        ),
        make_event(
            self_person_id=self_id,
            person_id=other_id,
            timestamp=now - timedelta(days=5),
            direction="inbound",
            thread_id=thread_b,
            attachment_count=2,
        ),
        make_event(
            self_person_id=self_id,
            person_id=other_id,
            timestamp=now - timedelta(hours=6),
            direction="outbound",
            thread_id=thread_b,
            attachment_count=1,
        ),
    ]

    summary = summarize_events(events, now=now)

    assert summary.messages_30d == 4
    assert summary.attachments_30d == 4
    assert summary.distinct_threads_90d == 2
    assert summary.last_contact_at == events[-1].timestamp
    assert summary.decay_bucket == 0

    expected_latency = (1 * 86400 + 4.75 * 86400) / 2
    assert summary.avg_reply_latency_seconds == pytest.approx(expected_latency, rel=1e-6)


def test_summarize_events_requires_events():
    with pytest.raises(ValueError):
        summarize_events([])
