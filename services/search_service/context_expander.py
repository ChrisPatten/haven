"""Context expansion for iMessage search hits with surrounding messages."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional
from uuid import UUID

from psycopg.rows import dict_row

from haven.search.db import get_connection
from shared.logging import get_logger

from .models_v2 import SearchDocument

logger = get_logger("search.context")


class ContextExpander:
    """Expands iMessage search hits with surrounding messages from the same thread."""

    def __init__(
        self,
        lookback_hours: int = 8,
        lookahead_hours: int = 2,
        max_messages: int = 10,
    ):
        """Initialize context expander.
        
        Args:
            lookback_hours: Hours to look back from hit timestamp (default: 8)
            lookahead_hours: Hours to look ahead from hit timestamp (default: 2)
            max_messages: Maximum number of context messages per hit (default: 10)
        """
        self.lookback_hours = lookback_hours
        self.lookahead_hours = lookahead_hours
        self.max_messages = max_messages

    async def expand_imessage_context(
        self,
        hits: List[Any],  # SearchHit from haven.search
    ) -> List[Dict[str, Any]]:
        """Expand iMessage hits with surrounding messages.
        
        Args:
            hits: List of SearchHit objects, filtered to iMessage hits
            
        Returns:
            List of expanded context documents as dictionaries
        """
        expanded = []
        seen_doc_ids = set()
        
        # Filter to iMessage hits only
        imessage_hits = [
            h for h in hits
            if h.metadata.get("source_type") == "imessage"
            and h.metadata.get("thread_id")
        ]
        
        if not imessage_hits:
            return expanded
        
        async with get_connection() as conn:
            async with conn.cursor(row_factory=dict_row) as cur:
                for hit in imessage_hits:
                    doc_id_str = hit.document_id
                    thread_id_str = hit.metadata.get("thread_id")
                    hit_timestamp = hit.metadata.get("content_timestamp")
                    
                    if not thread_id_str or not hit_timestamp:
                        continue
                    
                    try:
                        thread_uuid = UUID(thread_id_str)
                        doc_uuid = UUID(doc_id_str)
                    except ValueError:
                        logger.warning(
                            "invalid_uuid",
                            thread_id=thread_id_str,
                            doc_id=doc_id_str,
                        )
                        continue
                    
                    # Parse timestamp if it's a string
                    if isinstance(hit_timestamp, str):
                        try:
                            hit_timestamp = datetime.fromisoformat(
                                hit_timestamp.replace("Z", "+00:00")
                            )
                        except ValueError:
                            logger.warning(
                                "invalid_timestamp",
                                timestamp=hit_timestamp,
                            )
                            continue
                    
                    if not isinstance(hit_timestamp, datetime):
                        continue
                    
                    # Ensure timezone-aware
                    if hit_timestamp.tzinfo is None:
                        hit_timestamp = hit_timestamp.replace(tzinfo=timezone.utc)
                    
                    # Calculate time window
                    start_time = hit_timestamp - timedelta(hours=self.lookback_hours)
                    end_time = hit_timestamp + timedelta(hours=self.lookahead_hours)
                    
                    # Query surrounding messages
                    await cur.execute(
                        """
                        SELECT
                            doc_id,
                            external_id,
                            source_type,
                            source_provider,
                            title,
                            canonical_uri,
                            mime_type,
                            content_timestamp,
                            content_timestamp_type,
                            people,
                            has_attachments,
                            attachment_count,
                            has_location,
                            has_due_date,
                            due_date,
                            is_completed,
                            metadata,
                            thread_id,
                            text
                        FROM documents
                        WHERE thread_id = %s::uuid
                          AND is_active_version = true
                          AND source_type = 'imessage'
                          AND content_timestamp >= %s
                          AND content_timestamp <= %s
                          AND doc_id != %s::uuid
                        ORDER BY content_timestamp
                        LIMIT %s
                        """,
                        (thread_uuid, start_time, end_time, doc_uuid, self.max_messages),
                    )
                    
                    rows = await cur.fetchall()
                    
                    for row in rows:
                        ctx_doc_id = str(row["doc_id"])
                        if ctx_doc_id in seen_doc_ids:
                            continue
                        
                        seen_doc_ids.add(ctx_doc_id)
                        
                        # Convert to SearchDocument format
                        doc = SearchDocument.from_record(row)
                        
                        expanded.append({
                            "document_id": str(doc.doc_id),
                            "chunk_id": None,
                            "title": doc.title,
                            "url": doc.canonical_uri,
                            "snippet": doc.metadata.get("text", "")[:200] if doc.metadata else "",
                            "score": 0.5,  # Lower score for context messages
                            "sources": ["context"],
                            "metadata": {
                                "source_type": doc.source_type,
                                "thread_id": str(doc.thread_id) if doc.thread_id else None,
                                "content_timestamp": doc.content_timestamp.isoformat(),
                                "people": [
                                    {
                                        "identifier": p.identifier,
                                        "display_name": p.display_name or p.identifier,
                                    }
                                    for p in doc.people
                                ],
                                "has_attachments": doc.has_attachments,
                                "context": True,
                                "context_for": doc_id_str,
                            },
                        })
        
        logger.debug(
            "context_expanded",
            hit_count=len(imessage_hits),
            expanded_count=len(expanded),
        )
        
        return expanded


def get_context_expander() -> ContextExpander:
    """Get a ContextExpander instance with default settings."""
    return ContextExpander(
        lookback_hours=8,
        lookahead_hours=2,
        max_messages=10,
    )

