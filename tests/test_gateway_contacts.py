from __future__ import annotations

from contextlib import contextmanager
from uuid import uuid4

from fastapi.testclient import TestClient

import services.gateway_api.app as gateway_module
from services.gateway_api.app import app as gateway_app
from shared.people_repository import PersonIngestRecord, UpsertStats


def test_contacts_ingest_invokes_repository(monkeypatch):
    gateway_module.settings.catalog_token = None
    called: dict[str, object] = {}

    class DummyRepo:
        def __init__(self, conn, *, default_region=None) -> None:
            called["default_region"] = default_region

        def upsert_batch(self, source: str, records: list[PersonIngestRecord]) -> UpsertStats:
            called["source"] = source
            called["records"] = records
            return UpsertStats(accepted=len(records), upserts=len(records), deletes=0, conflicts=0, skipped=0)

    @contextmanager
    def fake_connection(*args, **kwargs):
        class DummyConn:
            def commit(self) -> None:
                called["committed"] = True

            def rollback(self) -> None:
                called["rolled_back"] = True

        yield DummyConn()

    def fake_update_change_token(conn, source, device_id, token):
        called["token"] = token

    monkeypatch.setattr(gateway_module, "PeopleRepository", DummyRepo)
    monkeypatch.setattr(gateway_module, "get_connection", fake_connection)
    monkeypatch.setattr(gateway_module, "_update_change_token", fake_update_change_token)

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
    assert called["source"] == "macos_contacts"
    assert called["token"] == "cursor-1"
    assert called.get("committed") is True
    records = called["records"]
    assert len(records) == 1
    assert records[0].change_token == "cursor-1"


def test_people_search_uses_facets(monkeypatch):
    gateway_module.settings.api_token = ""

    person_id = uuid4()
    rows = [
        {
            "person_id": person_id,
            "display_name": "Alice Smith",
            "given_name": "Alice",
            "family_name": "Smith",
            "organization": "Acme",
            "nicknames": ["Al"],
            "identifiers": [
                {
                    "kind": "email",
                    "value_canonical": "alice@example.com",
                    "value_raw": "Alice@Example.com",
                    "label": "work",
                },
                {
                    "kind": "phone",
                    "value_canonical": "+15085551234",
                    "value_raw": "(508) 555-1234",
                    "label": "mobile",
                },
            ],
            "addresses": [
                {"label": "home", "city": "Boston", "region": "MA", "country": "US"}
            ],
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
    assert "person_identifiers" in executed["sql"]
