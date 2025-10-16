from __future__ import annotations

from typing import Any, Dict, List
import unicodedata

import psycopg

# Set of explicit disallowed codepoints (object/replacement/zero-width/BOM)
_DISALLOWED_CODEPOINTS = {
    "\uFFFD",  # replacement character
    "\uFFFC",  # object replacement character
    "\u200B",  # zero-width space
    "\u200C",  # zero-width non-joiner
    "\u200D",  # zero-width joiner
    "\uFEFF",  # zero-width no-break space (BOM)
}


def is_message_text_valid(text: str | None) -> bool:
    """Return True when text contains meaningful content."""
    if not text:
        return False

    stripped = text.strip()
    normalized = unicodedata.normalize("NFKC", stripped)

    if normalized in _DISALLOWED_CODEPOINTS:
        return False

    cleaned_chars: List[str] = []
    for ch in normalized:
        if ch in _DISALLOWED_CODEPOINTS:
            continue
        cat = unicodedata.category(ch)
        if cat[0] == "C":
            continue
        if cat in {"Zl", "Zp"}:
            continue
        cleaned_chars.append(ch)

    cleaned = "".join(cleaned_chars).strip()
    if not cleaned:
        return False

    return any(unicodedata.category(ch)[0] in {"L", "N", "P", "S"} for ch in cleaned)


def fetch_context_overview(conn: psycopg.Connection) -> Dict[str, Any]:
    """Return aggregated context information derived from unified documents."""
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM threads")
        total_threads = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM documents WHERE is_active_version = true")
        total_documents = cur.fetchone()[0]

        cur.execute(
            """
            SELECT max(content_timestamp)
            FROM documents
            WHERE is_active_version = true
            """
        )
        last_document_timestamp = cur.fetchone()[0]

        cur.execute(
            """
            SELECT d.thread_id, t.title, COUNT(*) AS message_count
            FROM documents d
            LEFT JOIN threads t ON t.thread_id = d.thread_id
            WHERE d.is_active_version = true
              AND d.thread_id IS NOT NULL
            GROUP BY d.thread_id, t.title
            ORDER BY message_count DESC
            LIMIT 5
            """
        )
        top_threads = [
            {"thread_id": row[0], "title": row[1], "message_count": row[2]}
            for row in cur.fetchall()
        ]

        cur.execute(
            """
            SELECT doc_id, thread_id, content_timestamp, text, people
            FROM documents
            WHERE is_active_version = true
              AND text IS NOT NULL
              AND btrim(text) <> ''
            ORDER BY content_timestamp DESC
            LIMIT 30
            """
        )
        candidates = cur.fetchall()

    recent_highlights: List[Dict[str, Any]] = []
    for doc_id, thread_id, content_timestamp, text, people in candidates:
        if not is_message_text_valid(text):
            continue
        recent_highlights.append(
            {
                "doc_id": doc_id,
                "thread_id": thread_id,
                "content_timestamp": content_timestamp,
                "text": text,
                "people": people or [],
            }
        )
        if len(recent_highlights) == 5:
            break

    return {
        "total_threads": total_threads,
        "total_messages": total_documents,
        "last_message_ts": last_document_timestamp,
        "top_threads": top_threads,
        "recent_highlights": recent_highlights,
    }
