from __future__ import annotations

from contextlib import contextmanager
from uuid import uuid4

from fastapi import status
from fastapi.testclient import TestClient

import services.gateway_api.app as gateway_module
from services.gateway_api.app import app as gateway_app


def test_contacts_ingest_posts_documents(monkeypatch):
    gateway_module.settings.catalog_token = None
    captured: dict[str, object] = {"requests": []}

    class DummyResponse:
        def __init__(self, status_code: int, payload: dict[str, object]):
            self.status_code = status_code
            self._payload = payload
            self.text = ""

        def json(self) -> dict[str, object]:
            return self._payload

    def fake_catalog_sync_request(method: str, path: str, correlation_id: str, *, json_payload=None):
        captured["requests"].append(
            {"method": method, "path": path, "payload": json_payload, "correlation_id": correlation_id}
        )
        return DummyResponse(status.HTTP_202_ACCEPTED, {"duplicate": False})

    @contextmanager
    def fake_connection(*args, **kwargs):
        class DummyConn:
            def commit(self) -> None:
                captured["committed"] = True

            def rollback(self) -> None:
                captured["rolled_back"] = True

        yield DummyConn()

    def fake_update_change_token(conn, source, device_id, token):
        captured["token"] = token

    monkeypatch.setattr(gateway_module, "_catalog_sync_request", fake_catalog_sync_request)
    monkeypatch.setattr(gateway_module, "get_connection", fake_connection)
    monkeypatch.setattr(gateway_module, "_update_change_token", fake_update_change_token)
    monkeypatch.setattr(gateway_module, "get_active_document", lambda external_id: None)

    client = TestClient(gateway_app)

    payload = {
        "source": "macos_contacts",
        "device_id": "device-1",
        "since_token": "prev",
        "batch_id": "batch-1",
        "people": [
            {
                "external_id": "CN_1",
                "display_name": "Alice Smith",
                "phones": [
                    {"value": "+15085551234", "value_raw": "(508) 555-1234", "label": "mobile"}
                ],
                "emails": [
                    {"value": "alice@example.com", "value_raw": "Alice@Example.com", "label": "work"}
                ],
                "change_token": "cursor-1",
            }
        ],
    }

    response = client.post("/catalog/contacts/ingest", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert data == {
        "accepted": 1,
        "upserts": 1,
        "deletes": 0,
        "conflicts": 0,
        "skipped": 0,
        "since_token_next": "cursor-1",
    }
    assert captured["token"] == "cursor-1"
    assert captured.get("committed") is True
    request_payload = captured["requests"][0]["payload"]
    assert request_payload["source_type"] == "contact"
    assert request_payload["people"][0]["identifier_type"] == "email"
    assert request_payload["metadata"]["contact"]["display_name"] == "Alice Smith"


def test_people_search_reads_contact_documents(monkeypatch):
    gateway_module.settings.api_token = ""

    doc_id = uuid4()
    metadata = {
        "contact": {
            "display_name": "Alice Smith",
            "given_name": "Alice",
            "family_name": "Smith",
            "organization": "Acme",
            "nicknames": ["Al"],
            "emails": [{"value": "alice@example.com", "label": "work"}],
            "phones": [{"value": "+15085551234", "label": "mobile"}],
            "addresses": [{"label": "home", "city": "Boston", "region": "MA", "country": "US"}],
        }
    }

    rows = [
        {
            "doc_id": doc_id,
            "title": "Alice Smith",
            "metadata": metadata,
            "people": [],
            "text": "Alice Smith\nEmail: alice@example.com",
        }
    ]

    executed: dict[str, object] = {}

    class DummyCursor:
        def __init__(self, result_rows):
            self.result_rows = result_rows

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def execute(self, sql, params):
            executed["sql"] = sql
            executed["params"] = params

        def fetchall(self):
            return self.result_rows

    class DummyConn:
        def cursor(self, row_factory=None):
            executed["row_factory"] = row_factory
            return DummyCursor(rows)

    @contextmanager
    def fake_connection(*args, **kwargs):
        yield DummyConn()

    monkeypatch.setattr(gateway_module, "get_connection", fake_connection)

    client = TestClient(gateway_app)
    response = client.get("/search/people", params={"q": "Alice", "facets[label]": "mobile"})
    assert response.status_code == 200
    data = response.json()
    assert data["results"][0]["emails"] == ["alice@example.com"]
    assert data["results"][0]["phones"] == ["+15085551234"]
    assert executed["row_factory"].__name__ == "dict_row"
    assert "FROM documents" in executed["sql"]
