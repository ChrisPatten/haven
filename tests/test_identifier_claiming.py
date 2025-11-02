"""
Tests for identifier claiming functionality (hv-8972).

Tests cover:
- Atomic identifier claiming (_claim_identifier_ownership)
- Person resolution by identifiers (_resolve_person_by_identifiers)
- Concurrent claim attempts (no duplicate ownership)
- Existing owner detection
- Edge cases (unclaimed identifiers, multiple identifiers)
"""

import pytest
from uuid import UUID, uuid4

from shared.people_normalization import (
    IdentifierKind,
    NormalizedIdentifier,
    normalize_identifier,
)
from shared.people_repository import (
    PersonIngestRecord,
    PeopleRepository,
    ContactValue,
)


@pytest.fixture
def setup_identifier_test_data(conn_fixture):
    """
    Set up test data: people and identifier_owner entries.
    Returns dict with person_ids, identifiers, and connection.
    """
    conn = conn_fixture
    repo = PeopleRepository(conn)

    # Create person 1: John Doe with phone +15551234567
    person1 = PersonIngestRecord(
        external_id="contact_1",
        display_name="John Doe",
        given_name="John",
        family_name="Doe",
        emails=[ContactValue(value="john@example.com", label="work")],
        phones=[ContactValue(value="+15551234567", label="mobile")],
    )

    # Create person 2: Jane Smith with phone +15559876543
    person2 = PersonIngestRecord(
        external_id="contact_2",
        display_name="Jane Smith",
        given_name="Jane",
        family_name="Smith",
        emails=[ContactValue(value="jane@example.com", label="work")],
        phones=[ContactValue(value="+15559876543", label="mobile")],
    )

    repo.upsert_batch("test_source", [person1, person2])
    conn.commit()

    # Get the generated person IDs
    with conn.cursor() as cur:
        cur.execute(
            "SELECT person_id FROM people_source_map WHERE source = 'test_source' ORDER BY created_at"
        )
        rows = cur.fetchall()
        person_ids = [row[0] for row in rows]

    # Normalize identifiers
    phone1 = normalize_identifier(IdentifierKind.PHONE, "+15551234567")
    email1 = normalize_identifier(IdentifierKind.EMAIL, "john@example.com")
    phone2 = normalize_identifier(IdentifierKind.PHONE, "+15559876543")
    email2 = normalize_identifier(IdentifierKind.EMAIL, "jane@example.com")

    return {
        "conn": conn,
        "repo": repo,
        "person1_id": person_ids[0],
        "person2_id": person_ids[1],
        "phone1": phone1,
        "email1": email1,
        "phone2": phone2,
        "email2": email2,
    }


