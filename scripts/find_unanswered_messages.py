#!/usr/bin/env python3
"""
Find people you've forgotten to respond to from the past 6 months.

This script identifies threads where:
- The last message is from someone else (not you)
- Enough time has passed (default: 24 hours) since that message
- The conversation happened in the past 6 months

Usage:
    python scripts/find_unanswered_messages.py
    python scripts/find_unanswered_messages.py --min-hours 48
    python scripts/find_unanswered_messages.py --output .tmp/unanswered.md
"""

import argparse
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any
from collections import defaultdict

# Import database utilities from Haven
try:
    from shared.db import get_connection, get_self_person_data, resolve_people_from_identifiers
    from shared.context import is_message_text_valid
except ImportError:
    print("Error: shared modules not available. Make sure 'shared' is in PYTHONPATH")
    sys.exit(1)

os.environ["DATABASE_URL"] = "postgresql://postgres:postgres@localhost:5432/haven"


def _normalize_identifier(identifier: Optional[str]) -> Optional[str]:
    """Normalize an identifier by stripping source prefixes.
    
    Documents store identifiers with prefixes like 'E:' for email or 'P:' for phone.
    This strips those prefixes so they match the canonical identifiers in person_identifiers.
    """
    if not identifier:
        return None
    
    # Strip common source/type prefixes (E: for email, P: for phone, etc.)
    if ':' in identifier:
        parts = identifier.split(':', 1)
        if len(parts) == 2 and len(parts[0]) == 1:  # Single-letter prefix
            return parts[1]
    
    return identifier


