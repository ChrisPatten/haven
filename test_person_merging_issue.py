"""
Test to reproduce the bug where person_identifiers are lost when multiple
source contacts with overlapping identifiers are ingested in the same batch.

Bug: When two contacts share an identifier (e.g., phone number) and are ingested
in the same batch, the second contact's identifiers overwrite the first contact's
identifiers because _delete_children removes ALL identifiers before re-adding only
the current contact's identifiers.

Expected: Both contacts should merge to the same person_id, and that person should
have ALL unique identifiers from both contacts.
"""

import sys
from pathlib import Path
from uuid import UUID

# Add project root to path
PROJECT_ROOT = Path(__file__).resolve().parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from shared.db import get_connection
from shared.people_repository import PeopleRepository, PersonIngestRecord, ContactValue


def test_multiple_contacts_merge_keeps_all_identifiers():
    """
    Test that when multiple contacts merge to the same person,
    all identifiers from all contacts are preserved.
    """
    source = "test_macos_contacts"
    
    # Two contacts that share one phone number but have different emails
    contact_a = PersonIngestRecord(
        external_id="contact-A",
        display_name="John Doe A",
        phones=[
            ContactValue(value="+11234567890", value_raw="(123) 456-7890", label="mobile"),
        ],
        emails=[
            ContactValue(value="john.a@example.com", value_raw="john.a@example.com", label="work"),
        ],
    )
    
    contact_b = PersonIngestRecord(
        external_id="contact-B",
        display_name="John Doe B",
        phones=[
            ContactValue(value="+11234567890", value_raw="123-456-7890", label="home"),
        ],
        emails=[
            ContactValue(value="john.b@example.com", value_raw="john.b@example.com", label="personal"),
        ],
    )
    
    with get_connection(autocommit=False) as conn:
        repo = PeopleRepository(conn, default_region="US")
        
        # Ingest both contacts in the same batch
        stats = repo.upsert_batch(source, [contact_a, contact_b])
        conn.commit()
        
        print(f"\nUpsert stats: {stats}")
        
        # Debug: Check identifier_owner table
        with conn.cursor() as cur:
            cur.execute("""
                SELECT kind, value_canonical, owner_person_id
                FROM identifier_owner
                ORDER BY kind, value_canonical
            """)
            print(f"\nIdentifier ownership:")
            for kind, value, owner_id in cur.fetchall():
                print(f"  {kind}: {value} → {owner_id}")
        
        # Query person_identifiers to see what we actually have
        with conn.cursor() as cur:
            cur.execute("""
                SELECT p.person_id, p.display_name, pi.kind, pi.value_canonical, pi.label
                FROM people p
                LEFT JOIN person_identifiers pi ON pi.person_id = p.person_id
                WHERE p.source = %s
                ORDER BY p.person_id, pi.kind, pi.value_canonical
            """, (source,))
            rows = cur.fetchall()
            
            print(f"\nPerson identifiers in database:")
            current_person = None
            for person_id, display_name, kind, value_canonical, label in rows:
                if person_id != current_person:
                    current_person = person_id
                    print(f"\n  Person {person_id} ({display_name}):")
                if kind:
                    print(f"    - {kind}: {value_canonical} ({label})")
            
            # Count unique person_ids
            cur.execute("""
                SELECT COUNT(DISTINCT person_id)
                FROM people
                WHERE source = %s
            """, (source,))
            person_count = cur.fetchone()[0]
            
            print(f"\nTotal persons created: {person_count}")
            
            # Count identifiers per person
            cur.execute("""
                SELECT person_id, COUNT(*) as identifier_count
                FROM person_identifiers pi
                WHERE person_id IN (SELECT person_id FROM people WHERE source = %s)
                GROUP BY person_id
            """, (source,))
            identifier_counts = cur.fetchall()
            
            print(f"\nIdentifier counts per person:")
            for person_id, count in identifier_counts:
                print(f"  Person {person_id}: {count} identifiers")
            
            # Expected: 1 person with 3 identifiers (1 phone, 2 emails)
            assert person_count == 1, f"Expected 1 person, got {person_count}"
            assert len(identifier_counts) == 1, f"Expected 1 person with identifiers, got {len(identifier_counts)}"
            assert identifier_counts[0][1] == 3, f"Expected 3 identifiers, got {identifier_counts[0][1]}"
            
            # Verify we have both emails
            cur.execute("""
                SELECT value_canonical
                FROM person_identifiers
                WHERE person_id IN (SELECT person_id FROM people WHERE source = %s)
                  AND kind = 'email'
                ORDER BY value_canonical
            """, (source,))
            emails = [row[0] for row in cur.fetchall()]
            
            print(f"\nEmails found: {emails}")
            assert len(emails) == 2, f"Expected 2 emails, got {len(emails)}"
            assert "john.a@example.com" in emails, "Missing email from contact A"
            assert "john.b@example.com" in emails, "Missing email from contact B"
            
        # Rollback to clean up test data
        conn.rollback()
        
    print("\n✅ Test passed! All identifiers preserved when contacts merge.")


if __name__ == "__main__":
    test_multiple_contacts_merge_keeps_all_identifiers()
