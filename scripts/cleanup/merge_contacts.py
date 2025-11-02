#!/usr/bin/env python3
"""
Contact merge tool for discovering and merging duplicate contacts by phone/email identifiers.

Usage:
  # Dry-run (default): discover duplicates without making changes
  python scripts/cleanup/merge_contacts.py --dry-run

  # Apply: actually perform merges
  python scripts/cleanup/merge_contacts.py --apply

  # Output results to JSON
  python scripts/cleanup/merge_contacts.py --dry-run --output report.json

  # Filter by date range
  python scripts/cleanup/merge_contacts.py --dry-run --since 2025-01-01

Examples:
  # Find all duplicates without making changes
  python scripts/cleanup/merge_contacts.py

  # Apply merges for all discovered duplicates
  python scripts/cleanup/merge_contacts.py --apply

  # Get detailed report in JSON format
  python scripts/cleanup/merge_contacts.py --dry-run --output duplicates.json
"""

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List
from uuid import UUID

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from shared.db import get_connection
from shared.people_normalization import find_duplicate_candidates
from shared.people_repository import PeopleRepository
from shared.logging import get_logger

logger = get_logger("cleanup.merge_contacts")


def load_config_from_env() -> Dict[str, Any]:
    """Load database configuration from environment variables."""
    db_url = os.getenv("DATABASE_URL")
    if not db_url:
        # Try individual components
        db_host = os.getenv("DB_HOST", "localhost")
        db_port = os.getenv("DB_PORT", "5432")
        db_user = os.getenv("DB_USER", "postgres")
        db_password = os.getenv("DB_PASSWORD", "postgres")
        db_name = os.getenv("DB_NAME", "haven")
        db_url = f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
    
    return {
        "database_url": db_url,
        "default_region": os.getenv("CONTACTS_DEFAULT_REGION", "US"),
    }


def find_duplicates(conn, limit: int | None = None) -> List[Dict[str, Any]]:
    """Discover duplicate contact candidates."""
    duplicates = find_duplicate_candidates(conn)
    if limit:
        duplicates = duplicates[:limit]
    return duplicates


def merge_group(
    repo: PeopleRepository,
    person_ids: List[UUID],
    strategy: str,
    actor: str,
    dry_run: bool = True,
) -> Dict[str, Any]:
    """
    Merge a group of duplicate contacts.
    
    Selects the first person_id as target and merges all others into it.
    """
    if len(person_ids) < 2:
        return {"error": "Need at least 2 person_ids to merge"}
    
    target_id = person_ids[0]
    source_ids = person_ids[1:]
    
    try:
        if dry_run:
            return {
                "target_id": str(target_id),
                "source_ids": [str(s) for s in source_ids],
                "count": len(person_ids),
                "status": "would_merge",
                "dry_run": True,
            }
        else:
            result = repo.merge_people(
                target_id=target_id,
                source_ids=source_ids,
                strategy=strategy,
                actor=actor,
            )
            result["status"] = "merged"
            result["dry_run"] = False
            return result
    except Exception as e:
        logger.error(f"Failed to merge group: {str(e)}", exc_info=True)
        return {
            "target_id": str(target_id),
            "source_ids": [str(s) for s in source_ids],
            "status": "error",
            "error": str(e),
        }


def main():
    parser = argparse.ArgumentParser(
        description="Discover and merge duplicate contacts by phone/email identifiers"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=True,
        help="Report what would be merged without making changes (default)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually perform the merges",
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Output file path for JSON report",
    )
    parser.add_argument(
        "--strategy",
        type=str,
        choices=["prefer_target", "prefer_source", "merge_non_null"],
        default="prefer_target",
        help="Merge strategy for combining attributes",
    )
    parser.add_argument(
        "--actor",
        type=str,
        default="merge_contacts_cli",
        help="Actor name for audit logging",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Limit number of duplicate groups to process",
    )
    parser.add_argument(
        "--database-url",
        type=str,
        default=None,
        help="Database URL (or use DATABASE_URL env var)",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Verbose output",
    )

    args = parser.parse_args()

    # Determine if apply or dry-run
    apply_mode = args.apply
    if args.apply and args.dry_run:
        # If both flags provided, apply takes precedence
        apply_mode = True
    
    mode = "apply" if apply_mode else "dry-run"
    
    # Load configuration
    config = load_config_from_env()
    if args.database_url:
        # Override the DATABASE_URL environment variable
        os.environ["DATABASE_URL"] = args.database_url

    print(f"Contact Merge Tool - {mode.upper()} mode")
    print(f"Strategy: {args.strategy}")
    print(f"Actor: {args.actor}")
    if args.limit:
        print(f"Limit: {args.limit} groups")
    print()

    # Connect to database and run the merge process
    with get_connection() as conn:
        try:
            # Find duplicates
            print("Discovering duplicate contacts...", end=" ", flush=True)
            duplicates = find_duplicates(conn, limit=args.limit)
            print(f"Found {len(duplicates)} duplicate groups")
            print()

            if not duplicates:
                print("No duplicates found.")
                return 0

            # Initialize repository
            repo = PeopleRepository(conn, default_region=config.get("default_region"))

            # Process each group
            results = []
            merged_count = 0
            error_count = 0

            for i, dup_group in enumerate(duplicates, 1):
                kind = dup_group["kind"]
                value_canonical = dup_group["value_canonical"]
                person_ids = [UUID(pid) for pid in dup_group["person_ids"]]
                count = len(person_ids)

                if args.verbose:
                    print(
                        f"[{i}/{len(duplicates)}] {kind}: {value_canonical[:20]}... "
                        f"({count} contacts)",
                        end=" ",
                        flush=True,
                    )

                result = merge_group(
                    repo,
                    person_ids,
                    strategy=args.strategy,
                    actor=args.actor,
                    dry_run=not apply_mode,
                )
                results.append(
                    {
                        "group": i,
                        "identifier": {"kind": kind, "value": value_canonical},
                        "merge_result": result,
                    }
                )

                if result.get("status") == "merged":
                    merged_count += 1
                    if args.verbose:
                        print(f"✓ merged")
                elif result.get("status") == "error":
                    error_count += 1
                    if args.verbose:
                        print(f"✗ error: {result.get('error')}")
                elif result.get("status") == "would_merge":
                    if args.verbose:
                        print(f"→ would merge")

            print()
            print("=" * 60)
            print(f"Total groups: {len(duplicates)}")
            print(f"Merged: {merged_count}")
            print(f"Errors: {error_count}")
            print(f"Mode: {mode.upper()}")

            # Output results if requested
            if args.output:
                output_path = Path(args.output)
                output_path.parent.mkdir(parents=True, exist_ok=True)

                output_data = {
                    "timestamp": datetime.now().isoformat(),
                    "mode": mode,
                    "strategy": args.strategy,
                    "actor": args.actor,
                    "total_groups": len(duplicates),
                    "merged": merged_count,
                    "errors": error_count,
                    "results": results,
                }

                with open(output_path, "w") as f:
                    json.dump(output_data, f, indent=2, default=str)

                print(f"Report written to: {output_path}")

            return 0

        except Exception as e:
            logger.exception("merge_contacts_failed", error=str(e))
            print(f"Error: {str(e)}", file=sys.stderr)
            return 1


if __name__ == "__main__":
    sys.exit(main())