def get_unanswered_threads(
    months_back: int = 6,
    min_hours_since_last_message: int = 24,
    max_results: Optional[int] = None
) -> List[Dict[str, Any]]:
    """Find threads where the user hasn't responded to the last message.
    
    Args:
        months_back: How many months back to look (default: 6)
        min_hours_since_last_message: Minimum hours since last message to consider it "forgotten" (default: 24)
        max_results: Maximum number of results to return (None = all)
    
    Returns:
        List of dicts with thread info, last message info, and person info
    """
    # Get user's identifiers
    self_person_data = get_self_person_data()
    if not self_person_data:
        print("Error: self_person_id not set in system_settings. Cannot identify user messages.")
        return []
    
    self_person, user_identifiers = self_person_data
    user_identifier_set = {uid.lower() for uid in user_identifiers.keys()}
    
    # Calculate time window (use UTC for consistency with database)
    now = datetime.now(timezone.utc)
    cutoff_date = now - timedelta(days=months_back * 30)
    min_time_ago = now - timedelta(hours=min_hours_since_last_message)
    
    unanswered_threads = []
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            # Query to find threads where:
            # 1. Last message is from someone else (not the user)
            # 2. Last message is older than min_hours_since_last_message
            # 3. Thread has activity in the past 6 months
            query = """
            WITH thread_last_messages AS (
                -- Get the most recent message for each thread
                SELECT DISTINCT ON (d.thread_id)
                    d.thread_id,
                    d.doc_id,
                    d.content_timestamp,
                    d.text,
                    d.people,
                    d.source_type,
                    t.external_id as thread_external_id,
                    t.title as thread_title,
                    t.source_type as thread_source_type
                FROM documents d
                JOIN threads t ON d.thread_id = t.thread_id
                WHERE d.is_active_version = true
                    AND d.thread_id IS NOT NULL
                    AND d.content_timestamp >= %s
                    AND d.content_timestamp <= %s
                ORDER BY d.thread_id, d.content_timestamp DESC
            )
            SELECT 
                tlm.thread_id,
                tlm.doc_id,
                tlm.content_timestamp,
                tlm.text,
                tlm.people,
                tlm.source_type,
                tlm.thread_external_id,
                tlm.thread_title,
                tlm.thread_source_type
            FROM thread_last_messages tlm
            WHERE tlm.content_timestamp <= %s
            ORDER BY tlm.content_timestamp DESC
            """
            
            cur.execute(query, (cutoff_date, now, min_time_ago))
            rows = cur.fetchall()
            
            # Collect all identifiers that need resolution
            identifiers_to_resolve = set()
            for row in rows:
                _, _, _, _, people_data, _, _, _, _ = row
                if people_data:
                    for person in people_data:
                        raw_identifier = person.get("identifier")
                        if raw_identifier:
                            normalized = _normalize_identifier(raw_identifier)
                            if normalized:
                                identifiers_to_resolve.add(normalized)
            
            # Resolve all identifiers in batch
            people_lookup = resolve_people_from_identifiers(list(identifiers_to_resolve))
            
            # Process each thread
            for row in rows:
                thread_id, doc_id, content_ts, text, people_data, source_type, thread_external_id, thread_title, thread_source_type = row
                
                # Ensure content_ts is timezone-aware (should be from Postgres TIMESTAMPTZ, but be safe)
                if content_ts.tzinfo is None:
                    content_ts = content_ts.replace(tzinfo=timezone.utc)
                
                # Skip invalid messages
                if not is_message_text_valid(text):
                    continue
                
                # Check if last message is from the user
                is_user_message = False
                sender_identifier = None
                sender_name = "Unknown"
                
                if people_data:
                    for person in people_data:
                        if person.get("role") == "sender":
                            raw_identifier = person.get("identifier")
                            sender_identifier = _normalize_identifier(raw_identifier)
                            
                            if sender_identifier:
                                # Check if sender is the user
                                is_user_message = sender_identifier.lower() in user_identifier_set
                                
                                # Get sender name from resolved people
                                if sender_identifier in people_lookup:
                                    resolved_person, _ = people_lookup[sender_identifier]
                                    sender_name = resolved_person.display_name or sender_identifier
                                else:
                                    sender_name = raw_identifier or "Unknown"
                            break
                
                # Skip if last message is from the user (they already responded)
                if is_user_message:
                    continue
                
                # Calculate days since last message
                days_ago = (now - content_ts).total_seconds() / 86400
                
                unanswered_threads.append({
                    "thread_id": str(thread_id),
                    "thread_external_id": thread_external_id,
                    "thread_title": thread_title or thread_external_id,
                    "thread_source_type": thread_source_type,
                    "last_message_id": str(doc_id),
                    "last_message_timestamp": content_ts,
                    "last_message_text": text[:200] + "..." if len(text) > 200 else text,  # Truncate for display
                    "sender_name": sender_name,
                    "sender_identifier": sender_identifier,
                    "days_ago": days_ago,
                    "source_type": source_type
                })
                
                if max_results and len(unanswered_threads) >= max_results:
                    break
    
    return unanswered_threads


