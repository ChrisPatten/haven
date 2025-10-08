from __future__ import annotations

from collections import defaultdict
from typing import Any, Dict, List, Tuple

import numpy as np
import psycopg
from psycopg import AsyncConnection
from qdrant_client import QdrantClient
from qdrant_client.http import models as qm

from ..config import get_settings
from ..db import get_connection
from ..models import Facet, SearchHit, SearchRequest, SearchResult
from ..pipeline.embedder import Embedder
from shared.logging import get_logger

logger = get_logger("search.hybrid")

FilterClause = Tuple[str, List[Any]]


class HybridSearchService:
    """Executes hybrid (lexical + vector) search with simple fusion."""

    def __init__(self) -> None:
        self._settings = get_settings()
        self._embedder = Embedder()
        self._client = QdrantClient(url=self._settings.qdrant_url)

    async def search(self, org_id: str, request: SearchRequest) -> SearchResult:
        cursor_size = request.page.size
        lexical_weight = request.keyword.weight if request.keyword else 1.0
        vector_weight = request.vector.weight if request.vector else 1.0
        lexical_scores = await self._lexical_search(org_id, request, cursor_size, lexical_weight)
        vector_scores = await self._vector_search(org_id, request, cursor_size, vector_weight)
        fused = self._fuse_scores(lexical_scores, vector_scores)
        ordered = sorted(fused.items(), key=lambda item: item[1]["score"], reverse=True)[:cursor_size]
        hits = await self._load_hits(org_id, ordered, request)
        facet_counts = self._aggregate_facets(hits, request)
        return SearchResult(
            total_estimated=len(fused),
            cursor=None,
            hits=hits,
            facet_counts=facet_counts,
        )

    async def _lexical_search(
        self, org_id: str, request: SearchRequest, limit: int, weight: float
    ) -> Dict[str, Dict[str, Any]]:
        if not request.query:
            return {}

        clauses, params = self._build_where_clauses(org_id, request)
        query = "\n".join(
            [
                "SELECT c.chunk_id, c.document_id,",
                "       ts_rank_cd(c.tsv, plainto_tsquery('english', %s)) AS rank",
                "FROM search_chunks c",
                "JOIN search_documents d ON d.document_id = c.document_id",
                "WHERE c.tsv @@ plainto_tsquery('english', %s)",
                *clauses,
                "ORDER BY rank DESC",
                "LIMIT %s",
            ]
        )
        params = [request.query, request.query, *params, limit]
        async with get_connection() as conn:
            async with conn.cursor() as cur:
                await cur.execute(query, params)
                scores: Dict[str, Dict[str, Any]] = {}
                for row in await cur.fetchall():
                    chunk_id, document_id, rank = row
                    score = float(rank or 0.0) * weight
                    scores[chunk_id] = {"score": score, "document_id": document_id, "sources": ["lexical"]}
                return scores

    async def _vector_search(
        self, org_id: str, request: SearchRequest, limit: int, weight: float
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
        search_filter = qm.Filter(
            must=[qm.FieldCondition(key="org_id", match=qm.MatchValue(value=org_id))]
        )
        try:
            response = self._client.search(
                collection_name=self._settings.qdrant_collection,
                query_vector=vector.tolist(),
                limit=limit,
                with_payload=True,
                query_filter=search_filter,
            )
        except Exception as exc:  # pragma: no cover - network fallback path
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
            scores[chunk_id] = {"score": similarity, "document_id": document_id, "sources": ["vector"]}
        return scores

    async def _load_hits(
        self,
        org_id: str,
        ordered: List[Tuple[str, Dict[str, Any]]],
        request: SearchRequest,
    ) -> List[SearchHit]:
        if not ordered:
            return []

        chunk_ids = [chunk_id for chunk_id, _ in ordered]
        async with get_connection() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    SELECT c.chunk_id, c.document_id, c.text, d.title, d.url, d.facets, d.metadata
                    FROM search_chunks c
                    JOIN search_documents d ON d.document_id = c.document_id
                    WHERE c.chunk_id = ANY(%s)
                    """,
                    (chunk_ids,),
                )
                records = {row[0]: row for row in await cur.fetchall()}

        hits: List[SearchHit] = []
        for chunk_id, meta in ordered:
            record = records.get(chunk_id)
            if not record:
                continue
            _, document_id, text, title, url, facets_json, metadata_json = record
            snippet = text[:400]
            score = float(meta["score"])
            sources = meta.get("sources", [])
            facets_payload = facets_json or []
            metadata_payload = metadata_json or {}
            hits.append(
                SearchHit(
                    document_id=document_id,
                    chunk_id=chunk_id,
                    title=title,
                    url=url,
                    snippet=snippet,
                    highlights=[],
                    score=round(score, 4),
                    facets=[Facet(**facet) for facet in facets_payload],
                    metadata=metadata_payload,
                    sources=sources,
                )
            )
        return hits

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

    def _build_where_clauses(self, org_id: str, request: SearchRequest) -> Tuple[List[str], List[Any]]:
        clauses = ["AND c.org_id = %s"]
        params: List[Any] = [org_id]
        filters = request.must + request.filter
        for flt in filters:
            if flt.term and flt.value:
                field = flt.term
                value = flt.value
                if field in {"source", "source_id"}:
                    clauses.append("AND d.source_id = %s")
                    params.append(value)
                elif field.startswith("tag"):
                    clauses.append("AND %s = ANY(d.tags)")
                    params.append(value)
                else:
                    clauses.append("AND d.metadata ->> %s = %s")
                    params.extend([field, value])
            elif flt.range:
                field = flt.range.field
                if field in {"created_at", "updated_at"}:
                    if flt.range.gte is not None:
                        clauses.append(f"AND d.{field} >= %s")
                        params.append(flt.range.gte)
                    if flt.range.lte is not None:
                        clauses.append(f"AND d.{field} <= %s")
                        params.append(flt.range.lte)
        return clauses, params

    def _aggregate_facets(self, hits: List[SearchHit], request: SearchRequest) -> Dict[str, Dict[str, int]]:
        requested = set(request.facets)
        if not requested:
            return {}

        counts: Dict[str, Dict[str, int]] = defaultdict(lambda: defaultdict(int))
        for hit in hits:
            for facet in hit.facets:
                if facet.key in requested:
                    counts[facet.key][facet.value] += 1
        return {key: dict(value_counts) for key, value_counts in counts.items()}


__all__ = ["HybridSearchService"]
