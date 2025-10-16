from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Sequence, Tuple
from uuid import UUID

import numpy as np
from psycopg.rows import dict_row
from qdrant_client import QdrantClient
from qdrant_client.http import models as qm

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
        self._client = QdrantClient(url=self._settings.qdrant_url)

    async def search(self, org_id: str, request: SearchRequest) -> SearchResult:  # org_id retained for compatibility
        cursor_size = request.page.size
        filter_ctx = self._prepare_filters(request)

        lexical_weight = request.keyword.weight if request.keyword else 1.0
        vector_weight = request.vector.weight if request.vector else 1.0

        lexical_scores = await self._lexical_search(request, cursor_size, lexical_weight, filter_ctx)
        vector_scores = await self._vector_search(request, cursor_size, vector_weight, filter_ctx)

        fused = self._fuse_scores(lexical_scores, vector_scores)
        ordered = sorted(fused.items(), key=lambda item: item[1]["score"], reverse=True)[:cursor_size]

        hits, doc_models = await self._load_hits(ordered, filter_ctx)
        if filter_ctx.thread_id and filter_ctx.context_window > 0:
            context_hits = await self._append_thread_context(filter_ctx, doc_models, hits)
            if context_hits:
                hits.extend(context_hits)

        facet_counts = self._aggregate_facets(hits, request)
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
        if request.vector is None and not request.query:
            return {}

        text = request.vector.text if request.vector and request.vector.text else request.query or ""
        if not text:
            return {}

        embeddings = self._embedder.encode_texts([text])
        if not embeddings:
            return {}

        vector = embeddings[0]

        must_conditions: List[qm.FieldCondition] = []
        for flt in filter_ctx.post_filters:
            if not flt.term or flt.value is None:
                continue
            value_str = str(flt.value)
            if flt.term == "source_type":
                must_conditions.append(qm.FieldCondition(key="source_type", match=qm.MatchValue(value=value_str)))
            elif flt.term == "thread_id":
                must_conditions.append(qm.FieldCondition(key="thread_id", match=qm.MatchValue(value=value_str)))
            elif flt.term == "has_attachments":
                must_conditions.append(
                    qm.FieldCondition(
                        key="has_attachments",
                        match=qm.MatchValue(value=_parse_bool(flt.value)),
                    )
                )

        search_filter = qm.Filter(must=must_conditions) if must_conditions else None

        try:
            response = self._client.search(
                collection_name=self._settings.qdrant_collection,
                query_vector=vector.tolist(),
                limit=limit,
                with_payload=True,
                query_filter=search_filter,
            )
        except Exception as exc:  # pragma: no cover - network failures are tolerated
            logger.warning("vector_search_failed", error=str(exc))
            return {}

        scores: Dict[str, Dict[str, Any]] = {}
        for point in response:
            payload = point.payload or {}
            chunk_id = payload.get("chunk_id") or payload.get("id")
            document_id = payload.get("document_id") or payload.get("doc_id")
            if not chunk_id or not document_id:
                continue
            similarity = float(point.score or 0.0) * weight
            scores[str(chunk_id)] = {
                "score": similarity,
                "document_id": str(document_id),
                "sources": ["vector"],
            }
        return scores

    async def _load_hits(
        self,
        ordered: List[Tuple[str, Dict[str, Any]]],
        filter_ctx: FilterContext,
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
                        d.thread_id
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

            hit = self._create_hit(
                document=document,
                chunk_id=chunk_id,
                text=chunk_text,
                base_score=base_score,
                sources=sources,
                metadata_extra={"chunk_ordinal": chunk_ordinal},
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
                        context_hit = self._create_hit(
                            document=context_doc,
                            chunk_id=None,
                            text=text,
                            base_score=0.1,  # ensure minimal positive score
                            sources=["context"],
                            metadata_extra=metadata_extra,
                        )
                        context_hits.append(context_hit)

        return context_hits

    def _create_hit(
        self,
        *,
        document: SearchDocument,
        chunk_id: Optional[str],
        text: str,
        base_score: float,
        sources: Sequence[str],
        metadata_extra: Optional[Dict[str, Any]] = None,
    ) -> SearchHit:
        adjusted_score = self._apply_ranking_boost(base_score, document)
        metadata_payload = self._build_metadata(document)
        if metadata_extra:
            for key, value in metadata_extra.items():
                if value is not None:
                    metadata_payload[key] = value
        if chunk_id:
            metadata_payload.setdefault("chunk_id", chunk_id)
        snippet = (text or "")[:400]
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

    def _build_metadata(self, document: SearchDocument) -> Dict[str, Any]:
        payload = dict(document.metadata or {})
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
            }
        )
        if document.thread_id:
            payload["thread_id"] = str(document.thread_id)
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
