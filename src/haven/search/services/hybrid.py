from __future__ import annotations

import json
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, List, Optional, Sequence, Tuple
from uuid import UUID

import numpy as np
from psycopg.rows import dict_row

from ..config import get_settings
from ..db import get_connection
from ..models import Facet, QueryFilter, SearchHit, SearchRequest, SearchResult
from ..pipeline.embedder import Embedder
from services.search_service.models_v2 import SearchDocument
from shared.logging import get_logger

logger = get_logger("search.hybrid")


@dataclass
class FilterContext:
    sql_clauses: List[str]
    sql_params: List[Any]
    post_filters: List[QueryFilter]
    context_window: int
    thread_id: Optional[str]


def _parse_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).lower() in {"1", "true", "yes", "on"}


class HybridSearchService:
    """Executes hybrid (lexical + vector) search with unified schema awareness."""

    def __init__(self) -> None:
        self._settings = get_settings()
        self._embedder = Embedder()
        self._self_person_id: Optional[UUID] = None
        self._participant_cache: Dict[str, Dict[str, Any]] = {}

    async def search(self, org_id: str, request: SearchRequest) -> SearchResult:  # org_id retained for compatibility
        cursor_size = request.page.size
        filter_ctx = self._prepare_filters(request)

        lexical_weight = request.keyword.weight if request.keyword else 1.0
        vector_weight = request.vector.weight if request.vector else 1.0

        lexical_scores = await self._lexical_search(request, cursor_size, lexical_weight, filter_ctx)
        vector_scores = await self._vector_search(request, cursor_size, vector_weight, filter_ctx)

        fused = self._fuse_scores(lexical_scores, vector_scores)
        ordered = sorted(fused.items(), key=lambda item: item[1]["score"], reverse=True)[:cursor_size]

        hits, doc_models = await self._load_hits(ordered, filter_ctx, request)
        
        # Add automatic thread context for all results
        if request.thread_context_window > 0:
            await self._enrich_with_thread_context(hits, request)
        
        # Legacy thread context (for explicit thread_id filters)
        if filter_ctx.thread_id and filter_ctx.context_window > 0:
            context_hits = await self._append_thread_context(filter_ctx, doc_models, hits)
            if context_hits:
                hits.extend(context_hits)

        facet_counts = self._aggregate_facets(hits, request)
        
        # Transform hits to compact format if requested (default: True)
        if request.compact_format:
            try:
                hits = await self._transform_to_compact_format(hits)
            except Exception as e:
                logger.error("failed_to_apply_compact_format", error=str(e), exc_info=True)
        
        return SearchResult(
            total_estimated=len(fused),
            cursor=None,
            hits=hits,
            facet_counts=facet_counts,
        )

    async def _lexical_search(
        self,
        request: SearchRequest,
        limit: int,
        weight: float,
        filter_ctx: FilterContext,
    ) -> Dict[str, Dict[str, Any]]:
        if not request.query:
            return {}

        clauses = filter_ctx.sql_clauses.copy()
        params = [request.query, request.query, *filter_ctx.sql_params, limit]

        query = "\n".join(
            [
                "SELECT c.chunk_id, cd.doc_id,",
                "       ts_rank_cd(to_tsvector('english', c.text), plainto_tsquery('english', %s)) AS rank",
                "FROM chunks c",
                "JOIN chunk_documents cd ON cd.chunk_id = c.chunk_id",
                "JOIN documents d ON d.doc_id = cd.doc_id",
                "WHERE d.is_active_version = true",
                "  AND to_tsvector('english', c.text) @@ plainto_tsquery('english', %s)",
                *clauses,
                "ORDER BY rank DESC",
                "LIMIT %s",
            ]
        )

        async with get_connection() as conn:
            async with conn.cursor() as cur:
                await cur.execute(query, params)
                rows = await cur.fetchall()

        scores: Dict[str, Dict[str, Any]] = {}
        for row in rows:
            chunk_id, document_id, rank = row
            score = float(rank or 0.0) * weight
            scores[str(chunk_id)] = {
                "score": score,
                "document_id": str(document_id),
                "sources": ["lexical"],
            }
        return scores

    async def _vector_search(
        self,
        request: SearchRequest,
        limit: int,
        weight: float,
        filter_ctx: FilterContext,
    ) -> Dict[str, Dict[str, Any]]:
        """Vector search using Postgres pgvector."""
        if request.vector is None and not request.query:
            return {}

        text = request.vector.text if request.vector and request.vector.text else request.query or ""
        if not text:
            return {}

        # Generate embedding for query text
        embeddings = self._embedder.encode_texts([text])
        if not embeddings:
            return {}

        vector = embeddings[0]
        # Convert numpy array to list and format as Postgres vector literal
        vector_list = vector.tolist()
        vector_str = "[" + ",".join(str(x) for x in vector_list) + "]"

        try:
            async with get_connection() as conn:
                async with conn.cursor(row_factory=dict_row) as cur:
                    # Build WHERE clause from filters
                    where_clauses = ["c.embedding_vector IS NOT NULL", "d.is_active_version = true"]
                    params: List[Any] = []

                    # Add post-filters (applied in SQL for better performance)
                    for flt in filter_ctx.post_filters:
                        if not flt.term or flt.value is None:
                            continue
                        if flt.term == "source_type":
                            where_clauses.append("d.source_type = %s")
                            params.append(flt.value)
                        elif flt.term == "thread_id":
                            where_clauses.append("d.thread_id = %s::uuid")
                            params.append(flt.value)
                        elif flt.term == "has_attachments":
                            where_clauses.append("d.has_attachments = %s")
                            params.append(_parse_bool(flt.value))

                    # Add SQL filters from filter_ctx (pre-filters)
                    where_clauses.extend(filter_ctx.sql_clauses)
                    params.extend(filter_ctx.sql_params)

                    # Vector similarity: 1 - (embedding <=> query_vector) gives cosine similarity
                    # <=> is cosine distance operator in pgvector (0 = identical, 2 = opposite)
                    # We convert distance to similarity: similarity = 1 - distance
                    query = f"""
                        SELECT 
                            c.chunk_id,
                            cd.doc_id AS document_id,
                            1 - (c.embedding_vector <=> %s::vector) AS similarity
                        FROM chunks c
                        JOIN chunk_documents cd ON cd.chunk_id = c.chunk_id
                        JOIN documents d ON d.doc_id = cd.doc_id
                        WHERE {' AND '.join(where_clauses)}
                        ORDER BY c.embedding_vector <=> %s::vector
                        LIMIT %s
                    """

                    # Parameters: query_vector (twice - once for WHERE, once for ORDER BY), then filters, then limit
                    params = [vector_str] + params + [vector_str, limit]
                    await cur.execute(query, params)
                    rows = await cur.fetchall()

            scores: Dict[str, Dict[str, Any]] = {}
            for row in rows:
                chunk_id = str(row["chunk_id"])
                similarity = float(row["similarity"]) * weight
                scores[chunk_id] = {
                    "score": similarity,
                    "document_id": str(row["document_id"]),
                    "sources": ["vector"],
                }
            return scores
        except Exception as exc:
            logger.warning("vector_search_failed", error=str(exc))
            return {}

    async def _load_hits(
        self,
        ordered: List[Tuple[str, Dict[str, Any]]],
        filter_ctx: FilterContext,
        request: SearchRequest,
    ) -> Tuple[List[SearchHit], Dict[UUID, SearchDocument]]:
        if not ordered:
            return [], {}

        chunk_ids = [chunk_id for chunk_id, _ in ordered if chunk_id]
        if not chunk_ids:
            return [], {}

        async with get_connection() as conn:
            async with conn.cursor(row_factory=dict_row) as cur:
                await cur.execute(
                    """
                    SELECT
                        c.chunk_id,
                        c.text               AS chunk_text,
                        cd.doc_id             AS doc_id,
                        cd.ordinal            AS chunk_ordinal,
                        d.doc_id              AS document_id,
                        d.external_id,
                        d.source_type,
                        d.source_provider,
                        d.title,
                        d.canonical_uri,
                        d.mime_type,
                        d.content_timestamp,
                        d.content_timestamp_type,
                        d.people,
                        d.has_attachments,
                        d.attachment_count,
                        d.has_location,
                        d.has_due_date,
                        d.due_date,
                        d.is_completed,
                        d.metadata,
                        d.thread_id,
                        d.text
                    FROM chunks c
                    JOIN chunk_documents cd ON cd.chunk_id = c.chunk_id
                    JOIN documents d ON d.doc_id = cd.doc_id
                    WHERE c.chunk_id = ANY(%s)
                    """,
                    (chunk_ids,),
                )
                rows = await cur.fetchall()

        record_map: Dict[str, Dict[str, Any]] = {str(row["chunk_id"]): row for row in rows}
        hits: List[SearchHit] = []
        doc_models: Dict[UUID, SearchDocument] = {}
        seen_chunks: set[str] = set()

        for chunk_id, meta in ordered:
            record = record_map.get(chunk_id)
            if not record or chunk_id in seen_chunks:
                continue
            seen_chunks.add(chunk_id)

            document = SearchDocument.from_record(record)
            if not self._document_matches_filters(document, filter_ctx.post_filters):
                continue

            doc_models[document.doc_id] = document
            sources = list(dict.fromkeys(meta.get("sources", []) or ["hybrid"]))
            chunk_text: str = record.get("chunk_text") or ""
            base_score = float(meta["score"])
            chunk_ordinal = record.get("chunk_ordinal")

            # Get full message text for thread-based results
            # CRITICAL: For thread-based messages, always use full document text, not chunk text
            # Messages can be split into multiple chunks, and we need the complete message
            # for proper LLM context. Document text is the authoritative source.
            if document.thread_id and document.source_type in ("imessage", "email", "sms"):
                # Always use document text for thread-based messages (handles multi-chunk messages)
                doc_text = record.get("text")
                if doc_text:
                    full_text = doc_text
                else:
                    # Fallback to chunk text only if document text is missing (shouldn't happen)
                    full_text = chunk_text
            else:
                # For non-thread documents, chunk text is fine
                full_text = chunk_text
            
            hit = await self._create_hit(
                document=document,
                chunk_id=chunk_id,
                text=full_text,
                base_score=base_score,
                sources=sources,
                metadata_extra={"chunk_ordinal": chunk_ordinal},
                request=request,
            )
            hits.append(hit)

        return hits, doc_models

    async def _append_thread_context(
        self,
        filter_ctx: FilterContext,
        doc_models: Dict[UUID, SearchDocument],
        hits: List[SearchHit],
    ) -> List[SearchHit]:
        thread_id = filter_ctx.thread_id
        window = filter_ctx.context_window
        if not thread_id or window <= 0:
            return []

        try:
            thread_uuid = UUID(thread_id)
        except ValueError:
            return []

        base_doc_ids = {
            UUID(hit.document_id)
            for hit in hits
            if hit.metadata.get("thread_id") == thread_id
        }
        if not base_doc_ids:
            return []

        seen_documents = {UUID(hit.document_id) for hit in hits}
        context_hits: List[SearchHit] = []

        async with get_connection() as conn:
            async with conn.cursor(row_factory=dict_row) as cur:
                for target_doc_id in base_doc_ids:
                    await cur.execute(
                        """
                        WITH ordered AS (
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
                                text,
                                row_number() OVER (ORDER BY content_timestamp) AS rn
                            FROM documents
                            WHERE thread_id = %s::uuid
                              AND is_active_version = true
                        )
                        SELECT ctx.*
                        FROM ordered ctx
                        JOIN ordered target ON target.doc_id = %s::uuid
                        WHERE ctx.rn BETWEEN target.rn - %s AND target.rn + %s
                        ORDER BY ctx.content_timestamp
                        """,
                        (thread_uuid, target_doc_id, window, window),
                    )
                    rows = await cur.fetchall()

                    for row in rows:
                        ctx_doc_id = row["doc_id"]
                        if ctx_doc_id in seen_documents:
                            continue
                        context_doc = SearchDocument.from_record(row)
                        if not self._document_matches_filters(context_doc, filter_ctx.post_filters):
                            continue
                        seen_documents.add(ctx_doc_id)
                        metadata_extra = {
                            "context": True,
                            "context_for": str(target_doc_id),
                        }
                        text = row.get("text") or ""
                        context_hit = await self._create_hit(
                            document=context_doc,
                            chunk_id=None,
                            text=text,
                            base_score=0.1,  # ensure minimal positive score
                            sources=["context"],
                            metadata_extra=metadata_extra,
                            request=None,  # Legacy context doesn't need request
                        )
                        context_hits.append(context_hit)

        return context_hits

    def _smart_truncate(self, text: str, max_length: int = 1000) -> str:
        """Truncate text preserving sentence boundaries."""
        if len(text) <= max_length:
            return text
        
        # Try to find a sentence boundary near the limit
        truncated = text[:max_length]
        
        # Look for sentence endings (., !, ?) in the last 200 chars
        search_window = truncated[-200:]
        for punct in ['. ', '! ', '? ', '.\n', '!\n', '?\n']:
            last_punct = search_window.rfind(punct)
            if last_punct > 0:
                return truncated[:max_length - 200 + last_punct + len(punct)].strip()
        
        # Fallback to word boundary
        last_space = truncated.rfind(' ')
        if last_space > max_length * 0.8:  # Only if we're not losing too much
            return truncated[:last_space].strip() + "..."
        
        return truncated.strip() + "..."

    async def _create_hit(
        self,
        *,
        document: SearchDocument,
        chunk_id: Optional[str],
        text: str,
        base_score: float,
        sources: Sequence[str],
        metadata_extra: Optional[Dict[str, Any]] = None,
        request: Optional[SearchRequest] = None,
    ) -> SearchHit:
        adjusted_score = self._apply_ranking_boost(base_score, document)
        metadata_payload = await self._build_metadata(document, request)
        if metadata_extra:
            for key, value in metadata_extra.items():
                if value is not None:
                    metadata_payload[key] = value
        if chunk_id:
            metadata_payload.setdefault("chunk_id", chunk_id)
        
        # Enhanced snippet: larger size, smart truncation
        # For thread-based messages, use much larger limit (or no limit) to preserve full context
        # Non-thread messages can be shorter since they're standalone
        if document.thread_id and document.source_type in ("imessage", "email", "sms"):
            # For thread messages, don't truncate - show full message text
            # This ensures LLM sees complete messages in conversation context
            snippet = text or ""
        else:
            # For non-thread messages, use smart truncation with reasonable limit
            snippet_length = 800
            snippet = self._smart_truncate(text or "", snippet_length)
        
        return SearchHit(
            document_id=str(document.doc_id),
            chunk_id=chunk_id,
            title=document.title,
            url=document.canonical_uri,
            snippet=snippet,
            highlights=[],
            score=round(adjusted_score, 4),
            facets=self._build_facets(document),
            metadata=metadata_payload,
            sources=list(sources),
        )

    def _calculate_relative_time(self, timestamp: datetime) -> Dict[str, Any]:
        """Calculate relative time indicators for LLM context."""
        now = datetime.now(timezone.utc)
        ts_utc = timestamp.astimezone(timezone.utc)
        delta = now - ts_utc
        
        days_ago = int(delta.total_seconds() / 86400)
        hours_ago = int(delta.total_seconds() / 3600)
        minutes_ago = int(delta.total_seconds() / 60)
        
        # Calculate relative time string
        if days_ago == 0:
            if hours_ago == 0:
                if minutes_ago < 1:
                    relative = "just now"
                else:
                    relative = f"{minutes_ago} minute{'s' if minutes_ago != 1 else ''} ago"
            else:
                relative = f"{hours_ago} hour{'s' if hours_ago != 1 else ''} ago"
        elif days_ago == 1:
            relative = "yesterday"
        elif days_ago < 7:
            relative = f"{days_ago} days ago"
        elif days_ago < 30:
            weeks = days_ago // 7
            relative = f"{weeks} week{'s' if weeks != 1 else ''} ago"
        elif days_ago < 365:
            months = days_ago // 30
            relative = f"{months} month{'s' if months != 1 else ''} ago"
        else:
            years = days_ago // 365
            relative = f"{years} year{'s' if years != 1 else ''} ago"
        
        # Time of day
        hour = ts_utc.hour
        if 5 <= hour < 12:
            time_of_day = "morning"
        elif 12 <= hour < 17:
            time_of_day = "afternoon"
        elif 17 <= hour < 21:
            time_of_day = "evening"
        else:
            time_of_day = "night"
        
        # Day of week
        day_of_week = ts_utc.strftime("%A")
        is_weekend = ts_utc.weekday() >= 5  # Saturday = 5, Sunday = 6
        
        return {
            "relative": relative,
            "relative_days": days_ago,
            "is_recent": days_ago <= 7,
            "time_of_day": time_of_day,
            "day_of_week": day_of_week,
            "is_weekend": is_weekend,
        }

    async def _get_self_person_id(self) -> Optional[UUID]:
        """Get self_person_id from system_settings."""
        if self._self_person_id is not None:
            return self._self_person_id
        
        try:
            async with get_connection() as conn:
                async with conn.cursor(row_factory=dict_row) as cur:
                    await cur.execute(
                        "SELECT value FROM system_settings WHERE key = 'self_person_id'"
                    )
                    row = await cur.fetchone()
                    if row and row.get("value"):
                        value = row["value"]
                        if isinstance(value, dict):
                            person_id_str = value.get("self_person_id")
                            if person_id_str:
                                self._self_person_id = UUID(person_id_str)
                                return self._self_person_id
        except Exception as e:
            logger.warning("failed_to_get_self_person_id", error=str(e))
        
        return None

    async def _resolve_participant(self, identifier: str, identifier_type: str) -> Dict[str, Any]:
        """Resolve participant identifier to person record."""
        cache_key = f"{identifier_type}:{identifier}"
        if cache_key in self._participant_cache:
            return self._participant_cache[cache_key]
        
        result = {
            "identifier": identifier,
            "identifier_type": identifier_type,
            "display_name": None,
            "given_name": None,
            "family_name": None,
            "is_self": False,
        }
        
        try:
            async with get_connection() as conn:
                async with conn.cursor(row_factory=dict_row) as cur:
                    # Normalize phone number (remove +, spaces, dashes)
                    normalized = identifier.replace("+", "").replace(" ", "").replace("-", "").replace("(", "").replace(")", "")
                    
                    if identifier_type == "phone":
                        # Try to find person by phone number
                        # First try exact matches, then normalized matches
                        await cur.execute(
                            """
                            SELECT DISTINCT p.person_id, p.display_name, p.given_name, p.family_name
                            FROM people p
                            JOIN person_identifiers pi ON p.person_id = pi.person_id
                            WHERE pi.kind = 'phone'
                              AND (
                                pi.value_canonical = %s
                                OR pi.value_raw = %s
                                OR REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(pi.value_canonical::text, '\\+', '', 'g'), ' ', '', 'g'), '-', '', 'g'), '\\(', '', 'g'), '\\)', '', 'g') = %s
                                OR REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(pi.value_raw::text, '\\+', '', 'g'), ' ', '', 'g'), '-', '', 'g'), '\\(', '', 'g'), '\\)', '', 'g') = %s
                              )
                              AND p.deleted = false
                            LIMIT 1
                            """,
                            (identifier, identifier, normalized, normalized),
                        )
                    elif identifier_type == "email":
                        await cur.execute(
                            """
                            SELECT DISTINCT p.person_id, p.display_name, p.given_name, p.family_name
                            FROM people p
                            JOIN person_identifiers pi ON p.person_id = pi.person_id
                            WHERE pi.kind = 'email'
                              AND (pi.value_canonical = %s OR pi.value_raw = %s)
                              AND p.deleted = false
                            LIMIT 1
                            """,
                            (identifier.lower(), identifier),
                        )
                    else:
                        # Unknown identifier type, return as-is
                        self._participant_cache[cache_key] = result
                        return result
                    
                    row = await cur.fetchone()
                    if row:
                        result["display_name"] = row.get("display_name")
                        result["given_name"] = row.get("given_name")
                        result["family_name"] = row.get("family_name")
                        
                        # Check if this is self
                        self_id = await self._get_self_person_id()
                        if self_id and row["person_id"] == self_id:
                            result["is_self"] = True
        except Exception as e:
            logger.warning("failed_to_resolve_participant", identifier=identifier, error=str(e))
        
        self._participant_cache[cache_key] = result
        return result

    async def _resolve_thread_participants(self, thread_payload: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """Resolve thread participants from phone numbers to names."""
        if not thread_payload:
            return []
        
        participants_raw = thread_payload.get("participants", [])
        if not participants_raw:
            return []
        
        resolved = []
        for participant in participants_raw:
            identifier = participant.get("identifier", "")
            identifier_type = participant.get("identifier_type", "phone")
            resolved_participant = await self._resolve_participant(identifier, identifier_type)
            resolved.append(resolved_participant)
        
        return resolved

    async def _determine_message_direction(self, document: SearchDocument, thread_payload: Optional[Dict[str, Any]]) -> Dict[str, Any]:
        """Determine message direction and sender information."""
        direction_info = {
            "direction": document.content_timestamp_type,  # sent/received
            "sender": None,
            "is_self_message": False,
        }
        
        # For iMessage, check if it's sent or received
        if document.content_timestamp_type in ("sent", "received"):
            direction_info["direction"] = document.content_timestamp_type
            
            # Try to determine sender from metadata or people array
            # For sent messages, user is the sender
            if document.content_timestamp_type == "sent":
                direction_info["is_self_message"] = True
                self_id = await self._get_self_person_id()
                if self_id:
                    direction_info["sender"] = "You"
            else:
                # Received message - sender is someone else
                # Try to find sender in people array first
                sender_found = False
                for person in document.people:
                    if person.role == "sender":
                        # Resolve sender to get display name
                        resolved = await self._resolve_participant(
                            person.identifier,
                            person.identifier_type or "phone"
                        )
                        display_name = resolved.get("display_name")
                        if display_name:
                            direction_info["sender"] = display_name
                            sender_found = True
                            break
                
                # Fallback: If people array is empty or doesn't have sender,
                # try to get sender from thread_payload participants
                # For received messages, the sender is one of the participants (not "You")
                if not sender_found and thread_payload:
                    participants = thread_payload.get("participants", [])
                    # Get self identifier to exclude it
                    self_id = await self._get_self_person_id()
                    self_identifiers = set()
                    if self_id:
                        async with get_connection() as conn:
                            async with conn.cursor(row_factory=dict_row) as cur:
                                await cur.execute(
                                    """
                                    SELECT value_canonical, value_raw
                                    FROM person_identifiers
                                    WHERE person_id = %s::uuid
                                    """,
                                    (self_id,),
                                )
                                rows = await cur.fetchall()
                                for row in rows:
                                    if row.get("value_canonical"):
                                        self_identifiers.add(row["value_canonical"])
                                    if row.get("value_raw"):
                                        self_identifiers.add(row["value_raw"])
                    
                    # Try each participant (excluding self)
                    for participant in participants:
                        identifier = participant.get("identifier", "")
                        identifier_type = participant.get("identifier_type", "phone")
                        
                        # Skip if this is self
                        if identifier in self_identifiers:
                            continue
                        
                        # Resolve participant to get display name
                        resolved = await self._resolve_participant(identifier, identifier_type)
                        display_name = resolved.get("display_name")
                        if display_name:
                            direction_info["sender"] = display_name
                            sender_found = True
                            break
                    
                    # If still not found, use first non-self participant's identifier as fallback
                    if not sender_found:
                        for participant in participants:
                            identifier = participant.get("identifier", "")
                            if identifier not in self_identifiers:
                                direction_info["sender"] = identifier
                                break
        
        return direction_info

    async def _get_thread_context(
        self,
        thread_id: UUID,
        target_doc_id: UUID,
        window: int,
        max_messages: int,
    ) -> List[Dict[str, Any]]:
        """Get surrounding messages from a thread for context."""
        try:
            async with get_connection() as conn:
                async with conn.cursor(row_factory=dict_row) as cur:
                    await cur.execute(
                        """
                        WITH ordered AS (
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
                                text,
                                row_number() OVER (ORDER BY content_timestamp) AS rn
                            FROM documents
                            WHERE thread_id = %s::uuid
                              AND is_active_version = true
                        )
                        SELECT ctx.*
                        FROM ordered ctx
                        JOIN ordered target ON target.doc_id = %s::uuid
                        WHERE ctx.rn BETWEEN target.rn - %s AND target.rn + %s
                        ORDER BY ctx.content_timestamp
                        LIMIT %s
                        """,
                        (thread_id, target_doc_id, window, window, max_messages),
                    )
                    rows = await cur.fetchall()
                    
                    context_messages = []
                    for row in rows:
                        ctx_doc = SearchDocument.from_record(row)
                        ctx_text = row.get("text") or ""
                        
                        # Determine sender
                        sender_info = {"display_name": None, "is_self": False}
                        if ctx_doc.content_timestamp_type == "sent":
                            sender_info = {"display_name": "You", "is_self": True}
                        else:
                            # Try to find sender in people array
                            for person in ctx_doc.people:
                                if person.role == "sender":
                                    resolved = await self._resolve_participant(
                                        person.identifier,
                                        person.identifier_type or "phone"
                                    )
                                    sender_info = {
                                        "display_name": resolved.get("display_name") or person.identifier,
                                        "identifier": person.identifier,
                                        "is_self": resolved.get("is_self", False),
                                    }
                                    break
                            
                            # If no sender found, try to get from thread payload
                            if not sender_info.get("display_name"):
                                thread_payload_raw = ctx_doc.metadata.get("headers", {}).get("thread_payload") if ctx_doc.metadata else None
                                if thread_payload_raw:
                                    if isinstance(thread_payload_raw, str):
                                        try:
                                            thread_payload = json.loads(thread_payload_raw)
                                        except Exception:
                                            thread_payload = None
                                    else:
                                        thread_payload = thread_payload_raw
                                    
                                    if thread_payload:
                                        participants = thread_payload.get("participants", [])
                                        if participants:
                                            # Try first participant
                                            first_participant = participants[0]
                                            resolved = await self._resolve_participant(
                                                first_participant.get("identifier", ""),
                                                first_participant.get("identifier_type", "phone")
                                            )
                                            sender_info = {
                                                "display_name": resolved.get("display_name") or first_participant.get("identifier", "Unknown"),
                                                "identifier": first_participant.get("identifier", ""),
                                                "is_self": resolved.get("is_self", False),
                                            }
                        
                        # Enhance image placeholders with enrichment data if available
                        # ctx_doc.metadata is a dict, but we need to ensure it has the full metadata from the database
                        # The metadata from SearchDocument.from_record should already include image_captions
                        doc_metadata = ctx_doc.metadata if isinstance(ctx_doc.metadata, dict) else {}
                        enhanced_text = self._enhance_image_placeholders_in_text(ctx_text, doc_metadata)
                        
                        # Calculate relative time
                        temporal = self._calculate_relative_time(ctx_doc.content_timestamp)
                        
                        context_messages.append({
                            "content": enhanced_text[:500],  # Limit individual message size
                            "sender": sender_info.get("display_name"),
                            "direction": ctx_doc.content_timestamp_type,
                            "timestamp": ctx_doc.content_timestamp.astimezone(timezone.utc).isoformat(),
                            "relative_time": temporal.get("relative"),
                            "is_match": str(ctx_doc.doc_id) == str(target_doc_id),
                            "document_id": str(ctx_doc.doc_id),
                        })
                    
                    return context_messages
        except Exception as e:
            logger.warning("failed_to_get_thread_context", thread_id=str(thread_id), error=str(e))
            return []

    async def _build_conversation_summary(
        self,
        thread_id: UUID,
    ) -> Optional[Dict[str, Any]]:
        """Build conversation summary statistics."""
        try:
            async with get_connection() as conn:
                async with conn.cursor(row_factory=dict_row) as cur:
                    # Get thread statistics
                    await cur.execute(
                        """
                        SELECT
                            COUNT(*) AS message_count,
                            MIN(content_timestamp) AS start_time,
                            MAX(content_timestamp) AS end_time,
                            COUNT(DISTINCT doc_id) AS unique_messages
                        FROM documents
                        WHERE thread_id = %s::uuid
                          AND is_active_version = true
                        """,
                        (thread_id,),
                    )
                    stats = await cur.fetchone()
                    
                    if not stats or stats["message_count"] == 0:
                        return None
                    
                    start_time = stats["start_time"]
                    end_time = stats["end_time"]
                    
                    # Calculate duration
                    duration_days = 0
                    if start_time and end_time:
                        delta = end_time - start_time
                        duration_days = int(delta.total_seconds() / 86400)
                    
                    # Get thread_payload from one of the documents to get participant list
                    await cur.execute(
                        """
                        SELECT metadata->'headers'->>'thread_payload' AS thread_payload
                        FROM documents
                        WHERE thread_id = %s::uuid
                          AND is_active_version = true
                          AND metadata->'headers'->>'thread_payload' IS NOT NULL
                        LIMIT 1
                        """,
                        (thread_id,),
                    )
                    thread_payload_row = await cur.fetchone()
                    thread_payload = None
                    if thread_payload_row and thread_payload_row.get("thread_payload"):
                        try:
                            thread_payload = json.loads(thread_payload_row["thread_payload"])
                        except Exception:
                            pass
                    
                    # Get self person ID to identify self messages
                    self_id = await self._get_self_person_id()
                    self_identifiers = set()
                    if self_id:
                        await cur.execute(
                            """
                            SELECT value_canonical, value_raw
                            FROM person_identifiers
                            WHERE person_id = %s::uuid
                            """,
                            (self_id,),
                        )
                        self_rows = await cur.fetchall()
                        for row in self_rows:
                            if row.get("value_canonical"):
                                self_identifiers.add(row["value_canonical"])
                            if row.get("value_raw"):
                                self_identifiers.add(row["value_raw"])
                    
                    # Get all messages with their people arrays to count per participant
                    await cur.execute(
                        """
                        SELECT
                            content_timestamp_type,
                            people,
                            COUNT(*) AS message_count
                        FROM documents
                        WHERE thread_id = %s::uuid
                          AND is_active_version = true
                        GROUP BY content_timestamp_type, people
                        """,
                        (thread_id,),
                    )
                    message_groups = await cur.fetchall()
                    
                    # Count messages per participant
                    participant_counts: Dict[str, int] = defaultdict(int)
                    
                    for row in message_groups:
                        msg_type = row["content_timestamp_type"]
                        people_array = row.get("people") or []
                        count = row["message_count"]
                        
                        if msg_type == "sent":
                            # Sent messages are from "You"
                            participant_counts["__self__"] += count
                        else:
                            # Received messages - try to get sender from people array
                            sender_found = False
                            for person in people_array:
                                if isinstance(person, dict) and person.get("role") == "sender":
                                    identifier = person.get("identifier", "")
                                    if identifier and identifier not in self_identifiers:
                                        participant_counts[identifier] += count
                                        sender_found = True
                                    break
                            
                            # If no sender in people array, we can't determine individual sender
                            # Count as "unknown" for now
                            if not sender_found:
                                participant_counts["__unknown__"] += count
                    
                    # Build participants list with resolved names
                    participants = []
                    
                    # Add "You" for sent messages
                    if participant_counts.get("__self__", 0) > 0:
                        participants.append({
                            "name": "You",
                            "message_count": participant_counts["__self__"],
                            "is_self": True,
                        })
                    
                    # Add other participants
                    if thread_payload:
                        thread_participants = thread_payload.get("participants", [])
                        # Create a map of identifier to participant info
                        participant_map = {
                            p.get("identifier", ""): p
                            for p in thread_participants
                            if p.get("identifier", "") not in self_identifiers
                        }
                        
                        # Add participants with message counts
                        for identifier, count in participant_counts.items():
                            if identifier == "__self__" or identifier == "__unknown__":
                                continue
                            
                            # Resolve participant name
                            participant_info = participant_map.get(identifier, {})
                            identifier_type = participant_info.get("identifier_type", "phone")
                            resolved = await self._resolve_participant(identifier, identifier_type)
                            display_name = resolved.get("display_name") or identifier
                            
                            participants.append({
                                "name": display_name,
                                "message_count": count,
                                "is_self": False,
                            })
                    
                    # If we have unknown messages, add them as "Others"
                    if participant_counts.get("__unknown__", 0) > 0:
                        participants.append({
                            "name": "Others",
                            "message_count": participant_counts["__unknown__"],
                            "is_self": False,
                        })
                    
                    # Sort by message count descending
                    participants.sort(key=lambda p: p["message_count"], reverse=True)
                    
                    return {
                        "message_count": stats["message_count"],
                        "time_span": {
                            "start": start_time.astimezone(timezone.utc).isoformat() if start_time else None,
                            "end": end_time.astimezone(timezone.utc).isoformat() if end_time else None,
                            "duration_days": duration_days,
                        },
                        "participants": participants,
                    }
        except Exception as e:
            logger.warning("failed_to_build_conversation_summary", thread_id=str(thread_id), error=str(e))
            return None

    async def _enrich_with_thread_context(
        self,
        hits: List[SearchHit],
        request: SearchRequest,
    ) -> None:
        """Enrich hits with thread context automatically."""
        # Group hits by thread_id
        thread_groups: Dict[str, List[SearchHit]] = {}
        for hit in hits:
            thread_id = hit.metadata.get("thread_id")
            if thread_id:
                if thread_id not in thread_groups:
                    thread_groups[thread_id] = []
                thread_groups[thread_id].append(hit)
        
        # Fetch context for each thread (batch queries)
        for thread_id_str, thread_hits in thread_groups.items():
            try:
                thread_uuid = UUID(thread_id_str)
            except ValueError:
                continue
            
            # Build conversation summary if requested
            conversation_summary = None
            if request.include_conversation_summary:
                conversation_summary = await self._build_conversation_summary(thread_uuid)
            
            # Get context for each hit in this thread
            for hit in thread_hits:
                doc_id = UUID(hit.document_id)
                
                # Get thread context
                context_messages = await self._get_thread_context(
                    thread_uuid,
                    doc_id,
                    request.thread_context_window,
                    request.max_conversation_messages,
                )
                
                # Add to metadata
                if context_messages:
                    hit.metadata["conversation_context"] = context_messages
                
                if conversation_summary:
                    hit.metadata["conversation_summary"] = conversation_summary

    async def _build_metadata(self, document: SearchDocument, request: Optional[SearchRequest] = None) -> Dict[str, Any]:
        """Build enhanced metadata with LLM-friendly context."""
        try:
            payload = dict(document.metadata or {})
            
            # Calculate relative time
            temporal = self._calculate_relative_time(document.content_timestamp)
            
            # Get thread payload if available
            thread_payload_raw = payload.get("headers", {}).get("thread_payload")
            thread_payload = None
            if thread_payload_raw:
                if isinstance(thread_payload_raw, str):
                    try:
                        thread_payload = json.loads(thread_payload_raw)
                    except Exception as e:
                        logger.debug("failed_to_parse_thread_payload", error=str(e))
                elif isinstance(thread_payload_raw, dict):
                    thread_payload = thread_payload_raw
            
            # Resolve participants
            resolved_participants = []
            try:
                if thread_payload:
                    resolved_participants = await self._resolve_thread_participants(thread_payload)
            except Exception as e:
                logger.warning("failed_to_resolve_participants", error=str(e), doc_id=str(document.doc_id))
            
            # Determine message direction
            direction_info = {}
            try:
                direction_info = await self._determine_message_direction(document, thread_payload)
            except Exception as e:
                logger.warning("failed_to_determine_message_direction", error=str(e), doc_id=str(document.doc_id))
            
            # Build enhanced metadata
            # Preserve image_captions before update (if it exists)
            image_captions = payload.get("image_captions")
            
            payload.update(
                {
                    "doc_id": str(document.doc_id),
                    "external_id": document.external_id,
                    "source_type": document.source_type,
                    "source_provider": document.source_provider,
                    "canonical_uri": document.canonical_uri,
                    "mime_type": document.mime_type,
                    "content_timestamp": document.content_timestamp.astimezone(timezone.utc).isoformat(),
                    "content_timestamp_type": document.content_timestamp_type,
                    "has_attachments": document.has_attachments,
                    "attachment_count": document.attachment_count,
                    "has_location": document.has_location,
                    "has_due_date": document.has_due_date,
                    "due_date": document.due_date.astimezone(timezone.utc).isoformat()
                    if document.due_date
                    else None,
                    "is_completed": document.is_completed,
                    "people": [person.model_dump(exclude_none=True) for person in document.people],
                    # Enhanced temporal context
                    "temporal": temporal,
                    # Enhanced message direction
                    "message": direction_info,
                }
            )
            
            # Restore image_captions if it was present (update doesn't overwrite if not in update dict, but be explicit)
            if image_captions is not None:
                payload["image_captions"] = image_captions
            
            # Add thread context with resolved participants
            if document.thread_id:
                payload["thread_id"] = str(document.thread_id)
                if resolved_participants:
                    payload["thread_participants"] = resolved_participants
            
            # Filter out None values, but preserve empty lists (like image_captions)
            result = {}
            for key, value in payload.items():
                if value is not None:
                    result[key] = value
            return result
        except Exception as e:
            logger.error("failed_to_build_metadata", error=str(e), doc_id=str(document.doc_id), exc_info=True)
            # Fallback to basic metadata
            payload = dict(document.metadata or {})
            payload.update(
                {
                    "doc_id": str(document.doc_id),
                    "external_id": document.external_id,
                    "source_type": document.source_type,
                    "content_timestamp": document.content_timestamp.astimezone(timezone.utc).isoformat(),
                }
            )
            return {key: value for key, value in payload.items() if value is not None}

    def _build_facets(self, document: SearchDocument) -> List[Facet]:
        facets: List[Facet] = [
            Facet(key="source_type", value=document.source_type),
            Facet(key="has_attachments", value=str(document.has_attachments).lower()),
        ]
        for person in document.people:
            identifier = person.identifier
            if identifier:
                facets.append(Facet(key="person", value=identifier))
        return facets

    def _apply_ranking_boost(self, base_score: float, document: SearchDocument) -> float:
        score = max(base_score, 0.1)
        now = datetime.now(timezone.utc)
        age_days = max((now - document.content_timestamp.astimezone(timezone.utc)).total_seconds() / 86400, 0.0)
        if age_days < 1:
            score *= 1.15
        elif age_days < 7:
            score *= 1.1
        elif age_days < 30:
            score *= 1.05

        if document.has_attachments:
            score *= 1.05

        source_weights = {
            "email": 1.05,
            "imessage": 1.03,
            "sms": 1.02,
            "localfs": 1.0,
        }
        score *= source_weights.get(document.source_type, 1.0)
        return score

    def _document_matches_filters(self, document: SearchDocument, filters: Sequence[QueryFilter]) -> bool:
        for flt in filters:
            if flt.term and flt.value is not None:
                value = flt.value
                if flt.term == "has_attachments":
                    expected = _parse_bool(value)
                    if document.has_attachments != expected:
                        return False
                elif flt.term == "source_type":
                    if document.source_type != str(value):
                        return False
                elif flt.term == "person":
                    identifier = str(value)
                    if not any(person.identifier == identifier for person in document.people):
                        return False
                elif flt.term == "thread_id":
                    if not document.thread_id or str(document.thread_id) != str(value):
                        return False
                elif flt.term == "context_window":
                    continue  # handled separately
                else:
                    if document.metadata.get(flt.term) != value:
                        return False

            if flt.range:
                field = flt.range.field
                gte = flt.range.gte
                lte = flt.range.lte
                if field == "content_timestamp":
                    ts = document.content_timestamp
                    if gte and ts < gte:
                        return False
                    if lte and ts > lte:
                        return False
                elif field == "due_date" and document.due_date:
                    if gte and document.due_date < gte:
                        return False
                    if lte and document.due_date > lte:
                        return False
        return True

    def _prepare_filters(self, request: SearchRequest) -> FilterContext:
        clauses: List[str] = []
        params: List[Any] = []
        post_filters: List[QueryFilter] = []
        context_window = 0
        thread_id: Optional[str] = None

        filters = request.must + request.filter
        for flt in filters:
            if flt.term == "context_window" and flt.value is not None:
                try:
                    context_window = max(int(flt.value), 0)
                except (TypeError, ValueError):
                    context_window = 0
                continue

            post_filters.append(flt)

            if flt.term and flt.value is not None:
                term = flt.term
                value = flt.value
                if term == "has_attachments":
                    clauses.append("AND d.has_attachments = %s")
                    params.append(_parse_bool(value))
                elif term == "source_type":
                    clauses.append("AND d.source_type = %s")
                    params.append(value)
                elif term == "person":
                    clauses.append(
                        "AND EXISTS (SELECT 1 FROM jsonb_array_elements(d.people) elem WHERE elem->>'identifier' = %s)"
                    )
                    params.append(value)
                elif term == "thread_id":
                    thread_id = str(value)
                    clauses.append("AND d.thread_id = %s::uuid")
                    params.append(value)
                elif term in {"source", "source_id"}:
                    clauses.append("AND d.external_id = %s")
                    params.append(value)
                else:
                    clauses.append("AND d.metadata ->> %s = %s")
                    params.extend([term, value])

            if flt.range:
                field = flt.range.field
                if field == "content_timestamp":
                    if flt.range.gte is not None:
                        clauses.append("AND d.content_timestamp >= %s")
                        params.append(flt.range.gte)
                    if flt.range.lte is not None:
                        clauses.append("AND d.content_timestamp <= %s")
                        params.append(flt.range.lte)
                elif field == "due_date":
                    if flt.range.gte is not None:
                        clauses.append("AND d.due_date >= %s")
                        params.append(flt.range.gte)
                    if flt.range.lte is not None:
                        clauses.append("AND d.due_date <= %s")
                        params.append(flt.range.lte)

        return FilterContext(
            sql_clauses=clauses,
            sql_params=params,
            post_filters=post_filters,
            context_window=context_window,
            thread_id=thread_id,
        )

    def _fuse_scores(
        self,
        lexical: Dict[str, Dict[str, Any]],
        vector: Dict[str, Dict[str, Any]],
    ) -> Dict[str, Dict[str, Any]]:
        fused: Dict[str, Dict[str, Any]] = {}
        for chunk_id, payload in lexical.items():
            fused[chunk_id] = {
                "score": payload["score"],
                "document_id": payload["document_id"],
                "sources": payload["sources"].copy(),
            }
        for chunk_id, payload in vector.items():
            if chunk_id in fused:
                fused[chunk_id]["score"] += payload["score"]
                fused[chunk_id]["sources"].extend(payload["sources"])
            else:
                fused[chunk_id] = {
                    "score": payload["score"],
                    "document_id": payload["document_id"],
                    "sources": payload["sources"].copy(),
                }
        return fused

    async def _transform_to_compact_format(self, hits: List[SearchHit]) -> List[SearchHit]:
        """Transform SearchHit objects to Option 4: Hierarchical Essential format for token efficiency."""
        transformed = []
        for hit in hits:
            metadata = hit.metadata or {}
            
            # Extract essential fields
            doc_id = hit.document_id
            text = hit.snippet or hit.title or ""
            
            # Enhance image placeholders in the main text
            # Get the original document metadata (which includes image_captions)
            # The metadata passed here is the enriched metadata from _build_metadata,
            # but we need the original document metadata for image_captions
            # For now, we'll enhance using the metadata we have (it should include image_captions
            # if it was in the original document)
            text = self._enhance_image_placeholders_in_text(text, metadata)
            
            temporal = metadata.get("temporal", {})
            message_info = metadata.get("message", {})
            thread_id = metadata.get("thread_id")
            thread_participants = metadata.get("thread_participants", [])
            conversation_context = metadata.get("conversation_context", [])
            conversation_summary = metadata.get("conversation_summary")
            
            # Build Option 4 structure
            compact_metadata: Dict[str, Any] = {
                "msg": {
                    "id": doc_id[:8] if len(doc_id) > 8 else doc_id,  # Short ID
                    "text": text,
                    "from": message_info.get("sender") or "Unknown",
                    "when": temporal.get("relative", "unknown"),
                }
            }
            
            # Add thread information if available
            if thread_id:
                # Extract participant names only
                participant_names = []
                for participant in thread_participants:
                    name = participant.get("display_name")
                    if name:
                        participant_names.append(name)
                    elif participant.get("is_self"):
                        participant_names.append("You")
                
                thread_data: Dict[str, Any] = {
                    "id": str(thread_id)[:8] if len(str(thread_id)) > 8 else str(thread_id),
                    "people": participant_names,
                }
                
                # Add conversation summary if available
                if conversation_summary:
                    summary_participants = []
                    for p in conversation_summary.get("participants", []):
                        summary_participants.append({
                            "name": p.get("name", "Unknown"),
                            "count": p.get("message_count", 0),
                        })
                    
                    thread_data["stats"] = {
                        "messages": conversation_summary.get("message_count", 0),
                        "duration_days": conversation_summary.get("time_span", {}).get("duration_days", 0),
                        "participants": summary_participants,
                    }
                
                # Add conversation context (simplified)
                if conversation_context:
                    context_messages = []
                    for ctx_msg in conversation_context:
                        # Enhance image placeholders in context messages
                        ctx_text = ctx_msg.get("content", "")
                        # Context messages should already be enhanced from _get_thread_context,
                        # but ensure they are if not
                        if "{IMG:" in ctx_text:
                            # Try to get original document metadata for this context message
                            # For now, enhance using available metadata (may not have image_captions)
                            ctx_text = self._enhance_image_placeholders_in_text(ctx_text, metadata)
                        
                        context_messages.append({
                            "from": ctx_msg.get("sender") or "Unknown",
                            "text": ctx_text[:200],  # Limit length
                            "when": ctx_msg.get("relative_time", "unknown"),
                        })
                    if context_messages:
                        thread_data["context"] = context_messages
                
                compact_metadata["thread"] = thread_data
            
            # Create new SearchHit with compact metadata
            # Keep essential top-level fields but use compact metadata
            transformed_hit = SearchHit(
                document_id=hit.document_id,
                chunk_id=None,  # Remove chunk_id for compactness
                title=None,  # Remove title (included in msg.text)
                url=None,  # Remove url (not needed for LLM)
                snippet=text,  # Keep snippet for backward compatibility
                highlights=[],  # Remove highlights (empty anyway)
                score=hit.score,
                facets=[],  # Remove facets (can be inferred)
                metadata=compact_metadata,
                sources=hit.sources,  # Keep sources for debugging
            )
            transformed.append(transformed_hit)
        
        return transformed

    def _enhance_image_placeholders_in_text(self, text: str, metadata: Dict[str, Any]) -> str:
        """Enhance image placeholders in text with enrichment data from metadata."""
        if not text or not metadata:
            return text
        
        # Check if text contains image placeholders
        if "{IMG:" not in text:
            return text
        
        import re
        
        # Pattern for {IMG:...} format
        img_pattern = r'\{IMG:([^}]+)\}'
        
        # Get image captions array (stored in metadata.image_captions)
        image_captions = metadata.get("image_captions", [])
        if not isinstance(image_captions, list):
            image_captions = []
        
        # Track which caption index we've used
        caption_index = [0]
        
        def replace_placeholder(match):
            attachment_path = match.group(1)
            filename = attachment_path.split("/")[-1] if "/" in attachment_path else attachment_path
            
            # First, try to find enrichment data in metadata.attachments (new schema)
            attachments = metadata.get("attachments", [])
            if attachments:
                # Try to match attachment by path or filename
                for attachment in attachments:
                    attachment_path_attr = attachment.get("path", "")
                    attachment_filename = attachment.get("filename", "")
                    
                    # Check if this attachment matches
                    if (attachment_path in attachment_path_attr or 
                        attachment_path in attachment_filename or
                        attachment_filename in attachment_path):
                        
                        # Extract caption and OCR from attachment
                        caption_obj = attachment.get("caption", {})
                        caption = caption_obj.get("text", "") if isinstance(caption_obj, dict) else ""
                        
                        ocr_obj = attachment.get("ocr", {})
                        ocr_text = ocr_obj.get("text", "") if isinstance(ocr_obj, dict) else ""
                        
                        # Build enriched placeholder: [Image: filename | caption | ocr_text]
                        parts = [filename]
                        if caption:
                            parts.append(caption)
                        if ocr_text:
                            parts.append(ocr_text[:100])  # Limit OCR text length
                        
                        return f"[Image: {' | '.join(parts)}]"
            
            # Fallback: use image_captions array (legacy schema - currently used)
            if caption_index[0] < len(image_captions):
                caption = image_captions[caption_index[0]]
                caption_index[0] += 1
                if caption:
                    return f"[Image: {filename} | {caption}]"
            
            # No enrichment data available, return cleaner format
            return f"[Image: {filename}]"
        
        # Replace all image placeholders
        enhanced_text = re.sub(img_pattern, replace_placeholder, text)
        return enhanced_text

    def _aggregate_facets(self, hits: List[SearchHit], request: SearchRequest) -> Dict[str, Dict[str, int]]:
        requested = set(request.facets or [])
        if not requested:
            return {}

        counts: Dict[str, Dict[str, int]] = defaultdict(lambda: defaultdict(int))
        for hit in hits:
            for facet in hit.facets:
                if facet.key in requested:
                    counts[facet.key][facet.value] += 1
        return {key: dict(value_counts) for key, value_counts in counts.items()}


__all__ = ["HybridSearchService"]