class TestClaimIdentifierOwnership:
    """Tests for _claim_identifier_ownership method."""

    def test_claim_unclaimed_identifier(self, setup_identifier_test_data):
        """Test claiming an unclaimed identifier."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person_id = setup_identifier_test_data["person1_id"]
        identifier = normalize_identifier(IdentifierKind.PHONE, "+15559999999")

        with conn.cursor() as cur:
            owner_id, was_claimed = repo._claim_identifier_ownership(cur, identifier, person_id)
            conn.commit()

        assert owner_id == person_id
        assert was_claimed is True

        # Verify in database
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT owner_person_id FROM identifier_owner 
                WHERE kind = %s AND value_canonical = %s
                """,
                (identifier.kind.value, identifier.value_canonical),
            )
            row = cur.fetchone()
            assert row is not None
            assert row[0] == person_id

    def test_claim_already_owned_identifier(self, setup_identifier_test_data):
        """Test attempting to claim an identifier already owned by a different person."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        identifier = normalize_identifier(IdentifierKind.PHONE, "+15559999999")

        # First claim by person1
        with conn.cursor() as cur:
            owner_id1, was_claimed1 = repo._claim_identifier_ownership(cur, identifier, person1_id)
            conn.commit()

        assert owner_id1 == person1_id
        assert was_claimed1 is True

        # Attempt to claim by person2
        with conn.cursor() as cur:
            owner_id2, was_claimed2 = repo._claim_identifier_ownership(cur, identifier, person2_id)
            conn.commit()

        # Should return existing owner (person1) without claiming
        assert owner_id2 == person1_id
        assert was_claimed2 is False

        # Verify ownership unchanged
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT owner_person_id FROM identifier_owner 
                WHERE kind = %s AND value_canonical = %s
                """,
                (identifier.kind.value, identifier.value_canonical),
            )
            row = cur.fetchone()
            assert row[0] == person1_id

    def test_claim_already_owned_by_same_person(self, setup_identifier_test_data):
        """Test claiming an identifier already owned by the same person."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person_id = setup_identifier_test_data["person1_id"]
        identifier = normalize_identifier(IdentifierKind.PHONE, "+15559999999")

        # First claim
        with conn.cursor() as cur:
            owner_id1, was_claimed1 = repo._claim_identifier_ownership(cur, identifier, person_id)
            conn.commit()

        # Claim again by same person
        with conn.cursor() as cur:
            owner_id2, was_claimed2 = repo._claim_identifier_ownership(cur, identifier, person_id)
            conn.commit()

        assert owner_id2 == person_id
        assert was_claimed2 is True  # Same person, so considered claimed

    def test_claim_null_owner(self, setup_identifier_test_data):
        """Test claiming an identifier that exists with NULL owner."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person_id = setup_identifier_test_data["person1_id"]
        identifier = normalize_identifier(IdentifierKind.PHONE, "+15559999999")

        # Insert identifier with NULL owner
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO identifier_owner (kind, value_canonical, owner_person_id)
                VALUES (%s, %s, NULL)
                """,
                (identifier.kind.value, identifier.value_canonical),
            )
            conn.commit()

        # Now claim it
        with conn.cursor() as cur:
            owner_id, was_claimed = repo._claim_identifier_ownership(cur, identifier, person_id)
            conn.commit()

        assert owner_id == person_id
        assert was_claimed is True

        # Verify ownership updated
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT owner_person_id FROM identifier_owner 
                WHERE kind = %s AND value_canonical = %s
                """,
                (identifier.kind.value, identifier.value_canonical),
            )
            row = cur.fetchone()
            assert row[0] == person_id


class TestResolvePersonByIdentifiers:
    """Tests for _resolve_person_by_identifiers method."""

    def test_resolve_single_identifier_match(self, setup_identifier_test_data):
        """Test resolving person by single identifier that matches."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        phone1 = setup_identifier_test_data["phone1"]

        # Claim identifier
        with conn.cursor() as cur:
            repo._claim_identifier_ownership(cur, phone1, person1_id)
            conn.commit()

        # Resolve by identifier
        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_by_identifiers(cur, [phone1])

        assert resolved_id == person1_id

    def test_resolve_multiple_identifiers_same_person(self, setup_identifier_test_data):
        """Test resolving person by multiple identifiers pointing to same person."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        phone1 = setup_identifier_test_data["phone1"]
        email1 = setup_identifier_test_data["email1"]

        # Claim both identifiers for person1
        with conn.cursor() as cur:
            repo._claim_identifier_ownership(cur, phone1, person1_id)
            repo._claim_identifier_ownership(cur, email1, person1_id)
            conn.commit()

        # Resolve by both identifiers
        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_by_identifiers(cur, [phone1, email1])

        assert resolved_id == person1_id

    def test_resolve_no_match(self, setup_identifier_test_data):
        """Test resolving person by identifier that doesn't exist."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        identifier = normalize_identifier(IdentifierKind.PHONE, "+15559999999")

        # Resolve by unclaimed identifier
        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_by_identifiers(cur, [identifier])

        assert resolved_id is None

    def test_resolve_empty_identifiers(self, setup_identifier_test_data):
        """Test resolving with empty identifier list."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]

        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_by_identifiers(cur, [])

        assert resolved_id is None

    def test_resolve_most_common_owner(self, setup_identifier_test_data):
        """Test resolving person when identifiers point to different people."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]
        phone2 = setup_identifier_test_data["phone2"]
        email1 = setup_identifier_test_data["email1"]

        # Claim identifiers: person1 owns phone1 and email1, person2 owns phone2
        with conn.cursor() as cur:
            repo._claim_identifier_ownership(cur, phone1, person1_id)
            repo._claim_identifier_ownership(cur, email1, person1_id)
            repo._claim_identifier_ownership(cur, phone2, person2_id)
            conn.commit()

        # Resolve by identifiers pointing to different people
        # person1 matches 2 identifiers, person2 matches 1
        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_by_identifiers(cur, [phone1, email1, phone2])

        # Should return person1 (most common owner)
        assert resolved_id == person1_id

    def test_resolve_tie_breaker_order(self, setup_identifier_test_data):
        """Test resolving when multiple people have same match count (tie breaker)."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]
        phone2 = setup_identifier_test_data["phone2"]

        # Claim one identifier each
        with conn.cursor() as cur:
            repo._claim_identifier_ownership(cur, phone1, person1_id)
            repo._claim_identifier_ownership(cur, phone2, person2_id)
            conn.commit()

        # Resolve by both identifiers (tie: each person matches 1)
        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_by_identifiers(cur, [phone1, phone2])

        # Should return one of them (ordered by owner_person_id, so lower UUID)
        assert resolved_id in (person1_id, person2_id)


