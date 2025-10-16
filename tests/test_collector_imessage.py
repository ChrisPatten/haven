import plistlib

import requests

from scripts.collectors import collector_imessage as collector


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
    assert payloads and payloads[0]["content"]["data"] == "hello"
    assert payloads[0]["metadata"]["message"]["text"] == "hello"


def test_post_events_failure_returns_false(monkeypatch):
    class ErrorResponse:
        status_code = 500
        text = "error"

        def raise_for_status(self) -> None:
            raise requests.HTTPError(response=self)

    def fake_post(url: str, json: dict[str, object], headers: dict[str, str], timeout: int) -> ErrorResponse:
        return ErrorResponse()

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


def test_compute_sleep_from_inactivity_short():
    # Activity 30s ago -> use base poll interval
    sleep = collector.compute_sleep_from_inactivity(30, base=5, max_sleep=60)
    assert sleep == 5


def test_compute_sleep_from_inactivity_mid_ramp():
    # 2 minutes after activity => 60s of inactivity beyond first minute -> ramp_progress = 60/300 = 0.2
    inactivity = 120
    sleep = collector.compute_sleep_from_inactivity(inactivity, base=5, max_sleep=60)
    expected = 5 + 0.2 * (60 - 5)
    assert abs(sleep - expected) < 1e-6


def test_compute_sleep_from_inactivity_maxed():
    # Long inactivity should cap at max_sleep
    sleep = collector.compute_sleep_from_inactivity(60 * 10, base=5, max_sleep=60)
    assert sleep == 60


def test_is_image_attachment_detects_extension():
    assert collector._is_image_attachment({"transfer_name": "photo.JPG"}) is True
    assert collector._is_image_attachment({"mime_type": "text/plain"}) is False


def test_build_attachment_chunk_text_combines_parts():
    attachment = {
        "image": {
            "caption": "A mountain vista",
            "ocr_text": "Trailhead elevation 8200ft",
            "ocr_entities": {"dates": ["2024-01-01"], "urls": []},
        }
    }
    chunk_text = collector._build_attachment_chunk_text(attachment)
    assert "Image caption: A mountain vista" in chunk_text
    assert "OCR text: Trailhead elevation 8200ft" in chunk_text
    assert "dates: 2024-01-01" in chunk_text


def test_normalize_row_includes_image_enrichment(monkeypatch):
    row = {
        "text": "",
        "attributed_body": None,
        "attachment_count": 1,
        "guid": "guid-1",
        "chat_guid": "chat-1",
        "chat_display_name": "Chat",
        "ROWID": 42,
        "date": None,
        "is_from_me": 1,
        "handle_id": None,
        "service": "iMessage",
    }

    attachments = [{"row_id": 99}]
    enriched = [
        {
            "row_id": 99,
            "guid": "attach-guid",
            "mime_type": "image/png",
            "transfer_name": "photo.png",
            "uti": "public.png",
            "total_bytes": 1024,
            "image": {
                "caption": "A cat on a sofa",
                "ocr_text": "meow",
                "ocr_boxes": [],
                "ocr_entities": {"urls": ["https://example.com"]},
                "blob_id": "hash-123",
            },
        }
    ]

    monkeypatch.setattr(
        collector,
        "enrich_image_attachments",
        lambda _attachments, thread_id, message_guid: (
            enriched,
            [
                {
                    "source": "imessage",
                    "kind": "image",
                    "thread_id": thread_id,
                    "message_id": message_guid,
                    "blob_id": "hash-123",
                    "caption": "A cat on a sofa",
                    "ocr_text": "meow",
                    "entities": {"urls": ["https://example.com"]},
                    "facets": {"urls": ["https://example.com"], "has_text": False},
                }
            ],
        ),
    )

    event = collector.normalize_row(row, participants=["me"], attachments=attachments)

    assert event.message["attachments"] == enriched
    assert len(event.chunks) == 2
    assert "Image caption: A cat on a sofa" in event.chunks[1]["text"]
    assert event.chunks[1]["meta"]["attachment_row_id"] == 99
    assert event.message["attrs"]["image_captions"] == ["A cat on a sofa"]
    assert event.message["attrs"]["image_blob_ids"] == ["hash-123"]
    assert event.image_events[0]["blob_id"] == "hash-123"
    # Verify that the caption and OCR text are now also included in the main message text
    assert event.message["text"] == "[Image: A cat on a sofa] [OCR: meow]"
    assert event.chunks[0]["text"] == "[Image: A cat on a sofa] [OCR: meow]"


