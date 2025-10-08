from __future__ import annotations

from typing import Any, Dict, List
import re

import psycopg

from shared.people_repository import PeopleResolver
from shared.people_normalization import IdentifierKind, normalize_identifier, normalize_imessage_handle
import os

# Use configured default region for phone normalization/resolution when available
DEFAULT_CONTACTS_REGION = os.getenv("CONTACTS_DEFAULT_REGION", "US")

# Regex pattern to detect messages that are only problematic characters
# Includes: whitespace, object replacement char (FFFC), replacement char (FFFD),
# zero-width spaces (200B-200D), zero-width no-break space/BOM (FEFF)
EMPTY_MESSAGE_PATTERN = re.compile(r'^[\ufffd\ufffc\s\u200b\u200c\u200d\ufeff]+$')


def is_message_text_valid(text: str | None) -> bool:
    """Check if message text is valid (not empty, whitespace-only, or only problematic Unicode).
    
    Returns True if the text contains at least one meaningful character.
    """
    if not text:
        return False
    
    # Strip regular whitespace
    stripped = text.strip()
    if not stripped:
        return False
    
    # Check if it only contains problematic Unicode characters
    if EMPTY_MESSAGE_PATTERN.match(stripped):
        return False
    
    # Remove known problematic characters and whitespace, then check if anything remains
    cleaned = re.sub(r'[\ufffd\ufffc\s\u200b\u200c\u200d\ufeff]+', '', stripped)
    if not cleaned:
        return False
    
    return True


def fetch_context_overview(conn: psycopg.Connection) -> Dict[str, Any]:
    """Run the shared queries for the context/general endpoint and return a plain dict.

    Returns keys: total_threads, total_messages, last_message_ts (datetime|None),
    top_threads (list of dict), recent_highlights (list of dict)
    """
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM threads")
        total_threads = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM messages")
        total_messages = cur.fetchone()[0]

        cur.execute("SELECT max(ts) FROM messages")
        last_message_ts = cur.fetchone()[0]

        cur.execute(
            """
            SELECT m.thread_id, t.title, COUNT(*) AS message_count
            FROM messages m
            JOIN threads t ON t.id = m.thread_id
            GROUP BY m.thread_id, t.title
            ORDER BY message_count DESC
            LIMIT 5
            """
        )
        top_threads = [
            {"thread_id": row[0], "title": row[1], "message_count": row[2]}
            for row in cur.fetchall()
        ]

        cur.execute(
            r"""
            SELECT doc_id, thread_id, ts, sender, text
            FROM messages
            WHERE text IS NOT NULL
              AND btrim(text) <> ''
              -- Filter out object replacement characters and other problematic Unicode
              AND text !~ '^[\uFFFD\uFFFC\s\u200B\u200C\u200D\uFEFF]+$'
              -- Ensure there's at least one printable character
              AND LENGTH(regexp_replace(text, '[\uFFFD\uFFFC\s\u200B\u200C\u200D\uFEFF]+', '', 'g')) > 0
            ORDER BY ts DESC
            LIMIT 5
            """
        )
        recent_rows = [row for row in cur.fetchall()]

        # Build basic recent_highlights list, then try to map sender values
        # (phone/email handles) to ingested contacts and replace the sender
        # display with the person's display_name when available.
        # Apply Python-side validation as an additional safety layer
        recent_highlights = [
            {"doc_id": row[0], "thread_id": row[1], "ts": row[2], "sender": row[3], "text": row[4]}
            for row in recent_rows
            if is_message_text_valid(row[4])
        ]

        # Collect unique senders to resolve (skip empty and local 'me')
        senders = [r[3] for r in recent_rows if r[3] and r[3] != "me"]
        unique_senders = list(dict.fromkeys(senders))  # preserve order

    resolver = PeopleResolver(conn, default_region=DEFAULT_CONTACTS_REGION)

    # Prepare items for resolve_many: try both IMESSAGE and PHONE for numeric
    # handles so that iMessage-style identifiers that are numeric are found.
    items: List[tuple[IdentifierKind, str]] = []
    sender_to_key: Dict[str, str] = {}
    for s in unique_senders:
        # If it's an email-like handle, only treat as EMAIL
        if "@" in s:
            try:
                ident = normalize_identifier(IdentifierKind.EMAIL, s, default_region=DEFAULT_CONTACTS_REGION)
                key = f"{ident.kind.value}:{ident.value_canonical}"
                items.append((IdentifierKind.EMAIL, s))
                sender_to_key[s] = key
            except Exception:
                continue
        else:
            # Non-email: try IMESSAGE (which will canonicalize emails or phones) and PHONE
            # Add two entries but keep a deterministic sender_to_key mapping for the first success.
            try:
                ident_im = normalize_imessage_handle(s, default_region=DEFAULT_CONTACTS_REGION)
                key_im = f"{ident_im.kind.value}:{ident_im.value_canonical}"
                items.append((ident_im.kind, s))
                # don't overwrite existing mapping
                sender_to_key.setdefault(s, key_im)
            except Exception:
                pass
            try:
                ident_ph = normalize_identifier(IdentifierKind.PHONE, s, default_region=DEFAULT_CONTACTS_REGION)
                key_ph = f"{ident_ph.kind.value}:{ident_ph.value_canonical}"
                items.append((IdentifierKind.PHONE, s))
                sender_to_key.setdefault(s, key_ph)
            except Exception:
                pass

    resolved: Dict[str, Dict[str, str]] = {}
    if items:
        try:
            resolved = resolver.resolve_many(items)
        except Exception:
            resolved = {}

    # Apply resolution: when a sender maps to a person, replace with display_name
    for h in recent_highlights:
        s = h.get("sender")
        if not s or s == "me":
            continue
        key = sender_to_key.get(s)
        if not key:
            continue
        person = resolved.get(key)
        if person:
            # replace sender with the ingested contact's display name
            h["sender"] = person.get("display_name") or h["sender"]

    return {
        "total_threads": total_threads,
        "total_messages": total_messages,
        "last_message_ts": last_message_ts,
        "top_threads": top_threads,
        "recent_highlights": recent_highlights,
    }