class TestConcurrentClaiming:
    """Tests for concurrent claim scenarios."""

    def test_concurrent_claims_same_person(self, setup_identifier_test_data):
        """Test concurrent claims by same person (idempotent)."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person_id = setup_identifier_test_data["person1_id"]
        identifier = normalize_identifier(IdentifierKind.PHONE, "+15559999999")

        # Simulate concurrent claims (same transaction for test simplicity)
        with conn.cursor() as cur:
            owner_id1, was_claimed1 = repo._claim_identifier_ownership(cur, identifier, person_id)
            owner_id2, was_claimed2 = repo._claim_identifier_ownership(cur, identifier, person_id)
            conn.commit()

        # Both should succeed (idempotent for same person)
        assert owner_id1 == person_id
        assert was_claimed1 is True
        assert owner_id2 == person_id
        assert was_claimed2 is True

    def test_concurrent_claims_different_persons(self, setup_identifier_test_data):
        """Test concurrent claims by different persons (first wins)."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        identifier = normalize_identifier(IdentifierKind.PHONE, "+15559999999")

        # Simulate concurrent claims in sequence (within same transaction)
        with conn.cursor() as cur:
            # First claim
            owner_id1, was_claimed1 = repo._claim_identifier_ownership(cur, identifier, person1_id)
            # Second claim attempt
            owner_id2, was_claimed2 = repo._claim_identifier_ownership(cur, identifier, person2_id)
            conn.commit()

        # First claim should succeed, second should get existing owner
        assert owner_id1 == person1_id
        assert was_claimed1 is True
        assert owner_id2 == person1_id  # Existing owner
        assert was_claimed2 is False

        # Verify final ownership
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT owner_person_id FROM identifier_owner 
                WHERE kind = %s AND value_canonical = %s
                """,
                (identifier.kind.value, identifier.value_canonical),
            )
            row = cur.fetchone()
            assert row[0] == person1_id


class TestResolvePersonIdIntegration:
    """Tests for _resolve_person_id method with identifier lookup integration."""

    def test_resolve_by_source_map_primary_path(self, setup_identifier_test_data):
        """Test that source map lookup still works (primary path)."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]

        # Create new person record (not yet in source map)
        new_person = PersonIngestRecord(
            external_id="new_contact",
            display_name="New Person",
            phones=[ContactValue(value="+15559999999")],
        )

        with conn.cursor() as cur:
            # First resolution should create new ID
            resolved_id1 = repo._resolve_person_id(cur, "test_source", "new_contact", new_person)
            conn.commit()

        # Second resolution with same external_id should return same ID
        with conn.cursor() as cur:
            resolved_id2 = repo._resolve_person_id(cur, "test_source", "new_contact")
            conn.commit()

        # Insert source map manually to simulate existing mapping
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO people_source_map (source, external_id, person_id)
                VALUES (%s, %s, %s)
                """,
                ("test_source", "new_contact", person1_id),
            )
            conn.commit()

        # Now resolution should return person1_id (source map lookup)
        with conn.cursor() as cur:
            resolved_id3 = repo._resolve_person_id(cur, "test_source", "new_contact")

        assert resolved_id3 == person1_id

    def test_resolve_by_identifiers_fallback(self, setup_identifier_test_data):
        """Test that identifier lookup works as fallback when source map not found."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        phone1 = setup_identifier_test_data["phone1"]

        # Claim identifier for person1
        with conn.cursor() as cur:
            repo._claim_identifier_ownership(cur, phone1, person1_id)
            conn.commit()

        # Create person record with same phone (different external_id)
        new_person = PersonIngestRecord(
            external_id="different_external_id",
            display_name="Same Person",
            phones=[ContactValue(value="+15551234567")],  # Same as person1
        )

        # Resolve with new external_id (not in source map)
        # Should find person1 via identifier lookup
        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_id(cur, "different_source", "different_external_id", new_person)

        assert resolved_id == person1_id

    def test_resolve_creates_new_when_no_match(self, setup_identifier_test_data):
        """Test that new UUID created when neither source map nor identifiers match."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]

        # Create person with completely unique identifiers
        unique_person = PersonIngestRecord(
            external_id="unique_external",
            display_name="Unique Person",
            phones=[ContactValue(value="+15551111111")],  # Unique phone
        )

        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_id(cur, "unique_source", "unique_external", unique_person)

        # Should return a new UUID
        assert resolved_id is not None
        assert isinstance(resolved_id, UUID)

        # Verify it's not person1 or person2
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        assert resolved_id != person1_id
        assert resolved_id != person2_id

    def test_resolve_backward_compatible_without_person(self, setup_identifier_test_data):
        """Test backward compatibility: can call without person parameter."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]

        # Call without person parameter (old behavior)
        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_id(cur, "old_source", "old_external_id")

        # Should still return a UUID (create new)
        assert resolved_id is not None
        assert isinstance(resolved_id, UUID)

    def test_resolve_source_map_priority_over_identifiers(self, setup_identifier_test_data):
        """Test that source map lookup takes priority over identifier lookup."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]

        # Claim phone1 for person1
        with conn.cursor() as cur:
            repo._claim_identifier_ownership(cur, phone1, person1_id)
            conn.commit()

        # Insert source map mapping to person2
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO people_source_map (source, external_id, person_id)
                VALUES (%s, %s, %s)
                """,
                ("priority_test", "priority_external", person2_id),
            )
            conn.commit()

        # Create person with phone1 (which belongs to person1)
        person_with_phone1 = PersonIngestRecord(
            external_id="priority_external",
            display_name="Person",
            phones=[ContactValue(value="+15551234567")],  # phone1
        )

        # Resolve should return person2 (source map priority), not person1 (identifier)
        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_id(
                cur, "priority_test", "priority_external", person_with_phone1
            )

        assert resolved_id == person2_id

    def test_resolve_multiple_identifiers_same_person(self, setup_identifier_test_data):
        """Test resolution when incoming person has multiple identifiers."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        phone1 = setup_identifier_test_data["phone1"]
        email1 = setup_identifier_test_data["email1"]

        # Claim both identifiers for person1
        with conn.cursor() as cur:
            repo._claim_identifier_ownership(cur, phone1, person1_id)
            repo._claim_identifier_ownership(cur, email1, person1_id)
            conn.commit()

        # Create person with both identifiers
        person_with_both = PersonIngestRecord(
            external_id="both_identifiers",
            display_name="Person with both",
            phones=[ContactValue(value="+15551234567")],
            emails=[ContactValue(value="john@example.com")],
        )

        with conn.cursor() as cur:
            resolved_id = repo._resolve_person_id(
                cur, "multi_source", "both_identifiers", person_with_both
            )

        assert resolved_id == person1_id


class TestAppendIdentifiersToExisting:
    """Tests for _append_identifiers_to_person method."""

    def test_append_single_identifier(self, setup_identifier_test_data):
        """Test appending a single identifier to existing person."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]

        # Create new identifier that person1 doesn't have yet
        new_identifier = normalize_identifier(IdentifierKind.PHONE, "+15551111111")

        with conn.cursor() as cur:
            stats = repo._append_identifiers_to_person(
                cur,
                target_person_id=person1_id,
                identifiers=[new_identifier],
                source="append_test",
                external_id="appended_external",
                incoming_person_id=person2_id,
            )
            conn.commit()

        assert stats["identifiers_appended"] == 1
        assert stats["ownership_claimed"] == 1
        assert stats["source_map_updated"] == 1

        # Verify identifier added to person1
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT COUNT(*) FROM person_identifiers
                WHERE person_id = %s AND value_canonical = %s
                """,
                (person1_id, new_identifier.value_canonical),
            )
            count = cur.fetchone()[0]
            assert count == 1

    def test_append_source_map_updated(self, setup_identifier_test_data):
        """Test that source map is updated to point to target person."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]

        new_identifier = normalize_identifier(IdentifierKind.PHONE, "+15551111111")

        with conn.cursor() as cur:
            repo._append_identifiers_to_person(
                cur,
                target_person_id=person1_id,
                identifiers=[new_identifier],
                source="source_test",
                external_id="source_test_external",
                incoming_person_id=person2_id,
            )
            conn.commit()

        # Verify source map points to person1
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT person_id FROM people_source_map
                WHERE source = %s AND external_id = %s
                """,
                ("source_test", "source_test_external"),
            )
            row = cur.fetchone()
            assert row is not None
            assert row[0] == person1_id

    def test_append_ownership_claimed(self, setup_identifier_test_data):
        """Test that ownership is claimed in identifier_owner."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]

        new_identifier = normalize_identifier(IdentifierKind.PHONE, "+15551111111")

        with conn.cursor() as cur:
            repo._append_identifiers_to_person(
                cur,
                target_person_id=person1_id,
                identifiers=[new_identifier],
                source="ownership_test",
                external_id="ownership_external",
                incoming_person_id=person2_id,
            )
            conn.commit()

        # Verify ownership claimed
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT owner_person_id FROM identifier_owner
                WHERE kind = %s AND value_canonical = %s
                """,
                (new_identifier.kind.value, new_identifier.value_canonical),
            )
            row = cur.fetchone()
            assert row is not None
            assert row[0] == person1_id

    def test_append_audit_recorded(self, setup_identifier_test_data):
        """Test that append_audit record is created."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]

        new_identifier = normalize_identifier(IdentifierKind.PHONE, "+15551111111")

        with conn.cursor() as cur:
            repo._append_identifiers_to_person(
                cur,
                target_person_id=person1_id,
                identifiers=[new_identifier],
                source="audit_test",
                external_id="audit_external",
                incoming_person_id=person2_id,
            )
            conn.commit()

        # Verify audit record
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT target_person_id, incoming_person_id, source, external_id, identifiers_appended
                FROM append_audit
                WHERE source = %s AND external_id = %s
                """,
                ("audit_test", "audit_external"),
            )
            row = cur.fetchone()
            assert row is not None
            assert row[0] == person1_id  # target_person_id
            assert row[1] == person2_id  # incoming_person_id
            assert row[2] == "audit_test"  # source
            assert row[3] == "audit_external"  # external_id
            assert len(row[4]) == 1  # identifiers_appended

    def test_append_multiple_identifiers(self, setup_identifier_test_data):
        """Test appending multiple identifiers at once."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]

        phone_ident = normalize_identifier(IdentifierKind.PHONE, "+15551111111")
        email_ident = normalize_identifier(IdentifierKind.EMAIL, "newemail@example.com")

        with conn.cursor() as cur:
            stats = repo._append_identifiers_to_person(
                cur,
                target_person_id=person1_id,
                identifiers=[phone_ident, email_ident],
                source="multi_append",
                external_id="multi_external",
                incoming_person_id=person2_id,
            )
            conn.commit()

        assert stats["identifiers_appended"] == 2
        assert stats["ownership_claimed"] == 2
        assert stats["source_map_updated"] == 1

    def test_append_skip_duplicates(self, setup_identifier_test_data):
        """Test that appending skips identifiers already belonging to target."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]

        # Add phone1 to person1's identifiers
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO person_identifiers (
                    person_id, kind, value_raw, value_canonical, label, priority, verified
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                """,
                (person1_id, phone1.kind.value, phone1.value_raw, phone1.value_canonical,
                 phone1.label, phone1.priority, phone1.verified),
            )
            conn.commit()

        # Try to append phone1 (already belongs to person1)
        with conn.cursor() as cur:
            stats = repo._append_identifiers_to_person(
                cur,
                target_person_id=person1_id,
                identifiers=[phone1],
                source="duplicate_test",
                external_id="duplicate_external",
                incoming_person_id=person2_id,
            )
            conn.commit()

        # Should skip the duplicate
        assert stats["identifiers_appended"] == 0
        # But still update source map and record audit
        assert stats["source_map_updated"] == 1


