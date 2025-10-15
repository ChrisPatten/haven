from __future__ import annotations

import hashlib
import json
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


def test_gateway_file_ingest_uploads_to_object_store_and_catalog(monkeypatch):
    original_token = gateway_app.settings.catalog_token
    gateway_app.settings.catalog_token = None
    gateway_app._minio_client = None

    class FakeS3Error(Exception):
        def __init__(self, code: str, status: int = 404) -> None:
            super().__init__(code)
            self.code = code
            self.status = status

    class DummyMinio:
        def __init__(self) -> None:
            self.bucket_exists_calls: list[str] = []
            self.make_bucket_calls: list[str] = []
            self.stat_calls: list[tuple[str, str]] = []
            self.put_object_calls: list[Dict[str, Any]] = []

        def bucket_exists(self, bucket: str) -> bool:
            self.bucket_exists_calls.append(bucket)
            return False

        def make_bucket(self, bucket: str) -> None:
            self.make_bucket_calls.append(bucket)

        def stat_object(self, bucket: str, object_key: str) -> None:
            self.stat_calls.append((bucket, object_key))
            raise gateway_app.S3Error("NoSuchKey")

        def put_object(
            self,
            bucket: str,
            object_key: str,
            stream,
            length: int,
            content_type: str,
        ) -> None:
            self.put_object_calls.append(
                {
                    "bucket": bucket,
                    "object_key": object_key,
                    "length": length,
                    "content_type": content_type,
                    "data": stream.getvalue(),
                }
            )

    dummy_minio = DummyMinio()

    monkeypatch.setattr(gateway_app, "S3Error", FakeS3Error)
    monkeypatch.setattr(gateway_app, "_get_minio_client", lambda: dummy_minio)
    monkeypatch.setattr(gateway_app, "_minio_bucket_checked", False, raising=False)

    calls: Dict[str, Any] = {}

    async def fake_catalog_request(method: str, path: str, correlation_id: str, *, json_payload=None):
        calls["payload"] = json_payload

        class FakeResponse:
            status_code = 202

            def json(self) -> Dict[str, Any]:
                return {
                    "submission_id": "sub-123",
                    "status": "embedding_pending",
                    "doc_id": "doc-456",
                    "total_chunks": 3,
                    "duplicate": False,
                }

        return FakeResponse()

    monkeypatch.setattr(gateway_app, "_catalog_request", fake_catalog_request)

    file_bytes = b"Hello localfs"
    expected_sha = hashlib.sha256(file_bytes).hexdigest()

    try:
        with TestClient(gateway_app.app) as client:
            response = client.post(
                "/v1/ingest/file",
                data={"meta": json.dumps({"path": "/tmp/sample.txt", "filename": "sample.txt", "tags": ["notes"]})},
                files={"upload": ("sample.txt", file_bytes, "text/plain")},
                headers={"Authorization": "Bearer changeme"},
            )
    finally:
        gateway_app.settings.catalog_token = original_token
        gateway_app._search_client = None
        gateway_app._minio_client = None
        gateway_app._minio_bucket_checked = False

    assert response.status_code == 202
    data = response.json()
    assert data["submission_id"] == "sub-123"
    assert data["file_sha256"] == expected_sha
    assert data["extraction_status"] == "ready"
    assert data["object_key"].startswith(f"{expected_sha}/")
    assert response.headers["X-File-SHA256"] == expected_sha
    assert response.headers["X-Object-Key"].startswith(f"{expected_sha}/")
    assert dummy_minio.bucket_exists_calls == [gateway_app.settings.minio_bucket]
    assert dummy_minio.make_bucket_calls == [gateway_app.settings.minio_bucket]
    assert dummy_minio.put_object_calls, "Expected file to be uploaded to MinIO"
    upload_call = dummy_minio.put_object_calls[0]
    assert upload_call["data"] == file_bytes
    assert upload_call["length"] == len(file_bytes)
    payload = calls["payload"]
    assert payload["attachments"][0]["object_key"] == data["object_key"]
    assert payload["attachments"][0]["extraction_status"] == "ready"
    assert payload["metadata"]["file"]["sha256"] == expected_sha
    assert "Hello localfs" in payload["text"]


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
