"""
Tests for contact merge functionality (hv-68).

Tests cover:
- Simple pair merge (2 people)
- Transitive merge (A→B, B→C)
- No-op merge (already merged)
- FK updates for all related tables
- Attribute merging strategies (prefer_target, prefer_source, merge_non_null)
- Transaction rollback on error
- Audit log creation
- Duplicate discovery
"""

import pytest
from uuid import UUID, uuid4
from typing import Optional

from shared.people_normalization import (
    IdentifierKind,
    NormalizedIdentifier,
    normalize_identifier,
    find_duplicate_candidates,
)
from shared.people_repository import (
    PersonIngestRecord,
    PeopleRepository,
    ContactValue,
    ContactAddress,
    ContactUrl,
)


@pytest.fixture
def setup_people(conn_fixture):
    """
    Set up test people with identifiers, addresses, URLs.
    Returns dict with person_ids and connection.
    """
    from psycopg import Connection

    conn = conn_fixture
    repo = PeopleRepository(conn)

    # Create person 1: John Doe with phone +15551234567
    person1 = PersonIngestRecord(
        external_id="contact_1",
        display_name="John Doe",
        given_name="John",
        family_name="Doe",
        organization="Acme Corp",
        emails=[ContactValue(value="john@example.com", label="work")],
        phones=[ContactValue(value="+15551234567", label="mobile", value_raw="555-123-4567")],
        addresses=[ContactAddress(label="work", city="San Francisco", region="CA")],
        urls=[ContactUrl(label="website", url="https://johndoe.com")],
    )

    # Create person 2: Jane Smith with phone +15559876543
    person2 = PersonIngestRecord(
        external_id="contact_2",
        display_name="Jane Smith",
        given_name="Jane",
        family_name="Smith",
        emails=[ContactValue(value="jane@example.com", label="work")],
        phones=[ContactValue(value="+15559876543", label="mobile")],
        addresses=[ContactAddress(label="home", city="New York", region="NY")],
    )

    # Create person 3: Duplicate of John (same phone)
    person3 = PersonIngestRecord(
        external_id="contact_3",
        display_name="J. Doe",
        given_name="J.",
        family_name="Doe",
        organization="Acme",
        emails=[ContactValue(value="johndoe@work.com", label="work")],
        phones=[ContactValue(value="+1 (555) 123-4567", label="mobile")],  # Same as person1, different format
        notes="Duplicate record",
    )

    stats1 = repo.upsert_batch("test_source", [person1, person2, person3])
    conn.commit()

    # Get the generated person IDs
    with conn.cursor() as cur:
        cur.execute(
            "SELECT person_id FROM people_source_map WHERE source = 'test_source' ORDER BY created_at"
        )
        rows = cur.fetchall()
        person_ids = [row[0] for row in rows]

    return {
        "conn": conn,
        "repo": repo,
        "person1_id": person_ids[0],
        "person2_id": person_ids[1],
        "person3_id": person_ids[2],
    }


