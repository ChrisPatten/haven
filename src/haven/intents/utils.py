"""Shared utility functions for intent processing."""

from __future__ import annotations

import json
from typing import Any, Dict, List, Optional
from uuid import UUID

import psycopg
from psycopg.rows import dict_row
from psycopg.errors import OperationalError

from shared.db import get_conn_str
from shared.people_normalization import (
    IdentifierKind,
    normalize_email,
    normalize_identifier,
    normalize_phone
)
from shared.people_repository import PeopleResolver


def resolve_sender_name(
    sender_identifier: Optional[str], database_url: Optional[str] = None
) -> Optional[str]:
    """Resolve a sender identifier (phone/email) to a person's display name.
    
    Uses shared normalization functions and queries the identifier_owner table
    (same pattern as PeopleRepository._lookup_identifier_owner).
    
    Args:
        sender_identifier: Phone number or email address to resolve
        database_url: PostgreSQL connection string (defaults to DATABASE_URL env var)
        
    Returns:
        The display_name if found, otherwise returns the original identifier.
    """
    if not sender_identifier:
        return None

    if database_url is None:
        database_url = get_conn_str()

    try:
        # Use shared normalization to determine identifier kind and normalize
        normalized_ident = None
        
        # Try phone first (E.164 format)
        if sender_identifier.startswith("+") or sender_identifier.replace(
            "-", ""
        ).replace(" ", "").replace("(", "").replace(")", "").isdigit():
            try:
                normalized_ident = normalize_identifier(
                    IdentifierKind.PHONE, sender_identifier
                )
            except Exception:
                pass

        # Try email
        if normalized_ident is None and "@" in sender_identifier:
            try:
                normalized_ident = normalize_identifier(
                    IdentifierKind.EMAIL, sender_identifier
                )
            except Exception:
                pass

        if not normalized_ident:
            return f"Normalization failed: {sender_identifier}"  # Return original if we can't normalize

        with psycopg.connect(database_url) as conn:
            resolver = PeopleResolver(conn)
            person = resolver.resolve(kind=normalized_ident.kind, value=normalized_ident.value_canonical)
            if person:
                return person["display_name"]

        return f"Not found: {sender_identifier}"  # Return original if not found
    except OperationalError:
        raise OperationalError(f"Error connecting to database: {database_url}")
        
        return f"Error: {sender_identifier}"  # Return original on error


def _coerce_json_dict(value: Any) -> Optional[Dict[str, Any]]:
    """Coerce a value to a JSON dict, handling both string and dict inputs."""
    if value is None:
        return None
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (json.JSONDecodeError, TypeError):
            return None
    return None


def fetch_thread_context(
    *,
    database_url: Optional[str] = None,
    doc_id: Optional[UUID] = None,
    limit: int = 5,
    time_window_hours: Optional[int] = None,
) -> Optional[List[Dict[str, Any]]]:
    """Fetch recent messages from the same thread for conversational context.
    
    Args:
        database_url: PostgreSQL connection string (defaults to DATABASE_URL env var)
        doc_id: Document ID - if thread_id is None, thread_id will be looked up from this doc
        limit: Maximum number of messages to return (default: 5)
        time_window_hours: Optional time window in hours to limit message search (default: None, no limit)
        
    Returns:
        List of message dicts with keys: text, sender (resolved name), timestamp.
        Returns None if no additional messages found.
        Messages are returned in chronological order (oldest first).
    """
    if not doc_id:
        return None

    if database_url is None:
        database_url = get_conn_str()

    try:
        with psycopg.connect(database_url) as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                query = """
WITH doc_thread AS (
    SELECT doc_id, thread_id, content_timestamp
    FROM documents
    WHERE doc_id = %s
)
SELECT d.text,  
    person->>'identifier' as identifier,
    d.content_timestamp
FROM documents d
CROSS JOIN LATERAL jsonb_array_elements(d.people) as person
INNER JOIN doc_thread ON d.thread_id = doc_thread.thread_id
WHERE 1 = 1
  AND person->>'role' = 'sender'
  AND d.text IS NOT NULL
  AND d.text != ''
  AND d.content_timestamp < doc_thread.content_timestamp
  AND d.content_timestamp > (doc_thread.content_timestamp - INTERVAL '%s hours')
ORDER BY content_timestamp DESC
LIMIT %s
                """
                params: List[Any] = [doc_id, time_window_hours, limit]
                cur.execute(query, params)
                rows = cur.fetchall()

        if not rows:
            return None

        context_messages = []
        for row in rows:
            sender_identifier = row.get("identifier")

            context_messages.append({
                "text": row.get("text") or "",
                "sender": resolve_sender_name(sender_identifier, database_url),
                "from": sender_identifier,  # Keep original identifier for reference
                "timestamp": row.get("content_timestamp"),
            })

        # Reverse to chronological order (oldest first)
        return list(reversed(context_messages))
    except Exception:
        return None

