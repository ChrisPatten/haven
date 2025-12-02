"""Tests for metadata preservation in gateway ingest pipeline.

These tests ensure that:
1. Original iMessage metadata structure is preserved
2. People data is correctly extracted and passed through
3. Thread data is correctly extracted and passed through
"""

from __future__ import annotations

import json
from typing import Any, Dict

from fastapi import status
from fastapi.testclient import TestClient

from services.gateway_api import app as gateway_app


def test_gateway_preserves_original_imessage_metadata(monkeypatch):
    """Test that gateway extracts and uses original metadata from headers."""
    original_token = gateway_app.settings.catalog_token
    gateway_app.settings.catalog_token = None

    calls: Dict[str, Dict[str, Any]] = {}

    class DummyResponse:
        def __init__(self, status_code: int = 202, payload: Dict[str, Any] | None = None) -> None:
            self.status_code = status_code
            self._payload = payload or {
                "submission_id": "sub-1",
                "status": "embedding_pending",
                "doc_id": "doc-1",
                "total_chunks": 2,
                "duplicate": False,
            }

        def json(self) -> Dict[str, Any]:
            return self._payload

        @property
        def text(self) -> str:
            return "ok"

    class DummyAsyncClient:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def __aenter__(self) -> "DummyAsyncClient":
            return self

        async def __aexit__(self, exc_type, exc, tb) -> bool:
            return False

        async def request(self, method: str, path: str, json=None, headers=None):
            calls["request"] = {"method": method, "path": path, "json": json, "headers": headers}
            return DummyResponse()

    monkeypatch.setattr(gateway_app.httpx, "AsyncClient", DummyAsyncClient)

    # Original iMessage metadata structure
    original_metadata = {
        "timestamps": {
            "primary": {
                "value": "2025-11-26T12:00:00+00:00",
                "type": "sent"
            },
            "source_specific": {
                "sent_at": "2025-11-26T12:00:00+00:00"
            }
        },
        "source": {
            "imessage": {
                "chat_guid": "any;+;chat123456789",
                "handle_id": 123,
                "service": "iMessage",
                "row_id": 456
            }
        },
        "type": {
            "kind": "imessage",
            "imessage": {
                "direction": "outgoing",
                "is_group": True
            }
        }
    }

    # Email-style metadata with original metadata in headers
    email_style_metadata = {
        "headers": {
            "_original_metadata": json.dumps(original_metadata)
        },
        "subject": "Test Thread",
        "snippet": "Test message",
        "has_attachments": False,
        "attachment_count": 0,
        "content_hash": "test-hash",
        "references": [],
        "body_processed": True
    }

    try:
        with TestClient(gateway_app.app) as client:
            response = client.post(
                "/v1/ingest",
                json={
                    "source_type": "imessage",
                    "source_id": "imessage:test-guid",
                    "content": {"mime_type": "text/plain", "data": "Hello world"},
                    "metadata": email_style_metadata,
                },
                headers={"Authorization": "Bearer changeme"},
            )
    finally:
        gateway_app.settings.catalog_token = original_token
        gateway_app._search_client = None

    assert response.status_code == 202

    # Verify the original metadata was extracted and used
    request_details = calls["request"]
    forwarded_json = request_details["json"]
    forwarded_metadata = forwarded_json["metadata"]

    # Should have original iMessage structure, not email-style
    assert "source" in forwarded_metadata
    assert "imessage" in forwarded_metadata["source"]
    assert forwarded_metadata["source"]["imessage"]["chat_guid"] == "any;+;chat123456789"
    assert forwarded_metadata["source"]["imessage"]["service"] == "iMessage"
    assert "type" in forwarded_metadata
    assert forwarded_metadata["type"]["kind"] == "imessage"

    # Should NOT have email-style fields as top-level
    assert "headers" not in forwarded_metadata or "_original_metadata" not in forwarded_metadata.get("headers", {})