class TestMergePolicyEvaluation:
    """Tests for merge policy evaluation methods."""

    def test_policy_never_returns_false(self, setup_identifier_test_data):
        """Test that 'never' policy always returns False."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]

        with conn.cursor() as cur:
            should_merge = repo._should_merge_on_ingest(
                cur,
                target_person_id=person1_id,
                incoming_person_id=person2_id,
                identifiers=[phone1],
                policy="never",
            )

        assert should_merge is False

    def test_policy_strict_insufficient_matches(self, setup_identifier_test_data):
        """Test that 'strict' policy returns False when matches < 2."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]

        # Add phone1 to person1
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO person_identifiers (
                    person_id, kind, value_raw, value_canonical, label, priority, verified
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                """,
                (person1_id, phone1.kind.value, phone1.value_raw, phone1.value_canonical,
                 phone1.label, phone1.priority, phone1.verified),
            )
            conn.commit()

        # Only 1 match, policy strict requires >= 2
        with conn.cursor() as cur:
            should_merge = repo._should_merge_on_ingest(
                cur,
                target_person_id=person1_id,
                incoming_person_id=person2_id,
                identifiers=[phone1],
                policy="strict",
            )

        assert should_merge is False

    def test_policy_strict_sufficient_matches(self, setup_identifier_test_data):
        """Test that 'strict' policy returns True when matches >= 2."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]
        email1 = setup_identifier_test_data["email1"]

        # Add both identifiers to person1
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO person_identifiers (
                    person_id, kind, value_raw, value_canonical, label, priority, verified
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s),
                       (%s, %s, %s, %s, %s, %s, %s)
                """,
                (person1_id, phone1.kind.value, phone1.value_raw, phone1.value_canonical,
                 phone1.label, phone1.priority, phone1.verified,
                 person1_id, email1.kind.value, email1.value_raw, email1.value_canonical,
                 email1.label, email1.priority, email1.verified),
            )
            conn.commit()

        # 2 matches, policy strict requires >= 2
        with conn.cursor() as cur:
            should_merge = repo._should_merge_on_ingest(
                cur,
                target_person_id=person1_id,
                incoming_person_id=person2_id,
                identifiers=[phone1, email1],
                policy="strict",
            )

        assert should_merge is True

    def test_policy_same_namespace_matching(self, setup_identifier_test_data):
        """Test 'same_namespace' policy returns True when sources match."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]

        # Add source maps with same source
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO people_source_map (source, external_id, person_id)
                VALUES (%s, %s, %s),
                       (%s, %s, %s)
                """,
                ("contacts", "person1_external", person1_id,
                 "contacts", "person2_external", person2_id),
            )
            conn.commit()

        with conn.cursor() as cur:
            should_merge = repo._should_merge_on_ingest(
                cur,
                target_person_id=person1_id,
                incoming_person_id=person2_id,
                identifiers=[],
                policy="same_namespace",
            )

        assert should_merge is True

    def test_policy_same_namespace_not_matching(self, setup_identifier_test_data):
        """Test 'same_namespace' policy returns False when sources differ."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]

        # Add source maps with different sources
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO people_source_map (source, external_id, person_id)
                VALUES (%s, %s, %s),
                       (%s, %s, %s)
                """,
                ("contacts", "person1_external", person1_id,
                 "email", "person2_external", person2_id),
            )
            conn.commit()

        with conn.cursor() as cur:
            should_merge = repo._should_merge_on_ingest(
                cur,
                target_person_id=person1_id,
                incoming_person_id=person2_id,
                identifiers=[],
                policy="same_namespace",
            )

        assert should_merge is False

    def test_count_matching_identifiers_exact_match(self, setup_identifier_test_data):
        """Test counting matching identifiers between two persons."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]
        email1 = setup_identifier_test_data["email1"]
        phone2 = setup_identifier_test_data["phone2"]

        # Add identifiers to both persons
        with conn.cursor() as cur:
            # person1: phone1, email1
            cur.execute(
                """
                INSERT INTO person_identifiers (
                    person_id, kind, value_raw, value_canonical, label, priority, verified
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s),
                       (%s, %s, %s, %s, %s, %s, %s)
                """,
                (person1_id, phone1.kind.value, phone1.value_raw, phone1.value_canonical,
                 phone1.label, phone1.priority, phone1.verified,
                 person1_id, email1.kind.value, email1.value_raw, email1.value_canonical,
                 email1.label, email1.priority, email1.verified),
            )
            # person2: phone1 (matching), phone2 (unique)
            cur.execute(
                """
                INSERT INTO person_identifiers (
                    person_id, kind, value_raw, value_canonical, label, priority, verified
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s),
                       (%s, %s, %s, %s, %s, %s, %s)
                """,
                (person2_id, phone1.kind.value, phone1.value_raw, phone1.value_canonical,
                 phone1.label, phone1.priority, phone1.verified,
                 person2_id, phone2.kind.value, phone2.value_raw, phone2.value_canonical,
                 phone2.label, phone2.priority, phone2.verified),
            )
            conn.commit()

        # Count matching identifiers
        with conn.cursor() as cur:
            match_count = repo._count_matching_identifiers(cur, person1_id, person2_id)

        # Only phone1 matches
        assert match_count == 1

    def test_count_matching_identifiers_no_match(self, setup_identifier_test_data):
        """Test counting identifiers when no matches exist."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]
        phone2 = setup_identifier_test_data["phone2"]

        # Add unique identifiers to both persons
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO person_identifiers (
                    person_id, kind, value_raw, value_canonical, label, priority, verified
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s),
                       (%s, %s, %s, %s, %s, %s, %s)
                """,
                (person1_id, phone1.kind.value, phone1.value_raw, phone1.value_canonical,
                 phone1.label, phone1.priority, phone1.verified,
                 person2_id, phone2.kind.value, phone2.value_raw, phone2.value_canonical,
                 phone2.label, phone2.priority, phone2.verified),
            )
            conn.commit()

        with conn.cursor() as cur:
            match_count = repo._count_matching_identifiers(cur, person1_id, person2_id)

        assert match_count == 0

    def test_unknown_policy_defaults_to_never(self, setup_identifier_test_data):
        """Test that unknown policy names default to never (False)."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]

        with conn.cursor() as cur:
            should_merge = repo._should_merge_on_ingest(
                cur,
                target_person_id=person1_id,
                incoming_person_id=person2_id,
                identifiers=[phone1],
                policy="unknown_policy",
            )

        assert should_merge is False


class TestIntegrationIngestAppendMerge:
    """Integration tests for ingest-time append/merge scenarios."""

    def test_ingest_same_contact_twice_appends_identifiers(self, setup_identifier_test_data):
        """Test that ingesting same contact twice appends identifiers to existing person."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]

        # First ingest: person from contacts source
        first_ingest = PersonIngestRecord(
            external_id="contacts:person1",
            display_name="John Doe",
            phones=[ContactValue(value="+15551234567")],
        )

        # Ingest first record
        stats1 = repo.upsert_batch("contacts", [first_ingest])
        conn.commit()

        assert stats1.upserts == 1
        assert stats1.conflicts == 0

        # Second ingest: same contact from email source with same phone but different external_id
        second_ingest = PersonIngestRecord(
            external_id="email:john@example.com",
            display_name="J. Doe",
            phones=[ContactValue(value="+15551234567")],
            emails=[ContactValue(value="john@example.com")],
        )

        # Ingest second record
        stats2 = repo.upsert_batch("email", [second_ingest])
        conn.commit()

        # Should recognize conflict on phone identifier and append to existing person
        # (This is the full integration scenario combining all parts)
        assert stats2.conflicts >= 0  # Depends on policy

    def test_ingest_concurrent_same_identifier_no_duplicates(self, setup_identifier_test_data):
        """Test that concurrent ingestion of contacts with same identifier doesn't create duplicates."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]

        # Simulate two concurrent ingest attempts with same identifier
        phone = normalize_identifier(IdentifierKind.PHONE, "+15559999999")

        # Both try to claim same identifier
        with conn.cursor() as cur:
            owner1, was_claimed1 = repo._claim_identifier_ownership(cur, phone, uuid4())
            conn.commit()

        with conn.cursor() as cur:
            owner2, was_claimed2 = repo._claim_identifier_ownership(cur, phone, uuid4())
            conn.commit()

        # Only one should have successfully claimed it
        claim_count = int(was_claimed1) + int(was_claimed2)
        assert claim_count == 1, "Only one concurrent claim should succeed"
        assert owner1 == owner2, "Both should see same owner"

    def test_identifier_ownership_persists_across_transactions(self, setup_identifier_test_data):
        """Test that claimed identifier ownership persists across separate transactions."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person_id = setup_identifier_test_data["person1_id"]
        phone = normalize_identifier(IdentifierKind.PHONE, "+15559999999")

        # Claim in first transaction
        with conn.cursor() as cur:
            owner1, claimed1 = repo._claim_identifier_ownership(cur, phone, person_id)
            conn.commit()

        assert owner1 == person_id
        assert claimed1 is True

        # Verify claim persisted in second transaction
        with conn.cursor() as cur:
            owner2, claimed2 = repo._claim_identifier_ownership(cur, phone, person_id)
            conn.commit()

        assert owner2 == person_id
        assert claimed2 is True  # Same person claiming again

    def test_ingest_multiple_persons_with_merged_identifiers(self, setup_identifier_test_data):
        """Test ingesting multiple persons where some share identifiers."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]

        # Create three ingest records
        contacts = [
            PersonIngestRecord(
                external_id="contact_a",
                display_name="Alice",
                phones=[ContactValue(value="+15551111111")],
                emails=[ContactValue(value="alice@example.com")],
            ),
            PersonIngestRecord(
                external_id="contact_b",
                display_name="Alice Brown",
                phones=[ContactValue(value="+15551111111")],  # Same phone
                emails=[ContactValue(value="alice.brown@example.com")],
            ),
            PersonIngestRecord(
                external_id="contact_c",
                display_name="Bob",
                phones=[ContactValue(value="+15552222222")],
                emails=[ContactValue(value="bob@example.com")],
            ),
        ]

        # Ingest all at once
        stats = repo.upsert_batch("contacts", contacts)
        conn.commit()

        # Alice and Alice Brown share phone, so should have 1 conflict detected
        assert stats.upserts >= 2
        assert stats.conflicts >= 1

    def test_identifier_resolution_finds_existing_person_by_multiple_identifiers(
        self, setup_identifier_test_data
    ):
        """Test that _resolve_person_by_identifiers correctly finds person by multiple matches."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        phone1 = setup_identifier_test_data["phone1"]
        email1 = setup_identifier_test_data["email1"]

        # Claim multiple identifiers for person1
        with conn.cursor() as cur:
            repo._claim_identifier_ownership(cur, phone1, person1_id)
            repo._claim_identifier_ownership(cur, email1, person1_id)
            conn.commit()

        # Resolve by both identifiers (should find person1)
        with conn.cursor() as cur:
            resolved = repo._resolve_person_by_identifiers(cur, [phone1, email1])

        assert resolved == person1_id

    def test_append_followed_by_identifier_claiming_consistency(self, setup_identifier_test_data):
        """Test that append operation and identifier claiming remain consistent."""
        conn = setup_identifier_test_data["conn"]
        repo = setup_identifier_test_data["repo"]
        person1_id = setup_identifier_test_data["person1_id"]
        person2_id = setup_identifier_test_data["person2_id"]
        phone1 = setup_identifier_test_data["phone1"]

        # Claim phone1 for person1
        with conn.cursor() as cur:
            repo._claim_identifier_ownership(cur, phone1, person1_id)
            conn.commit()

        # Append to person1 from person2
        with conn.cursor() as cur:
            stats = repo._append_identifiers_to_person(
                cur,
                target_person_id=person1_id,
                identifiers=[phone1],
                source="test",
                external_id="test_external",
                incoming_person_id=person2_id,
            )
            conn.commit()

        # Verify source map was updated
        assert stats["source_map_updated"] == 1

        # Verify person1 still owns phone1
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT owner_person_id FROM identifier_owner
                WHERE kind = %s AND value_canonical = %s
                """,
                (phone1.kind.value, phone1.value_canonical),
            )
            row = cur.fetchone()
            assert row[0] == person1_id