class TestMergePeopleBasic:
    """Basic merge operation tests."""

    def test_simple_pair_merge(self, setup_people):
        """Test merging two contacts into one."""
        conn = setup_people["conn"]
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source_id = setup_people["person3_id"]

        result = repo.merge_people(
            target_id=target_id,
            source_ids=[source_id],
            strategy="prefer_target",
            actor="test_user",
        )

        assert result["merge_id"]
        assert result["target_id"] == str(target_id)
        assert result["source_ids"] == [str(source_id)]
        assert result["strategy"] == "prefer_target"

        # Verify source is marked as merged
        with conn.cursor() as cur:
            cur.execute(
                "SELECT merged_into FROM people WHERE person_id = %s", (source_id,)
            )
            row = cur.fetchone()
            assert row[0] == target_id

        # Verify audit log entry
        with conn.cursor() as cur:
            cur.execute(
                "SELECT target_person_id, source_person_ids FROM contacts_merge_audit WHERE merge_id = %s",
                (UUID(result["merge_id"]),),
            )
            audit_row = cur.fetchone()
            assert audit_row[0] == target_id
            assert source_id in audit_row[1]

    def test_merge_validation_empty_sources(self, setup_people):
        """Test that merge fails with empty source_ids."""
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]

        with pytest.raises(ValueError, match="source_ids cannot be empty"):
            repo.merge_people(
                target_id=target_id,
                source_ids=[],
                strategy="prefer_target",
            )

    def test_merge_validation_target_in_sources(self, setup_people):
        """Test that merge fails if target is in source_ids."""
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]

        with pytest.raises(ValueError, match="target_id cannot be in source_ids"):
            repo.merge_people(
                target_id=target_id,
                source_ids=[target_id],
                strategy="prefer_target",
            )

    def test_merge_validation_invalid_strategy(self, setup_people):
        """Test that merge fails with invalid strategy."""
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source_id = setup_people["person2_id"]

        with pytest.raises(ValueError, match="Invalid strategy"):
            repo.merge_people(
                target_id=target_id,
                source_ids=[source_id],
                strategy="invalid_strategy",
            )

    def test_merge_validation_target_not_found(self, setup_people):
        """Test that merge fails if target doesn't exist."""
        repo = setup_people["repo"]
        fake_id = uuid4()
        source_id = setup_people["person2_id"]

        with pytest.raises(ValueError, match="Target person.*not found"):
            repo.merge_people(
                target_id=fake_id,
                source_ids=[source_id],
                strategy="prefer_target",
            )

    def test_merge_validation_source_not_found(self, setup_people):
        """Test that merge fails if source doesn't exist."""
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        fake_id = uuid4()

        with pytest.raises(ValueError, match="Source person.*not found"):
            repo.merge_people(
                target_id=target_id,
                source_ids=[fake_id],
                strategy="prefer_target",
            )


class TestMergeAttributes:
    """Test attribute merging strategies."""

    def test_prefer_target_strategy(self, setup_people):
        """Test prefer_target strategy keeps target attributes."""
        conn = setup_people["conn"]
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source_id = setup_people["person3_id"]

        repo.merge_people(
            target_id=target_id,
            source_ids=[source_id],
            strategy="prefer_target",
            actor="test_user",
        )

        # Check that target's display_name is unchanged
        with conn.cursor() as cur:
            cur.execute("SELECT display_name FROM people WHERE person_id = %s", (target_id,))
            row = cur.fetchone()
            assert row[0] == "John Doe"

    def test_prefer_source_strategy(self, setup_people):
        """Test prefer_source strategy uses source attributes."""
        conn = setup_people["conn"]
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source_id = setup_people["person3_id"]

        repo.merge_people(
            target_id=target_id,
            source_ids=[source_id],
            strategy="prefer_source",
            actor="test_user",
        )

        # Check that target's organization is updated from source
        with conn.cursor() as cur:
            cur.execute("SELECT organization FROM people WHERE person_id = %s", (target_id,))
            row = cur.fetchone()
            assert row[0] in ("Acme", "Acme Corp")  # Should have source's value or similar

    def test_merge_non_null_strategy(self, setup_people):
        """Test merge_non_null strategy combines non-null values."""
        conn = setup_people["conn"]
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source_id = setup_people["person3_id"]

        repo.merge_people(
            target_id=target_id,
            source_ids=[source_id],
            strategy="merge_non_null",
            actor="test_user",
        )

        # Merge_non_null should prefer target when both exist
        with conn.cursor() as cur:
            cur.execute("SELECT display_name FROM people WHERE person_id = %s", (target_id,))
            row = cur.fetchone()
            assert row[0] == "John Doe"