def test_normalize_row_appends_captions_to_existing_text(monkeypatch):
    """Test that captions and OCR text are appended to existing message text."""
    row = {
        "text": "Check out this photo!",
        "attributed_body": None,
        "attachment_count": 1,
        "guid": "guid-2",
        "chat_guid": "chat-2",
        "chat_display_name": "Chat",
        "ROWID": 43,
        "date": None,
        "is_from_me": 1,
        "handle_id": None,
        "service": "iMessage",
    }

    attachments = [{"row_id": 100}]
    enriched = [
        {
            "row_id": 100,
            "guid": "attach-guid-2",
            "mime_type": "image/jpeg",
            "transfer_name": "sunset.jpg",
            "uti": "public.jpeg",
            "total_bytes": 2048,
            "image": {
                "caption": "Beautiful sunset over the ocean",
                "ocr_text": "Golden Gate Bridge",
                "ocr_boxes": [],
                "ocr_entities": {},
                "blob_id": "hash-456",
            },
        }
    ]

    monkeypatch.setattr(
        collector,
        "enrich_image_attachments",
        lambda _attachments, thread_id, message_guid: (
            enriched,
            [
                {
                    "source": "imessage",
                    "kind": "image",
                    "thread_id": thread_id,
                    "message_id": message_guid,
                    "blob_id": "hash-456",
                    "caption": "Beautiful sunset over the ocean",
                    "ocr_text": "Golden Gate Bridge",
                    "entities": {},
                    "facets": {"has_text": False},
                }
            ],
        ),
    )

    event = collector.normalize_row(row, participants=["me", "you"], attachments=attachments)

    # Verify caption and OCR text are both appended to the existing text
    expected_text = "Check out this photo! [Image: Beautiful sunset over the ocean] [OCR: Golden Gate Bridge]"
    assert event.message["text"] == expected_text
    assert event.chunks[0]["text"] == expected_text
    assert event.message["attrs"]["image_captions"] == ["Beautiful sunset over the ocean"]
    assert event.message["attrs"]["image_ocr_text"] == ["Golden Gate Bridge"]


def test_normalize_row_includes_ocr_without_caption(monkeypatch):
    """Test that OCR text is included even when there's no caption."""
    row = {
        "text": "",
        "attributed_body": None,
        "attachment_count": 1,
        "guid": "guid-3",
        "chat_guid": "chat-3",
        "chat_display_name": "Chat",
        "ROWID": 44,
        "date": None,
        "is_from_me": 0,
        "handle_id": "+1234567890",
        "service": "iMessage",
    }

    attachments = [{"row_id": 101}]
    enriched = [
        {
            "row_id": 101,
            "guid": "attach-guid-3",
            "mime_type": "image/png",
            "transfer_name": "screenshot.png",
            "uti": "public.png",
            "total_bytes": 512,
            "image": {
                "caption": "",  # No caption generated
                "ocr_text": "Error 404: Page not found",
                "ocr_boxes": [],
                "ocr_entities": {},
                "blob_id": "hash-789",
            },
        }
    ]

    monkeypatch.setattr(
        collector,
        "enrich_image_attachments",
        lambda _attachments, thread_id, message_guid: (
            enriched,
            [
                {
                    "source": "imessage",
                    "kind": "image",
                    "thread_id": thread_id,
                    "message_id": message_guid,
                    "blob_id": "hash-789",
                    "caption": "",
                    "ocr_text": "Error 404: Page not found",
                    "entities": {},
                    "facets": {"has_text": False},
                }
            ],
        ),
    )

    event = collector.normalize_row(row, participants=["+1234567890", "me"], attachments=attachments)

    # Verify OCR text is used even without caption
    assert event.message["text"] == "[OCR: Error 404: Page not found]"
    assert event.chunks[0]["text"] == "[OCR: Error 404: Page not found]"
    assert event.message["attrs"]["image_ocr_text"] == ["Error 404: Page not found"]
    # No captions should be in attrs since none were generated
    assert "image_captions" not in event.message["attrs"]


def test_image_enrichment_cache_round_trip(tmp_path):
    cache_path = tmp_path / "cache.json"
    cache = collector.ImageEnrichmentCache(cache_path)
    assert cache.get("abc") is None
    cache.set("abc", {"caption": "hello"})
    cache.save()

    cache_reload = collector.ImageEnrichmentCache(cache_path)
    assert cache_reload.get("abc") == {"caption": "hello"}


def test_parse_time_bound_hours():
    from datetime import timedelta
    result = collector.parse_time_bound("12h")
    assert result == timedelta(hours=12)


def test_parse_time_bound_days():
    from datetime import timedelta
    result = collector.parse_time_bound("5d")
    assert result == timedelta(days=5)


def test_parse_time_bound_minutes():
    from datetime import timedelta
    result = collector.parse_time_bound("30m")
    assert result == timedelta(minutes=30)


def test_parse_time_bound_seconds():
    from datetime import timedelta
    result = collector.parse_time_bound("3600s")
    assert result == timedelta(seconds=3600)


def test_parse_time_bound_decimal():
    from datetime import timedelta
    result = collector.parse_time_bound("1.5h")
    assert result == timedelta(hours=1.5)


def test_parse_time_bound_invalid_unit():
    import pytest
    with pytest.raises(ValueError, match="Invalid time unit"):
        collector.parse_time_bound("12x")


def test_parse_time_bound_invalid_format():
    import pytest
    with pytest.raises(ValueError, match="Invalid time bound format"):
        collector.parse_time_bound("abch")


def test_parse_time_bound_negative():
    import pytest
    with pytest.raises(ValueError, match="Time bound must be positive"):
        collector.parse_time_bound("-5d")


def test_parse_time_bound_empty():
    import pytest
    with pytest.raises(ValueError, match="Time bound cannot be empty"):
        collector.parse_time_bound("")


def test_datetime_to_apple_epoch():
    from datetime import datetime, timezone
    # Test with a known date: 2001-01-02 (one day after Apple epoch)
    dt = datetime(2001, 1, 2, 0, 0, 0, tzinfo=timezone.utc)
    result = collector.datetime_to_apple_epoch(dt)
    # One day in nanoseconds = 24 * 60 * 60 * 1_000_000_000
    expected = 86400 * 1_000_000_000
    assert result == expected


def test_datetime_to_apple_epoch_at_epoch():
    from datetime import datetime, timezone
    # Test at Apple epoch
    dt = datetime(2001, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
    result = collector.datetime_to_apple_epoch(dt)
    assert result == 0
