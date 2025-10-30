import sys
import types
import uuid
import pytest
from fastapi.testclient import TestClient
from contextlib import contextmanager

# Stub optional deps used by gateway to allow test import without extras
minio_module = types.ModuleType("minio")
error_module = types.ModuleType("minio.error")
class _S3Error(Exception):
    pass
setattr(minio_module, "Minio", object)
setattr(error_module, "S3Error", _S3Error)
sys.modules.setdefault("minio", minio_module)
sys.modules.setdefault("minio.error", error_module)

# Stub pdfminer used for file extraction
pdfminer_module = types.ModuleType("pdfminer")
pdfminer_high = types.ModuleType("pdfminer.high_level")

def _extract_text_stub(*args, **kwargs):
    return ""

setattr(pdfminer_high, "extract_text", _extract_text_stub)
sys.modules.setdefault("pdfminer", pdfminer_module)
sys.modules.setdefault("pdfminer.high_level", pdfminer_high)

import services.gateway_api.app as gateway_module
from services.gateway_api.app import app as gateway_app
import services.catalog_api.app as catalog_module


def make_contacts_fixture():
    return [
        {
            "external_id": "CN_a",
            "display_name": "Dee Email",
            "emails": [
                {"value": "dee@example.com", "label": "work"},
                {"value": "dee@alt.com", "label": "personal"},
            ],
            "phones": [],
        },
        {
            "external_id": "CN_b",
            "display_name": "Pho Nomme",
            "phones": [
                {"value": "+15551231234", "label": "mobile"},
                {"value": "(555) 234-5678", "label": "home"},
            ],
        },
    ]


def make_people_json_for_doc():
    return [
        {"identifier": "dee@example.com", "identifier_type": "email", "role": "sender"},
        {"identifier": "+15551231234", "identifier_type": "phone", "role": "recipient"},
        {"identifier": "unknown@example.com", "identifier_type": "email", "role": "participant"},
    ]


@pytest.fixture(scope="module")
def gateway():
    return TestClient(gateway_app)


def test_contact_ingest_people_are_normalized_monkeypatched(gateway, monkeypatch):
    # Avoid DB write by stubbing get_connection and token update; avoid network by stubbing catalog sync
    class DummyConn:
        def commit(self):
            pass
        def rollback(self):
            pass

    def fake_update_change_token(conn, source, device_id, token):
        return None

    class DummyResponse:
        def __init__(self, status_code=202, payload=None):
            self.status_code = status_code
            self._payload = payload or {"duplicate": False}
            self.text = ""
        def json(self):
            return self._payload

    def fake_catalog_sync_request(method: str, path: str, correlation_id: str, *, json_payload=None):
        return DummyResponse(202, {"duplicate": False})

    @contextmanager
    def fake_connection(*args, **kwargs):
        yield DummyConn()

    monkeypatch.setattr(gateway_module, "get_connection", fake_connection)
    monkeypatch.setattr(gateway_module, "_update_change_token", fake_update_change_token)
    monkeypatch.setattr(gateway_module, "_catalog_sync_request", fake_catalog_sync_request)
    monkeypatch.setattr(gateway_module, "get_active_document", lambda external_id: None)

    payload = {
        "source": "test_import",
        "device_id": "hv-112-fixture",
        "since_token": None,
        "batch_id": "batch-hv-112",
        "people": make_contacts_fixture(),
    }
    r = gateway.post("/catalog/contacts/ingest", json=payload)
    assert r.status_code == 200
    data = r.json()
    assert data["accepted"] == 2
    assert data["upserts"] >= 1


def test_link_document_people_standalone(monkeypatch):
    # Prepare fake resolver outputs for two identifiers
    class FakeResolver:
        def __init__(self, conn, **kwargs):
            pass
        def resolve(self, kind, value):
            mapping = {
                ("email", "dee@example.com"): {"person_id": str(uuid.uuid4()), "display_name": "Dee Email"},
                ("phone", "+15551231234"): {"person_id": str(uuid.uuid4()), "display_name": "Pho Nomme"},
            }
            # kind is Enum, use its value
            return mapping.get((getattr(kind, "value", str(kind)), value))

    monkeypatch.setattr(catalog_module, "PeopleResolver", FakeResolver)

    # Capture SQL inserts to document_people
    captured = {"inserts": []}

    class DummyCursor:
        def __enter__(self):
            return self
        def __exit__(self, exc_type, exc, tb):
            return False
        def execute(self, sql, params):
            if "INSERT INTO document_people" in sql:
                captured["inserts"].append(tuple(params))
        def fetchone(self):
            return None
        def fetchall(self):
            return []

    class DummyConn:
        def cursor(self, row_factory=None):
            return DummyCursor()

    doc_id = uuid.uuid4()
    people_json = make_people_json_for_doc()

    link_fn = getattr(catalog_module, "_link_document_people")
    link_fn(DummyConn(), doc_id, people_json)

    # Expect two inserts for resolvable identifiers with correct roles
    by_role = {role: (did, pid) for (did, pid, role) in captured["inserts"]}
    assert len(captured["inserts"]) == 2
    assert "sender" in by_role and "recipient" in by_role
