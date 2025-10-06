from __future__ import annotations

import os
from collections import defaultdict
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Dict, List, Sequence

import psycopg
from fastapi import Depends, FastAPI, HTTPException, Query, Request, status
from pydantic import BaseModel, Field
from qdrant_client import QdrantClient
from sentence_transformers import SentenceTransformer

from shared.db import get_conn_str
from shared.logging import get_logger, setup_logging

logger = get_logger("gateway.api")


class GatewaySettings(BaseModel):
    database_url: str = Field(default_factory=get_conn_str)
    api_token: str = Field(default_factory=lambda: os.getenv("AUTH_TOKEN", ""))
    embedding_model: str = Field(default_factory=lambda: os.getenv("EMBEDDING_MODEL", "BAAI/bge-m3"))
    embedding_dim: int = Field(default_factory=lambda: int(os.getenv("EMBEDDING_DIM", "1024")))
    qdrant_url: str = Field(default_factory=lambda: os.getenv("QDRANT_URL", "http://qdrant:6333"))
    qdrant_collection: str = Field(default_factory=lambda: os.getenv("QDRANT_COLLECTION", "imessage_chunks"))


settings = GatewaySettings()
app = FastAPI(title="Haven Gateway API", version="0.1.0")

_model: SentenceTransformer | None = None
_client: QdrantClient | None = None


@app.on_event("startup")
def on_startup() -> None:
    setup_logging()
    os.environ.setdefault("DATABASE_URL", settings.database_url)
    global _model, _client
    if _model is None:
        _model = SentenceTransformer(settings.embedding_model)
    if _client is None:
        _client = QdrantClient(url=settings.qdrant_url)
    logger.info("gateway_api_ready", collection=settings.qdrant_collection)


def get_model() -> SentenceTransformer:
    if _model is None:
        raise RuntimeError("model not initialized")
    return _model


def get_client() -> QdrantClient:
    if _client is None:
        raise RuntimeError("qdrant client not initialized")
    return _client


@dataclass
class MessageDoc:
    doc_id: str
    thread_id: str
    ts: datetime
    sender: str
    text: str


class SearchHit(BaseModel):
    doc_id: str
    thread_id: str
    ts: datetime
    sender: str
    text: str
    score: float
    sources: List[str]


class SearchResponse(BaseModel):
    query: str
    results: List[SearchHit]


class AskRequest(BaseModel):
    query: str
    k: int = 5


class AskResponse(BaseModel):
    query: str
    answer: str
    citations: List[Dict[str, Any]]


def require_token(request: Request) -> None:
    if not settings.api_token:
        return
    header = request.headers.get("Authorization")
    if not header or not header.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing token")
    token = header.split(" ", 1)[1]
    if token != settings.api_token:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid token")


def fetch_messages_by_doc_ids(conn: psycopg.Connection, doc_ids: Sequence[str]) -> Dict[str, MessageDoc]:
    if not doc_ids:
        return {}
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT doc_id, thread_id, ts, sender, text
            FROM messages
            WHERE doc_id = ANY(%s)
            """,
            (list(doc_ids),),
        )
        records = {
            row[0]: MessageDoc(
                doc_id=row[0],
                thread_id=row[1],
                ts=row[2],
                sender=row[3],
                text=row[4],
            )
            for row in cur.fetchall()
        }
    return records


def lexical_search(conn: psycopg.Connection, query_text: str, limit: int) -> Dict[str, float]:
    if not query_text:
        return {}
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT doc_id,
                   ts_rank_cd(tsv, plainto_tsquery('english', %s)) AS rank
            FROM messages
            WHERE tsv @@ plainto_tsquery('english', %s)
            ORDER BY rank DESC
            LIMIT %s
            """,
            (query_text, query_text, limit),
        )
        scores: Dict[str, float] = {}
        for idx, row in enumerate(cur.fetchall()):
            rank = row[1] or 0.0
            score = 1.0 / (60 + idx) + rank
            scores[row[0]] = score
        return scores


def vector_search(query_text: str, limit: int) -> Dict[str, float]:
    if not query_text:
        return {}
    model = get_model()
    client = get_client()
    query_vector = model.encode([query_text], normalize_embeddings=True)[0]
    search_result = client.search(
        collection_name=settings.qdrant_collection,
        query_vector=query_vector.tolist(),
        limit=limit,
        with_payload=True,
    )
    scores: Dict[str, float] = {}
    for idx, point in enumerate(search_result):
        payload = point.payload or {}
        doc_id = payload.get("doc_id")
        if not doc_id:
            continue
        similarity = point.score or 0.0
        score = 1.0 / (60 + idx) + similarity
        if doc_id in scores:
            scores[doc_id] = max(scores[doc_id], score)
        else:
            scores[doc_id] = score
    return scores


