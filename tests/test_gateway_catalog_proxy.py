import json
from typing import Any, Dict, cast

from fastapi.testclient import TestClient

from services.gateway_api import app as gateway_app


def test_proxy_catalog_events_forwards_batches(monkeypatch):
    original_token = gateway_app.settings.catalog_token
    gateway_app.settings.catalog_token = None

    calls: Dict[str, Dict[str, Any]] = {}

    class DummyResponse:
        def __init__(self) -> None:
            self.status_code = 202
            self.content = b"{\"ingested\": 1}"
            self.headers = {"content-type": "application/json"}

        def json(self) -> dict[str, int]:
            return {"ingested": 1}

    class DummyAsyncClient:
        def __init__(self, *args, **kwargs) -> None:
            calls["init_kwargs"] = kwargs

        async def __aenter__(self) -> "DummyAsyncClient":
            return self

        async def __aexit__(self, exc_type, exc, tb) -> bool:
            return False

        async def post(self, path: str, content: bytes, headers: dict[str, str]) -> DummyResponse:
            calls["request"] = {"path": path, "content": content, "headers": headers}
            return DummyResponse()

    monkeypatch.setattr(gateway_app.httpx, "AsyncClient", DummyAsyncClient)

    try:
        with TestClient(gateway_app.app) as client:
            response = client.post(
                "/v1/catalog/events",
                json={"items": [{"doc_id": "doc-1"}]},
            )
    finally:
        gateway_app.settings.catalog_token = original_token
        gateway_app._search_client = None

    assert response.status_code == 202
    request_details = calls["request"]
    assert cast(str, request_details["path"]) == "/v1/catalog/events"
    forwarded_payload = json.loads(cast(bytes, request_details["content"]).decode("utf-8"))
    assert forwarded_payload == {"items": [{"doc_id": "doc-1"}]}
    headers = cast(dict[str, str], request_details["headers"])
    assert headers["Content-Type"] == "application/json"
