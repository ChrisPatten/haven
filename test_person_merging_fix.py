#!/usr/bin/env python3
"""
Test to verify that contact ingestion properly merges people based on shared identifiers.
This test simulates the issue where two VCF files representing the same person
should be merged but weren't due to empty identifier_owner table.
"""

import sys
from pathlib import Path
from uuid import uuid4

PROJECT_ROOT = Path(__file__).resolve().parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from shared.people_repository import (
    PersonIngestRecord,
    ContactValue,
    PeopleRepository,
    UpsertStats,
)
from shared.people_normalization import IdentifierKind, normalize_identifier
from shared.db import get_connection


def test_person_merging_with_shared_phone():
    """
    Test that two contacts with shared identifiers get merged.
    
    First contact (Christopher Patten):
    - phone: +16179971267
    - emails: mrwhistler@gmail.com, chris.patten@slalom.com, netitibydow@yahoo.com
    
    Second contact (Chris Patten):
    - email: netitibydow@yahoo.com (same as first contact)
    
    Expected: Second contact should resolve to first person via shared email
    """
    with get_connection(autocommit=False) as conn:
        repo = PeopleRepository(conn, default_region="US")
        
        # First contact
        contact1 = PersonIngestRecord(
            external_id="vcf_christopher_patten",
            display_name="Christopher Patten",
            given_name="Christopher",
            family_name="Patten",
            organization="Slalom",
            nicknames=("Chris",),
            phones=[
                ContactValue(value="+16179971267", value_raw="617-997-1267", label="other")
            ],
            emails=[
                ContactValue(value="mrwhistler@gmail.com", value_raw="mrwhistler@gmail.com", label="other"),
                ContactValue(value="chris.patten@slalom.com", value_raw="chris.patten@slalom.com", label="other"),
                ContactValue(value="netitibydow@yahoo.com", value_raw="netitibydow@yahoo.com", label="other"),
            ],
        )
        
        # Ingest first contact
        stats1 = repo.upsert_batch("test_source", [contact1])
        print(f"First contact ingestion: {stats1.as_dict()}")
        
        # Get the person_id for first contact
        with conn.cursor() as cur:
            cur.execute(
                "SELECT person_id FROM people_source_map WHERE source = %s AND external_id = %s",
                ("test_source", "vcf_christopher_patten"),
            )
            person1_id = cur.fetchone()[0]
            print(f"First contact person_id: {person1_id}")
        
        # Second contact with different external_id but shared email
        contact2 = PersonIngestRecord(
            external_id="vcf_chris_patten",
            display_name="Chris Patten",
            given_name="Chris",
            family_name="Patten",
            emails=[
                ContactValue(value="netitibydow@yahoo.com", value_raw="netitibydow@yahoo.com", label="other"),
            ],
        )
        
        # Ingest second contact
        stats2 = repo.upsert_batch("test_source", [contact2])
        print(f"Second contact ingestion: {stats2.as_dict()}")
        
        # Get the person_id for second contact
        with conn.cursor() as cur:
            cur.execute(
                "SELECT person_id FROM people_source_map WHERE source = %s AND external_id = %s",
                ("test_source", "vcf_chris_patten"),
            )
            person2_row = cur.fetchone()
            if person2_row:
                person2_id = person2_row[0]
                print(f"Second contact person_id: {person2_id}")
                
                if person1_id == person2_id:
                    print("✓ SUCCESS: Both contacts resolved to the same person_id (merged)")
                    return True
                else:
                    print("✗ FAILURE: Contacts created separate people")
                    print(f"  Expected: {person1_id}")
                    print(f"  Got: {person2_id}")
                    return False
            else:
                print("✗ FAILURE: Second contact not found in people_source_map")
                return False


if __name__ == "__main__":
    try:
        success = test_person_merging_with_shared_phone()
        sys.exit(0 if success else 1)
    except Exception as e:
        print(f"✗ TEST ERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