def test_gateway_preserves_people_data(monkeypatch):
    """Test that people data is correctly extracted and passed through."""
    original_token = gateway_app.settings.catalog_token
    gateway_app.settings.catalog_token = None

    calls: Dict[str, Dict[str, Any]] = {}

    class DummyResponse:
        def __init__(self, status_code: int = 202, payload: Dict[str, Any] | None = None) -> None:
            self.status_code = status_code
            self._payload = payload or {
                "submission_id": "sub-1",
                "status": "embedding_pending",
                "doc_id": "doc-1",
                "total_chunks": 2,
                "duplicate": False,
            }

        def json(self) -> Dict[str, Any]:
            return self._payload

        @property
        def text(self) -> str:
            return "ok"

    class DummyAsyncClient:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def __aenter__(self) -> "DummyAsyncClient":
            return self

        async def __aexit__(self, exc_type, exc, tb) -> bool:
            return False

        async def request(self, method: str, path: str, json=None, headers=None):
            calls["request"] = {"method": method, "path": path, "json": json, "headers": headers}
            return DummyResponse()

    monkeypatch.setattr(gateway_app.httpx, "AsyncClient", DummyAsyncClient)

    people_data = [
        {
            "identifier": "+1234567890",
            "identifier_type": "phone",
            "role": "sender"
        },
        {
            "identifier": "+0987654321",
            "identifier_type": "phone",
            "role": "recipient"
        }
    ]

    try:
        with TestClient(gateway_app.app) as client:
            response = client.post(
                "/v1/ingest",
                json={
                    "source_type": "imessage",
                    "source_id": "imessage:test-guid",
                    "content": {"mime_type": "text/plain", "data": "Hello world"},
                    "metadata": {},
                    "people": people_data,
                },
                headers={"Authorization": "Bearer changeme"},
            )
    finally:
        gateway_app.settings.catalog_token = original_token
        gateway_app._search_client = None

    assert response.status_code == 202

    # Verify people data was passed through
    request_details = calls["request"]
    forwarded_json = request_details["json"]
    forwarded_people = forwarded_json["people"]

    assert len(forwarded_people) == 2
    assert forwarded_people[0]["identifier"] == "+1234567890"
    assert forwarded_people[0]["role"] == "sender"
    assert forwarded_people[1]["identifier"] == "+0987654321"
    assert forwarded_people[1]["role"] == "recipient"


def test_gateway_preserves_thread_data(monkeypatch):
    """Test that thread data is correctly extracted and passed through."""
    original_token = gateway_app.settings.catalog_token
    gateway_app.settings.catalog_token = None

    calls: Dict[str, Dict[str, Any]] = {}

    class DummyResponse:
        def __init__(self, status_code: int = 202, payload: Dict[str, Any] | None = None) -> None:
            self.status_code = status_code
            self._payload = payload or {
                "submission_id": "sub-1",
                "status": "embedding_pending",
                "doc_id": "doc-1",
                "total_chunks": 2,
                "duplicate": False,
                "thread_id": "550e8400-e29b-41d4-a716-446655440000",
            }

        def json(self) -> Dict[str, Any]:
            return self._payload

        @property
        def text(self) -> str:
            return "ok"

    class DummyAsyncClient:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def __aenter__(self) -> "DummyAsyncClient":
            return self

        async def __aexit__(self, exc_type, exc, tb) -> bool:
            return False

        async def request(self, method: str, path: str, json=None, headers=None):
            calls["request"] = {"method": method, "path": path, "json": json, "headers": headers}
            return DummyResponse()

    monkeypatch.setattr(gateway_app.httpx, "AsyncClient", DummyAsyncClient)

    thread_data = {
        "external_id": "imessage:any;+;chat123456789",
        "source_type": "imessage",
        "source_provider": "apple_messages",
        "source_account_id": "E:test@example.com",
        "title": "Test Thread",
        "participants": [
            {
                "identifier": "+1234567890",
                "identifier_type": "phone",
                "role": "participant"
            }
        ],
        "metadata": {
            "chat_guid": "any;+;chat123456789"
        }
    }

    try:
        with TestClient(gateway_app.app) as client:
            response = client.post(
                "/v1/ingest",
                json={
                    "source_type": "imessage",
                    "source_id": "imessage:test-guid",
                    "content": {"mime_type": "text/plain", "data": "Hello world"},
                    "metadata": {},
                    "thread": thread_data,
                },
                headers={"Authorization": "Bearer changeme"},
            )
    finally:
        gateway_app.settings.catalog_token = original_token
        gateway_app._search_client = None

    assert response.status_code == 202

    # Verify thread data was passed through
    request_details = calls["request"]
    forwarded_json = request_details["json"]
    forwarded_thread = forwarded_json["thread"]

    assert forwarded_thread["external_id"] == "imessage:any;+;chat123456789"
    assert forwarded_thread["source_type"] == "imessage"
    assert forwarded_thread["title"] == "Test Thread"
    assert len(forwarded_thread["participants"]) == 1
    assert forwarded_thread["participants"][0]["identifier"] == "+1234567890"

