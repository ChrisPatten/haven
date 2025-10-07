from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List

import psycopg


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
            """
            SELECT doc_id, thread_id, ts, sender, text
            FROM messages
            WHERE text IS NOT NULL
              AND btrim(text) <> ''
            ORDER BY ts DESC
            LIMIT 5
            """
        )
        recent_highlights = [
            {"doc_id": row[0], "thread_id": row[1], "ts": row[2], "sender": row[3], "text": row[4]}
            for row in cur.fetchall()
        ]

    return {
        "total_threads": total_threads,
        "total_messages": total_messages,
        "last_message_ts": last_message_ts,
        "top_threads": top_threads,
        "recent_highlights": recent_highlights,
    }
