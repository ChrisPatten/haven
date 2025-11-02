from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone

from fastapi.testclient import TestClient

import services.gateway_api.app as gateway_module
from services.gateway_api.app import app as gateway_app


def test_get_top_relationships_filters_and_returns_metadata(monkeypatch):
    gateway_module.settings.api_token = ""

    rows = [
        {
            "person_id": "5b7b8c6e-8c1e-4f5d-9b6c-1234567890ab",
            "score": 42.5,
            "last_contact_at": datetime(2025, 1, 15, 12, 0, tzinfo=timezone.utc),
            "display_name": "Alice Smith",
            "organization": "Acme Corp",
            "emails": ["alice@example.com"],
            "phones": ["+15085551234"],
        }
    ]
    count_row = {"cnt": 1}

    executed = {"sql": [], "params": [], "row_factory": None}

    class DummyCursor:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def execute(self, sql, params):
            executed["sql"].append(sql)
            executed["params"].append(list(params))

        def fetchall(self):
            return rows

        def fetchone(self):
            return count_row

    class DummyConn:
        def cursor(self, row_factory=None):
            executed["row_factory"] = row_factory
            return DummyCursor()

    @contextmanager
    def fake_connection(*args, **kwargs):
        yield DummyConn()

    monkeypatch.setattr(gateway_module, "get_connection", fake_connection)
    monkeypatch.setattr(gateway_module, "get_self_person_id_from_settings", lambda conn: None)

    client = TestClient(gateway_app)

    response = client.get(
        "/v1/crm/relationships/top",
        params={
            "window": "30d",
            "limit": 25,
            "self_person_id": "11111111-1111-1111-1111-111111111111",
        },
    )

    assert response.status_code == 200
    data = response.json()
    assert data["window"] == "30d"
    assert data["limit"] == 25
    assert data["total_count"] == 1
    assert len(data["relationships"]) == 1

    relationship = data["relationships"][0]
    assert relationship["person_id"] == "5b7b8c6e-8c1e-4f5d-9b6c-1234567890ab"
    assert relationship["score"] == 42.5
    assert relationship["display_name"] == "Alice Smith"
    assert relationship["emails"] == ["alice@example.com"]
    assert relationship["phones"] == ["+15085551234"]
    assert relationship["organization"] == "Acme Corp"

    # First SQL call should include the self_person filter and pagination params
    assert "self_person_id = %s" in executed["sql"][0]
    assert executed["params"][0] == [
        30,
        "11111111-1111-1111-1111-111111111111",
        25,
        0,
    ]

    # Count query should group by the unique relationship pair
    assert "GROUP BY cr.self_person_id, cr.person_id" in executed["sql"][1]
    assert executed["params"][1] == [
        30,
        "11111111-1111-1111-1111-111111111111",
    ]

    assert executed["row_factory"].__name__ == "dict_row"
