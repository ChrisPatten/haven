from __future__ import annotations

from typing import Any, Dict

from fastapi.testclient import TestClient

from services.gateway_api import app as gateway_app


def test_gateway_ingest_posts_to_catalog(monkeypatch):
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
            calls["init_kwargs"] = kwargs

        async def __aenter__(self) -> "DummyAsyncClient":
            return self

        async def __aexit__(self, exc_type, exc, tb) -> bool:
            return False

        async def request(self, method: str, path: str, json=None, headers=None):
            calls["request"] = {"method": method, "path": path, "json": json, "headers": headers}
            return DummyResponse()

    monkeypatch.setattr(gateway_app.httpx, "AsyncClient", DummyAsyncClient)

    try:
        with TestClient(gateway_app.app) as client:
            response = client.post(
                "/v1/ingest",
                json={
                    "source_type": "imessage",
                    "source_id": "thread-1",
                    "content": {"mime_type": "text/plain", "data": "Hello world"},
                    "metadata": {"foo": "bar"},
                },
                headers={"Authorization": "Bearer changeme"},
            )
    finally:
        gateway_app.settings.catalog_token = original_token
        gateway_app._search_client = None

    assert response.status_code == 202
    payload = response.json()
    assert payload["submission_id"] == "sub-1"
    assert "X-Correlation-ID" in response.headers

    request_details = calls["request"]
    assert request_details["method"] == "POST"
    assert request_details["path"] == "/v1/catalog/documents"
    forwarded_json = request_details["json"]
    assert forwarded_json["source_type"] == "imessage"
    assert forwarded_json["source_id"] == "thread-1"
    assert forwarded_json["text"] == "Hello world"
    assert forwarded_json["metadata"] == {"foo": "bar"}
    assert "idempotency_key" in forwarded_json
    assert request_details["headers"]["X-Correlation-ID"].startswith("gw_ingest_")


def test_gateway_ingest_status_proxies_catalog(monkeypatch):
    original_token = gateway_app.settings.catalog_token
    gateway_app.settings.catalog_token = None

    calls: Dict[str, Dict[str, Any]] = {}

    class DummyResponse:
        status_code = 200

        def json(self) -> Dict[str, Any]:
            return {
                "submission_id": "sub-1",
                "status": "embedding_pending",
                "document_status": "embedding_pending",
                "doc_id": "doc-1",
                "total_chunks": 2,
                "embedded_chunks": 1,
                "pending_chunks": 1,
                "error": None,
            }

        @property
        def text(self) -> str:
            return "ok"

    class DummyAsyncClient:
        def __init__(self, *args, **kwargs) -> None:
            calls["init_kwargs"] = kwargs

        async def __aenter__(self) -> "DummyAsyncClient":
            return self

        async def __aexit__(self, exc_type, exc, tb) -> bool:
            return False

        async def request(self, method: str, path: str, json=None, headers=None):
            calls["request"] = {"method": method, "path": path, "headers": headers}
            return DummyResponse()

    monkeypatch.setattr(gateway_app.httpx, "AsyncClient", DummyAsyncClient)

    try:
        with TestClient(gateway_app.app) as client:
            response = client.get(
                "/v1/ingest/sub-1",
                headers={"Authorization": "Bearer changeme"},
            )
    finally:
        gateway_app.settings.catalog_token = original_token
        gateway_app._search_client = None

    assert response.status_code == 200
    data = response.json()
    assert data["submission_id"] == "sub-1"
    assert data["pending_chunks"] == 1
    assert "X-Correlation-ID" in response.headers
    assert calls["request"]["path"] == "/v1/catalog/submissions/sub-1"
    assert calls["request"]["headers"]["X-Correlation-ID"].startswith("gw_status_")
