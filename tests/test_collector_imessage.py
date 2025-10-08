import plistlib

import requests

from services.collector import collector_imessage as collector


def _make_archive(text: str) -> bytes:
    return plistlib.dumps(
        {
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": {"root": {"UID": 1}},
            "$objects": [
                "$null",
                {"NS.string": {"UID": 2}},
                text,
            ],
        },
        fmt=plistlib.FMT_BINARY,
    )


def test_decode_attributed_body_returns_string():
    archive = _make_archive("hello world")
    assert collector.decode_attributed_body(archive) == "hello world"


def test_decode_attributed_body_handles_missing():
    assert collector.decode_attributed_body(None) == ""


def _make_event(row_id: int = 1, text: str = "hello") -> collector.SourceEvent:
    now = "2024-01-01T00:00:00Z"
    return collector.SourceEvent(
        doc_id=f"imessage:{row_id}",
        thread={
            "id": "thread-1",
            "kind": "imessage",
            "participants": ["me", "you"],
            "title": "Test",
        },
        message={
            "row_id": row_id,
            "guid": f"guid-{row_id}",
            "thread_id": "thread-1",
            "ts": now,
            "sender": "me",
            "sender_service": "iMessage",
            "is_from_me": True,
            "text": text,
            "attrs": {},
        },
        chunks=[
            {
                "id": collector.deterministic_chunk_id(f"doc-{row_id}", 0),
                "chunk_index": 0,
                "text": text,
                "meta": {"doc_id": f"doc-{row_id}", "ts": now, "thread_id": "thread-1"},
            }
        ],
    )


def test_post_events_success(monkeypatch):
    class DummyResponse:
        status_code = 202
        text = ""

        def raise_for_status(self) -> None:  # pragma: no cover - simple stub
            return None

    payloads: list[dict[str, object]] = []

    def fake_post(url: str, json: dict[str, object], headers: dict[str, str], timeout: int) -> DummyResponse:
        payloads.append(json)
        return DummyResponse()

    monkeypatch.setattr(collector.requests, "post", fake_post)

    assert collector.post_events([_make_event()]) is True
    assert payloads and payloads[0]["items"]


def test_post_events_failure_returns_false(monkeypatch):
    response = requests.Response()
    response.status_code = 501
    response._content = b"Unsupported method ('POST')"  # type: ignore[attr-defined]
    response.url = "http://localhost/v1/catalog/events"
    response.request = requests.Request("POST", response.url).prepare()

    def fake_post(url: str, json: dict[str, object], headers: dict[str, str], timeout: int) -> requests.Response:
        return response

    monkeypatch.setattr(collector.requests, "post", fake_post)
    assert collector.post_events([_make_event()]) is False


def test_process_events_updates_state_on_success(monkeypatch):
    state = collector.CollectorState(last_seen_rowid=5)
    state.save = lambda: None  # type: ignore[assignment]

    def fake_post(events: list[collector.SourceEvent]) -> bool:
        assert len(events) == 1
        return True

    monkeypatch.setattr(collector, "post_events", fake_post)

    assert collector.process_events(state, [_make_event(10)]) is True
    assert state.last_seen_rowid == 10


def test_process_events_preserves_state_on_failure(monkeypatch):
    state = collector.CollectorState(last_seen_rowid=7)
    state.save = lambda: None  # type: ignore[assignment]

    def fake_post(events: list[collector.SourceEvent]) -> bool:
        return False

    monkeypatch.setattr(collector, "post_events", fake_post)
    assert collector.process_events(state, [_make_event(12)]) is False
    assert state.last_seen_rowid == 7
