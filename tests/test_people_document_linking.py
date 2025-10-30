import uuid
import pytest
from fastapi.testclient import TestClient
from services.gateway_api.app import app as gateway_app
from services.catalog_api.app import app as catalog_app

def make_contacts_fixture():
    # Diverse: phone, email, social, duplicates, missing pieces, deleted, multiple roles
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
        {
            "external_id": "CN_c",
            "display_name": "Mia Social",
            "emails": [
                {"value": "mia.social@example.com", "label": "work"}
            ],
            "phones": [
                {"value": "+15559998877", "label": "mobile"}
            ],
            "deleted": True,
        },
        {
            "external_id": "CN_d",
            "display_name": "Unresolvable",
            "phones": [{"value": "000"}],
            # Invalid, will not resolve
        },
    ]
def make_documents_fixture():
    # Each "people" entry will be attempted to link to above contacts
    doc_id = str(uuid.uuid4())
    return [
        {
            "idempotency_key": f"doc-{doc_id}-A",
            "source_type": "email",
            "source_id": "email-abc",
            "content_sha256": "sha1",
            "title": "Test Email",
            "text": "Email body",
            "content_timestamp": "2024-01-01T00:00:00Z",
            "content_timestamp_type": "sent",
            "people": [
                {"identifier": "dee@example.com", "identifier_type": "email", "role": "sender"},
                {"identifier": "+15551231234", "identifier_type": "phone", "role": "recipient"},
            ],
        },
        {
            "idempotency_key": f"doc-{doc_id}-B",
            "source_type": "imessage",
            "source_id": "msg-123",
            "content_sha256": "sha2",
            "title": "Text thread",
            "text": "Hey there!",
            "content_timestamp": "2024-01-01T12:00:00Z",
            "content_timestamp_type": "sent",
            "people": [
                {"identifier": "MIA.SOCIAL@example.com", "identifier_type": "email", "role": "mentioned"},
                {"identifier": "+15559998877", "identifier_type": "phone", "role": "sender"},  # Is deleted
                {"identifier": "+19999999999", "identifier_type": "phone", "role": "recipient"},  # MISSING
            ],
        },
        {
            "idempotency_key": f"doc-{doc_id}-C",
            "source_type": "note",
            "source_id": "note-13",
            "content_sha256": "sha3",
            "title": "Personal notes",
            "text": "Random",
            "content_timestamp": "2024-02-01T13:00:00Z",
            "content_timestamp_type": "authored",
            "people": [
                {"identifier": "000", "identifier_type": "phone", "role": "sender"},  # unresolvable
                {"identifier": "dee@alt.com", "identifier_type": "email", "role": "participant"},
            ],
        },
    ]

@pytest.fixture(scope="module")
def gateway():
    return TestClient(gateway_app)

@pytest.fixture(scope="module")
def catalog():
    return TestClient(catalog_app)

@pytest.mark.order(1)
def test_contact_ingest_people_are_normalized(gateway):
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
    assert data["accepted"] == 4
    # At least 2 accepted; deleted doesn't count as upsert, missing phone doesn't either
    assert data["upserts"] >= 2

@pytest.mark.order(2)
def test_document_ingest_links_persons(catalog):
    fixtures = make_documents_fixture()
    for fx in fixtures:
        resp = catalog.post("/v1/catalog/documents", json=fx)
        assert resp.status_code in (200, 202)
        result = resp.json()
        assert result["doc_id"]
    # Depending on test DB and resets, run DB query here or have manual confirmation: in a real environment,
    # this would query the document_people and people tables for linking rows. Here we rely on no exceptions.

# Future: use direct DB/ORM calls to validate document_people and linking. This is a smoke/behavior test skeleton.