def fuse_scores(lexical: Dict[str, float], semantic: Dict[str, float]) -> Dict[str, Dict[str, Any]]:
    fused: Dict[str, Dict[str, Any]] = defaultdict(lambda: {"score": 0.0, "sources": []})
    for doc_id, score in lexical.items():
        fused[doc_id]["score"] += score
        fused[doc_id]["sources"].append("lexical")
    for doc_id, score in semantic.items():
        fused[doc_id]["score"] += score
        fused[doc_id]["sources"].append("semantic")
    return fused


@app.get("/v1/search", response_model=SearchResponse)
async def search_endpoint(
    q: str = Query(..., min_length=1),
    k: int = Query(20, ge=1, le=50),
    _: None = Depends(require_token),
) -> SearchResponse:
    with psycopg.connect(settings.database_url) as conn:
        lexical_scores = lexical_search(conn, q, k)
        semantic_scores = vector_search(q, k)
        fused = fuse_scores(lexical_scores, semantic_scores)
        doc_ids = sorted(fused.keys(), key=lambda doc: fused[doc]["score"], reverse=True)[:k]
        docs = fetch_messages_by_doc_ids(conn, doc_ids)

    results: List[SearchHit] = []
    for doc_id in doc_ids:
        doc = docs.get(doc_id)
        if not doc:
            continue
        results.append(
            SearchHit(
                doc_id=doc.doc_id,
                thread_id=doc.thread_id,
                ts=doc.ts,
                sender=doc.sender,
                text=doc.text,
                score=round(fused[doc_id]["score"], 4),
                sources=fused[doc_id]["sources"],
            )
        )
    return SearchResponse(query=q, results=results)


def build_summary_text(query: str, docs: Sequence[MessageDoc]) -> str:
    if not docs:
        return "No relevant messages found."

    summary_sentences: List[str] = []
    for doc in docs:
        ts_str = doc.ts.astimezone(UTC).strftime("%Y-%m-%d %H:%M")
        summary_sentences.append(
            f"{doc.sender} mentioned '{doc.text}' on {ts_str} UTC."
        )
        if len(summary_sentences) >= 3:
            break

    intro = f"Summary for query '{query}':"
    return intro + " " + " ".join(summary_sentences)


@app.post("/v1/ask", response_model=AskResponse)
async def ask_endpoint(
    payload: AskRequest,
    _: None = Depends(require_token),
) -> AskResponse:
    k = min(max(payload.k, 1), 10)
    with psycopg.connect(settings.database_url) as conn:
        lexical_scores = lexical_search(conn, payload.query, k)
        semantic_scores = vector_search(payload.query, k)
        fused = fuse_scores(lexical_scores, semantic_scores)
        doc_ids = sorted(fused.keys(), key=lambda doc: fused[doc]["score"], reverse=True)[:k]
        docs = fetch_messages_by_doc_ids(conn, doc_ids)

    ordered_docs = [docs[doc_id] for doc_id in doc_ids if doc_id in docs]
    answer = build_summary_text(payload.query, ordered_docs)
    citations = [
        {"doc_id": doc.doc_id, "ts": doc.ts.astimezone(UTC).isoformat()}
        for doc in ordered_docs[:3]
    ]
    return AskResponse(query=payload.query, answer=answer, citations=citations)


@app.get("/v1/doc/{doc_id}")
async def doc_endpoint(doc_id: str, _: None = Depends(require_token)) -> Dict[str, Any]:
    with psycopg.connect(settings.database_url) as conn:
        docs = fetch_messages_by_doc_ids(conn, [doc_id])
    doc = docs.get(doc_id)
    if not doc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Document not found")
    return {
        "doc_id": doc.doc_id,
        "thread_id": doc.thread_id,
        "ts": doc.ts,
        "sender": doc.sender,
        "text": doc.text,
    }


@app.get("/v1/context/general")
async def context_general(_: None = Depends(require_token)) -> Dict[str, Any]:
    with psycopg.connect(settings.database_url) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM threads")
            total_threads = cur.fetchone()[0]

            cur.execute("SELECT COUNT(*) FROM messages")
            total_messages = cur.fetchone()[0]

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
                ORDER BY ts DESC
                LIMIT 5
                """
            )
            recent_highlights = [
                {
                    "doc_id": row[0],
                    "thread_id": row[1],
                    "ts": row[2],
                    "sender": row[3],
                    "text": row[4],
                }
                for row in cur.fetchall()
            ]

    return {
        "total_threads": total_threads,
        "total_messages": total_messages,
        "top_threads": top_threads,
        "recent_highlights": recent_highlights,
    }


@app.get("/v1/healthz")
async def health() -> Dict[str, str]:
    return {"status": "ok"}

