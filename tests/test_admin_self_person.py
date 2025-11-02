"""Tests for self_person_id admin endpoints and system_settings."""

import json
from datetime import datetime, UTC
from uuid import UUID, uuid4

import pytest
from psycopg import Connection

from shared.people_repository import (
    get_self_person_id_from_settings,
    store_self_person_id_if_needed,
)


@pytest.fixture
def test_person_id(conn: Connection) -> UUID:
    """Create a test person and return their ID."""
    person_id = uuid4()
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO people (person_id, display_name, given_name, family_name)
            VALUES (%s, 'Test Person', 'Test', 'Person')
            """,
            (person_id,),
        )
        conn.commit()
    return person_id


class TestGetSelfPersonIdFromSettings:
    """Tests for get_self_person_id_from_settings()."""

    def test_returns_none_when_not_set(self, conn: Connection):
        """Should return None when self_person_id is not set."""
        result = get_self_person_id_from_settings(conn)
        assert result is None

    def test_returns_uuid_when_set(self, conn: Connection, test_person_id: UUID):
        """Should return the UUID when self_person_id is set."""
        # Set the value directly
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO system_settings (key, value)
                VALUES ('self_person_id', %s)
                """,
                (json.dumps({
                    "self_person_id": str(test_person_id),
                    "source": "imessage",
                    "detected_at": "2025-11-01T12:00:00Z",
                }),),
            )
            conn.commit()
        
        result = get_self_person_id_from_settings(conn)
        assert result == test_person_id

    def test_returns_none_when_value_is_null(self, conn: Connection):
        """Should return None when self_person_id value is null."""
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO system_settings (key, value)
                VALUES ('self_person_id', %s)
                """,
                (json.dumps({"self_person_id": None}),),
            )
            conn.commit()
        
        result = get_self_person_id_from_settings(conn)
        assert result is None


class TestStoreSelfPersonIdIfNeeded:
    """Tests for store_self_person_id_if_needed()."""

    def test_writes_when_not_set(self, conn: Connection, test_person_id: UUID):
        """Should write self_person_id when not already set."""
        now = datetime.now(tz=UTC)
        result = store_self_person_id_if_needed(
            conn,
            test_person_id,
            source="imessage",
            detected_at=now.isoformat(),
        )
        
        assert result is True
        
        # Verify stored value
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT value->>'self_person_id' AS self_person_id
                FROM system_settings
                WHERE key = 'self_person_id'
                """
            )
            row = cur.fetchone()
            assert row is not None
            assert row[0] == str(test_person_id)

    def test_returns_false_when_already_set(self, conn: Connection, test_person_id: UUID):
        """Should return False when self_person_id is already set."""
        # Set initial value
        now = datetime.now(tz=UTC)
        store_self_person_id_if_needed(
            conn,
            test_person_id,
            source="imessage",
            detected_at=now.isoformat(),
        )
        
        # Try to store again
        other_person_id = uuid4()
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO people (person_id, display_name, given_name, family_name)
                VALUES (%s, 'Other Person', 'Other', 'Person')
                """,
                (other_person_id,),
            )
            conn.commit()
        
        result = store_self_person_id_if_needed(
            conn,
            other_person_id,
            source="imessage",
            detected_at=now.isoformat(),
        )
        
        assert result is False
        
        # Verify original value is unchanged
        stored_id = get_self_person_id_from_settings(conn)
        assert stored_id == test_person_id

    def test_upsert_is_idempotent(self, conn: Connection, test_person_id: UUID):
        """Should be safe to call multiple times (idempotent)."""
        now = datetime.now(tz=UTC)
        
        # Call multiple times
        result1 = store_self_person_id_if_needed(
            conn,
            test_person_id,
            source="imessage",
            detected_at=now.isoformat(),
        )
        result2 = store_self_person_id_if_needed(
            conn,
            test_person_id,
            source="imessage",
            detected_at=now.isoformat(),
        )
        
        assert result1 is True
        assert result2 is False
        
        # Verify value is still there
        stored_id = get_self_person_id_from_settings(conn)
        assert stored_id == test_person_id

    def test_stores_metadata(self, conn: Connection, test_person_id: UUID):
        """Should store source and detected_at metadata."""
        now = datetime.now(tz=UTC)
        now_str = now.isoformat()
        
        store_self_person_id_if_needed(
            conn,
            test_person_id,
            source="manual",
            detected_at=now_str,
        )
        
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT value
                FROM system_settings
                WHERE key = 'self_person_id'
                """
            )
            row = cur.fetchone()
            assert row is not None
            value = row[0]
            assert value["self_person_id"] == str(test_person_id)
            assert value["source"] == "manual"
            assert value["detected_at"] == now_str


class TestAdminEndpoints:
    """Integration tests for admin endpoints via FastAPI."""

    def test_get_self_person_id_when_not_set(self, client, admin_token):
        """GET /v1/admin/self-person-id should return empty with warning."""
        response = client.get(
            "/v1/admin/self-person-id",
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        
        assert response.status_code == 200
        data = response.json()
        assert data["self_person_id"] is None
        assert data["warning"] == "self_person_id not yet set"

    def test_post_self_person_id_sets_value(self, client, admin_token, test_person_id: UUID):
        """POST /v1/admin/self-person-id should set the value."""
        response = client.post(
            "/v1/admin/self-person-id",
            headers={"Authorization": f"Bearer {admin_token}"},
            json={
                "person_id": str(test_person_id),
                "source": "manual",
            },
        )
        
        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert data["self_person_id"] == str(test_person_id)
        assert data["source"] == "manual"

    def test_get_self_person_id_after_set(self, client, admin_token, test_person_id: UUID):
        """GET /v1/admin/self-person-id should return set value after POST."""
        # Set the value first
        client.post(
            "/v1/admin/self-person-id",
            headers={"Authorization": f"Bearer {admin_token}"},
            json={
                "person_id": str(test_person_id),
                "source": "imessage",
            },
        )
        
        # Now GET
        response = client.get(
            "/v1/admin/self-person-id",
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        
        assert response.status_code == 200
        data = response.json()
        assert data["self_person_id"] == str(test_person_id)
        assert data["source"] == "imessage"
        assert data["warning"] is None

    def test_post_with_invalid_uuid(self, client, admin_token):
        """POST should return error for invalid UUID."""
        response = client.post(
            "/v1/admin/self-person-id",
            headers={"Authorization": f"Bearer {admin_token}"},
            json={
                "person_id": "not-a-uuid",
                "source": "manual",
            },
        )
        
        assert response.status_code == 200
        data = response.json()
        assert data["success"] is False
        assert "Invalid UUID" in data["error"]

    def test_post_with_nonexistent_person(self, client, admin_token):
        """POST should return error for person that doesn't exist."""
        nonexistent_id = uuid4()
        response = client.post(
            "/v1/admin/self-person-id",
            headers={"Authorization": f"Bearer {admin_token}"},
            json={
                "person_id": str(nonexistent_id),
                "source": "manual",
            },
        )
        
        assert response.status_code == 200
        data = response.json()
        assert data["success"] is False
        assert "not found" in data["error"].lower()

    def test_requires_auth(self, client):
        """Endpoints should require authentication."""
        # GET without auth
        response = client.get("/v1/admin/self-person-id")
        assert response.status_code == 401
        
        # POST without auth
        response = client.post(
            "/v1/admin/self-person-id",
            json={"person_id": str(uuid4())},
        )
        assert response.status_code == 401