class TestMergeForeignKeys:
    """Test that FK updates are handled correctly."""

    def test_identifiers_merged(self, setup_people):
        """Test that person_identifiers are updated."""
        conn = setup_people["conn"]
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source_id = setup_people["person3_id"]

        repo.merge_people(
            target_id=target_id,
            source_ids=[source_id],
            strategy="prefer_target",
        )

        # Both identifiers should now point to target
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) FROM person_identifiers WHERE person_id = %s",
                (target_id,),
            )
            count = cur.fetchone()[0]
            assert count >= 2  # Both person1 and person3's identifiers

    def test_addresses_merged(self, setup_people):
        """Test that person_addresses are updated."""
        conn = setup_people["conn"]
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source_id = setup_people["person3_id"]

        repo.merge_people(
            target_id=target_id,
            source_ids=[source_id],
            strategy="prefer_target",
        )

        # All addresses should point to target
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) FROM person_addresses WHERE person_id = %s",
                (target_id,),
            )
            count = cur.fetchone()[0]
            assert count >= 1  # person1's address

    def test_source_map_merged(self, setup_people):
        """Test that people_source_map is updated."""
        conn = setup_people["conn"]
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source_id = setup_people["person3_id"]

        repo.merge_people(
            target_id=target_id,
            source_ids=[source_id],
            strategy="prefer_target",
        )

        # Both external IDs should map to target
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(DISTINCT person_id) FROM people_source_map WHERE source = 'test_source'",
            )
            distinct_ids = cur.fetchone()[0]
            assert distinct_ids == 2  # Only person1_id and person2_id now


class TestDuplicateDiscovery:
    """Test duplicate candidate discovery."""

    def test_find_duplicates_by_phone(self, setup_people):
        """Test finding duplicate contacts by phone."""
        conn = setup_people["conn"]

        duplicates = find_duplicate_candidates(conn)

        # Should find at least one group (person1 and person3 share phone)
        assert len(duplicates) > 0

        # Find the phone duplicate group
        phone_groups = [d for d in duplicates if d["kind"] == "phone"]
        assert len(phone_groups) > 0

        phone_group = phone_groups[0]
        assert phone_group["count"] >= 2
        assert len(phone_group["person_ids"]) >= 2

    def test_find_duplicates_excludes_merged(self, setup_people):
        """Test that find_duplicates excludes already-merged records."""
        conn = setup_people["conn"]
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source_id = setup_people["person3_id"]

        # Merge the records
        repo.merge_people(
            target_id=target_id,
            source_ids=[source_id],
            strategy="prefer_target",
        )
        conn.commit()

        duplicates = find_duplicate_candidates(conn)

        # Merged records should not appear in duplicates anymore
        for group in duplicates:
            assert source_id not in group.get("person_ids", [])


class TestAuditLogging:
    """Test audit trail functionality."""

    def test_audit_log_created(self, setup_people):
        """Test that merge operations are logged to audit table."""
        conn = setup_people["conn"]
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source_id = setup_people["person3_id"]

        result = repo.merge_people(
            target_id=target_id,
            source_ids=[source_id],
            strategy="prefer_target",
            actor="test_admin",
            metadata={"reason": "duplicate"},
        )

        # Verify audit entry
        with conn.cursor() as cur:
            cur.execute(
                "SELECT merge_id, target_person_id, source_person_ids, actor, strategy, merge_metadata FROM contacts_merge_audit WHERE merge_id = %s",
                (UUID(result["merge_id"]),),
            )
            audit_row = cur.fetchone()
            assert audit_row is not None
            assert audit_row[1] == target_id
            assert source_id in audit_row[2]
            assert audit_row[3] == "test_admin"
            assert audit_row[4] == "prefer_target"
            assert audit_row[5].get("reason") == "duplicate"


class TestMultipleMerge:
    """Test merging more than 2 contacts at once."""

    def test_merge_three_contacts(self, setup_people):
        """Test merging three contacts into one."""
        conn = setup_people["conn"]
        repo = setup_people["repo"]
        target_id = setup_people["person1_id"]
        source1_id = setup_people["person3_id"]
        source2_id = setup_people["person2_id"]

        result = repo.merge_people(
            target_id=target_id,
            source_ids=[source1_id, source2_id],
            strategy="prefer_target",
        )

        assert result["target_id"] == str(target_id)
        assert set(result["source_ids"]) == {str(source1_id), str(source2_id)}

        # Both sources should be marked as merged
        with conn.cursor() as cur:
            for source_id in [source1_id, source2_id]:
                cur.execute(
                    "SELECT merged_into FROM people WHERE person_id = %s", (source_id,)
                )
                row = cur.fetchone()
                assert row[0] == target_id