def group_by_person(unanswered_threads: List[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    """Group unanswered threads by person (sender of last message)."""
    grouped = defaultdict(list)
    
    for thread in unanswered_threads:
        # Use sender_name as key, fallback to identifier
        key = thread["sender_name"] or thread["sender_identifier"] or "Unknown"
        grouped[key].append(thread)
    
    return dict(grouped)


def generate_markdown_report(
    unanswered_threads: List[Dict[str, Any]],
    grouped_by_person: Dict[str, List[Dict[str, Any]]],
    months_back: int,
    min_hours: int
) -> str:
    """Generate a markdown report of unanswered messages."""
    lines = []
    lines.append("# Unanswered Messages Report")
    lines.append("")
    lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")
    lines.append(f"**Time Window**: Past {months_back} months")
    lines.append(f"**Minimum Hours Since Last Message**: {min_hours} hours")
    lines.append("")
    
    # Summary
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- **Total Unanswered Threads**: {len(unanswered_threads)}")
    lines.append(f"- **Unique People**: {len(grouped_by_person)}")
    lines.append("")
    
    # Grouped by person
    lines.append("## By Person")
    lines.append("")
    
    # Sort people by number of unanswered threads (most first)
    sorted_people = sorted(
        grouped_by_person.items(),
        key=lambda x: (len(x[1]), -min(t["days_ago"] for t in x[1])),  # Count, then most recent
        reverse=True
    )
    
    for person_name, threads in sorted_people:
        lines.append(f"### {person_name} ({len(threads)} thread{'s' if len(threads) != 1 else ''})")
        lines.append("")
        
        # Sort threads by most recent first
        threads_sorted = sorted(threads, key=lambda t: t["days_ago"])
        
        for thread in threads_sorted:
            days = int(thread["days_ago"])
            hours = int((thread["days_ago"] - days) * 24)
            
            lines.append(f"**{thread['thread_title']}** ({thread['thread_source_type']})")
            lines.append(f"- Last message: {days} days, {hours} hours ago")
            lines.append(f"- Timestamp: {thread['last_message_timestamp'].strftime('%Y-%m-%d %H:%M:%S')}")
            lines.append(f"- Preview: {thread['last_message_text']}")
            lines.append("")
    
    # All threads (chronological)
    lines.append("## All Threads (Chronological)")
    lines.append("")
    
    # Sort all threads by most recent first
    sorted_threads = sorted(unanswered_threads, key=lambda t: t["days_ago"])
    
    for thread in sorted_threads:
        days = int(thread["days_ago"])
        hours = int((thread["days_ago"] - days) * 24)
        
        lines.append(f"### {thread['thread_title']}")
        lines.append("")
        lines.append(f"- **From**: {thread['sender_name']}")
        lines.append(f"- **Source**: {thread['thread_source_type']}")
        lines.append(f"- **Last message**: {days} days, {hours} hours ago ({thread['last_message_timestamp'].strftime('%Y-%m-%d %H:%M:%S')})")
        lines.append(f"- **Preview**: {thread['last_message_text']}")
        lines.append("")
    
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Find people you've forgotten to respond to from the past 6 months"
    )
    parser.add_argument(
        "--months-back",
        type=int,
        default=6,
        help="How many months back to look (default: 6)"
    )
    parser.add_argument(
        "--min-hours",
        type=int,
        default=24,
        help="Minimum hours since last message to consider it 'forgotten' (default: 24)"
    )
    parser.add_argument(
        "--max-results",
        type=int,
        default=None,
        help="Maximum number of results to return (default: all)"
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Output file path (default: print to stdout)"
    )
    
    args = parser.parse_args()
    
    # Get project root for default output path
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    
    print(f"Finding unanswered messages from the past {args.months_back} months...")
    print(f"Minimum hours since last message: {args.min_hours}")
    print()
    
    unanswered_threads = get_unanswered_threads(
        months_back=args.months_back,
        min_hours_since_last_message=args.min_hours,
        max_results=args.max_results
    )
    
    if not unanswered_threads:
        print("No unanswered messages found!")
        return
    
    # Group by person
    grouped_by_person = group_by_person(unanswered_threads)
    
    # Generate report
    report = generate_markdown_report(
        unanswered_threads,
        grouped_by_person,
        args.months_back,
        args.min_hours
    )
    
    # Output
    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, 'w') as f:
            f.write(report)
        print(f"Report written to: {output_path}")
    else:
        print(report)
    
    # Print summary to console
    print()
    print("=" * 60)
    print(f"Found {len(unanswered_threads)} unanswered threads from {len(grouped_by_person)} people")
    print("=" * 60)
    
    # Show top 5 people by count
    sorted_people = sorted(
        grouped_by_person.items(),
        key=lambda x: len(x[1]),
        reverse=True
    )
    
    print("\nTop people with unanswered messages:")
    for person_name, threads in sorted_people[:5]:
        print(f"  - {person_name}: {len(threads)} thread{'s' if len(threads) != 1 else ''}")


if __name__ == "__main__":
    main()

