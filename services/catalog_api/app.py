from __future__ import annotations

import hashlib
import os
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Dict, Iterator, List, Optional

import orjson
import psycopg
from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response, status
from fastapi.responses import StreamingResponse
from psycopg.rows import dict_row
from psycopg.types.json import Json
from pydantic import BaseModel, Field
from qdrant_client import QdrantClient
from qdrant_client.http import models as qm

from shared.context import fetch_context_overview, is_message_text_valid
from shared.db import get_connection
from shared.logging import get_logger, setup_logging

logger = get_logger("catalog.api")


class CatalogSettings(BaseModel):
    database_url: str = Field(
        default_factory=lambda: os.getenv(
            "DATABASE_URL", "postgresql://postgres:postgres@postgres:5432/haven"
        )
    )
    ingest_token: Optional[str] = Field(default_factory=lambda: os.getenv("CATALOG_TOKEN"))
    qdrant_url: str = Field(default_factory=lambda: os.getenv("QDRANT_URL", "http://qdrant:6333"))
    qdrant_collection: str = Field(default_factory=lambda: os.getenv("QDRANT_COLLECTION", "haven_chunks"))
    contacts_default_region: str | None = Field(default_factory=lambda: os.getenv("CONTACTS_DEFAULT_REGION", "US"))


settings = CatalogSettings()
app = FastAPI(title="Haven Catalog API", version="0.3.0")

_qdrant_client: QdrantClient | None = None


def verify_token(request: Request) -> None:
    if not settings.ingest_token:
        return
    header = request.headers.get("Authorization")
    if not header or not header.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing token")
    token = header.split(" ", 1)[1]
    if token != settings.ingest_token:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid token")


def get_qdrant_client() -> QdrantClient:
    global _qdrant_client
    if _qdrant_client is None:
        _qdrant_client = QdrantClient(url=settings.qdrant_url)
    return _qdrant_client


def ensure_qdrant_collection(client: QdrantClient, vector_size: int) -> None:
    try:
        info = client.get_collection(settings.qdrant_collection)
        current_size = info.config.params.vectors.size  # type: ignore[attr-defined]
        if current_size != vector_size:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Qdrant collection vector size mismatch (expected {vector_size}, found {current_size})",
            )
    except Exception as exc:
        logger.info("creating_qdrant_collection", collection=settings.qdrant_collection)
        try:
            client.create_collection(
                collection_name=settings.qdrant_collection,
                vectors_config=qm.VectorParams(size=vector_size, distance=qm.Distance.COSINE),
            )
        except Exception as create_exc:  # pragma: no cover
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Failed to create Qdrant collection: {create_exc}",
            ) from exc


@app.on_event("startup")
def on_startup() -> None:
    setup_logging()
    os.environ.setdefault("DATABASE_URL", settings.database_url)
    logger.info("catalog_api_startup", qdrant_collection=settings.qdrant_collection)


class DocumentIngestRequest(BaseModel):
    idempotency_key: str
    source_type: str
    source_id: str
    content_sha256: str
    text: str
    mime_type: str = "text/plain"
    canonical_uri: Optional[str] = None
    title: Optional[str] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)


class DocumentIngestResponse(BaseModel):
    submission_id: str
    doc_id: Optional[str]
    status: str
    total_chunks: int
    duplicate: bool = False


class SubmissionStatusResponse(BaseModel):
    submission_id: str
    status: str
    doc_id: Optional[str] = None
    document_status: Optional[str] = None
    total_chunks: int = 0
    embedded_chunks: int = 0
    pending_chunks: int = 0
    error: Optional[Dict[str, Any]] = None


class DocumentStatusResponse(BaseModel):
    doc_id: str
    status: str
    submission_id: str
    total_chunks: int
    embedded_chunks: int
    pending_chunks: int


class EmbeddingSubmitRequest(BaseModel):
    chunk_id: str
    vector: List[float]
    model: str
    dimensions: int


class EmbeddingSubmitResponse(BaseModel):
    chunk_id: str
    status: str


class DeleteDocumentResponse(BaseModel):
    doc_id: str
    status: str


def _normalize_text(value: str) -> str:
    return value.replace("\r\n", "\n").replace("\r", "\n").strip()


@dataclass
class ChunkCandidate:
    ordinal: int
    text: str
    text_sha256: str


def _chunk_text(text: str, max_chars: int = 1200, overlap: int = 200) -> List[ChunkCandidate]:
    normalized = _normalize_text(text)
    if not normalized:
        return []
    length = len(normalized)
    ordinal = 0
    start = 0
    chunks: List[ChunkCandidate] = []
    while start < length:
        end = min(length, start + max_chars)
        if end < length:
            # Try to break on whitespace or newline to avoid mid-word splits.
            window = normalized[start:end]
            newline_break = window.rfind("\n")
            space_break = window.rfind(" ")
            candidate_break = max(newline_break, space_break)
            min_chunk = max_chars // 2
            if candidate_break >= min_chunk:
                end = start + candidate_break
        chunk_text = normalized[start:end].strip()
        if chunk_text:
            chunk_hash = hashlib.sha256(chunk_text.encode("utf-8")).hexdigest()
            chunks.append(ChunkCandidate(ordinal=ordinal, text=chunk_text, text_sha256=chunk_hash))
            ordinal += 1
        if end >= length:
            break
        start = max(start + 1, end - overlap)
    return chunks


def _row_to_dict(cur, row) -> dict:
    cols = [d[0] for d in cur.description]
    return {k: v for k, v in zip(cols, row)}


@app.post(
    "/v1/catalog/documents",
    response_model=DocumentIngestResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def register_document(
    payload: DocumentIngestRequest,
    response: Response,
    _token: None = Depends(verify_token),
) -> DocumentIngestResponse:
    chunk_candidates = _chunk_text(payload.text)
    if not chunk_candidates:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Document produced no valid chunks")

    text_sha = hashlib.sha256(_normalize_text(payload.text).encode("utf-8")).hexdigest()

    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                INSERT INTO ingest_submissions (idempotency_key, source_type, source_id, content_sha256, status)
                VALUES (%s, %s, %s, %s, 'submitted')
                ON CONFLICT (idempotency_key) DO NOTHING
                RETURNING submission_id, status
                """,
                (payload.idempotency_key, payload.source_type, payload.source_id, payload.content_sha256),
            )
            inserted = cur.fetchone()
            if not inserted:
                cur.execute(
                    """
                    SELECT submission_id, status
                    FROM ingest_submissions
                    WHERE idempotency_key = %s
                    """,
                    (payload.idempotency_key,),
                )
                existing = cur.fetchone()
                if not existing:
                    conn.rollback()
                    raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to load submission")
                conn.commit()
                response.status_code = status.HTTP_200_OK
                return DocumentIngestResponse(
                    submission_id=str(existing["submission_id"]),
                    doc_id=None,
                    status=existing["status"],
                    total_chunks=0,
                    duplicate=True,
                )

            submission_id = inserted["submission_id"]
            cur.execute(
                """
                INSERT INTO documents (submission_id, canonical_uri, mime_type, title, text, text_sha256, metadata, status)
                VALUES (%s, %s, %s, %s, %s, %s, %s, 'submitted')
                RETURNING doc_id
                """,
                (
                    submission_id,
                    payload.canonical_uri,
                    payload.mime_type,
                    payload.title,
                    _normalize_text(payload.text),
                    text_sha,
                    Json(payload.metadata),
                ),
            )
            doc_row = cur.fetchone()
            if not doc_row:
                conn.rollback()
                raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to create document record")

            doc_id = doc_row["doc_id"]
            doc_uuid = uuid.UUID(str(doc_id))

            cur.execute(
                "UPDATE ingest_submissions SET status = 'cataloged' WHERE submission_id = %s",
                (submission_id,),
            )
            cur.execute(
                "UPDATE documents SET status = 'cataloged' WHERE doc_id = %s",
                (doc_id,),
            )

            for chunk in chunk_candidates:
                chunk_uuid = uuid.uuid5(doc_uuid, f"chunk:{chunk.ordinal}")
                cur.execute(
                    """
                    INSERT INTO chunks (chunk_id, doc_id, ord, text, text_sha256, status)
                    VALUES (%s, %s, %s, %s, %s, 'queued')
                    ON CONFLICT (chunk_id) DO UPDATE
                    SET text = EXCLUDED.text,
                        text_sha256 = EXCLUDED.text_sha256,
                        status = 'queued',
                        updated_at = NOW()
                    """,
                    (chunk_uuid, doc_id, chunk.ordinal, chunk.text, chunk.text_sha256),
                )
                cur.execute(
                    """
                    INSERT INTO embed_jobs (chunk_id, tries, last_error, locked_by, locked_at, next_attempt_at)
                    VALUES (%s, 0, NULL, NULL, NULL, NOW())
                    ON CONFLICT (chunk_id) DO UPDATE
                    SET last_error = NULL,
                        locked_by = NULL,
                        locked_at = NULL,
                        next_attempt_at = NOW()
                    """,
                    (chunk_uuid,),
                )

            cur.execute(
                "UPDATE documents SET status = 'chunked' WHERE doc_id = %s",
                (doc_id,),
            )
            cur.execute(
                "UPDATE ingest_submissions SET status = 'chunked' WHERE submission_id = %s",
                (submission_id,),
            )
            cur.execute(
                "UPDATE documents SET status = 'embedding_pending' WHERE doc_id = %s",
                (doc_id,),
            )
            cur.execute(
                "UPDATE ingest_submissions SET status = 'embedding_pending' WHERE submission_id = %s",
                (submission_id,),
            )
        conn.commit()

    response.status_code = status.HTTP_202_ACCEPTED
    return DocumentIngestResponse(
        submission_id=str(submission_id),
        doc_id=str(doc_id),
        status="embedding_pending",
        total_chunks=len(chunk_candidates),
        duplicate=False,
    )


@app.get("/v1/catalog/submissions/{submission_id}", response_model=SubmissionStatusResponse)
def get_submission_status(submission_id: str, _token: None = Depends(verify_token)) -> SubmissionStatusResponse:
    try:
        submission_uuid = uuid.UUID(submission_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid submission_id") from exc

    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT
                    s.submission_id,
                    s.status,
                    s.error_json,
                    d.doc_id,
                    d.status AS document_status,
                    COALESCE(stats.total_chunks, 0) AS total_chunks,
                    COALESCE(stats.embedded_chunks, 0) AS embedded_chunks,
                    COALESCE(stats.pending_chunks, 0) AS pending_chunks
                FROM ingest_submissions s
                LEFT JOIN documents d ON d.submission_id = s.submission_id
                LEFT JOIN (
                    SELECT
                        doc_id,
                        COUNT(*) AS total_chunks,
                        COUNT(*) FILTER (WHERE status = 'embedded') AS embedded_chunks,
                        COUNT(*) FILTER (WHERE status IN ('queued', 'embedding')) AS pending_chunks
                    FROM chunks
                    GROUP BY doc_id
                ) stats ON stats.doc_id = d.doc_id
                WHERE s.submission_id = %s
                """,
                (submission_uuid,),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Submission not found")

    error_payload = row["error_json"]
    if isinstance(error_payload, memoryview):
        error_payload = orjson.loads(error_payload.tobytes())

    return SubmissionStatusResponse(
        submission_id=str(row["submission_id"]),
        status=row["status"],
        doc_id=str(row["doc_id"]) if row["doc_id"] else None,
        document_status=row["document_status"],
        total_chunks=row["total_chunks"],
        embedded_chunks=row["embedded_chunks"],
        pending_chunks=row["pending_chunks"],
        error=error_payload,
    )


@app.get("/v1/catalog/documents/{doc_id}/status", response_model=DocumentStatusResponse)
def get_document_status(doc_id: str, _token: None = Depends(verify_token)) -> DocumentStatusResponse:
    try:
        doc_uuid = uuid.UUID(doc_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid doc_id") from exc

    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT
                    d.doc_id,
                    d.submission_id,
                    d.status,
                    COALESCE(stats.total_chunks, 0) AS total_chunks,
                    COALESCE(stats.embedded_chunks, 0) AS embedded_chunks,
                    COALESCE(stats.pending_chunks, 0) AS pending_chunks
                FROM documents d
                LEFT JOIN (
                    SELECT
                        doc_id,
                        COUNT(*) AS total_chunks,
                        COUNT(*) FILTER (WHERE status = 'embedded') AS embedded_chunks,
                        COUNT(*) FILTER (WHERE status IN ('queued', 'embedding')) AS pending_chunks
                    FROM chunks
                    GROUP BY doc_id
                ) stats ON stats.doc_id = d.doc_id
                WHERE d.doc_id = %s
                """,
                (doc_uuid,),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Document not found")

    return DocumentStatusResponse(
        doc_id=str(row["doc_id"]),
        submission_id=str(row["submission_id"]),
        status=row["status"],
        total_chunks=row["total_chunks"],
        embedded_chunks=row["embedded_chunks"],
        pending_chunks=row["pending_chunks"],
    )


class DocumentUpdateRequest(BaseModel):
    metadata: Dict[str, Any]
    text: str
    requeue_for_embedding: bool = True


class DocumentUpdateResponse(BaseModel):
    doc_id: str
    status: str
    chunks_requeued: int = 0


@app.patch("/v1/catalog/documents/{doc_id}", response_model=DocumentUpdateResponse)
def update_document(
    doc_id: str,
    payload: DocumentUpdateRequest,
    _token: None = Depends(verify_token)
) -> DocumentUpdateResponse:
    """Update a document's metadata and text, optionally re-queuing chunks for embedding."""
    try:
        doc_uuid = uuid.UUID(doc_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid doc_id") from exc

    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            # Check document exists
            cur.execute(
                "SELECT doc_id, status FROM documents WHERE doc_id = %s FOR UPDATE",
                (doc_uuid,),
            )
            doc_row = cur.fetchone()
            if not doc_row:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Document not found")

            # Update document
            cur.execute(
                """
                UPDATE documents
                SET metadata = %s,
                    text = %s,
                    updated_at = NOW()
                WHERE doc_id = %s
                """,
                (Json(payload.metadata), payload.text, doc_uuid),
            )

            chunks_requeued = 0
            if payload.requeue_for_embedding:
                # Re-queue all chunks for re-embedding
                cur.execute(
                    """
                    UPDATE chunks
                    SET status = 'queued',
                        text = %s,
                        updated_at = NOW()
                    WHERE doc_id = %s
                    RETURNING chunk_id
                    """,
                    (payload.text, doc_uuid),
                )
                chunk_ids = [str(row["chunk_id"]) for row in cur.fetchall()]
                chunks_requeued = len(chunk_ids)

                # Reset embed_jobs for all chunks
                for chunk_id in chunk_ids:
                    cur.execute(
                        """
                        INSERT INTO embed_jobs (chunk_id, tries, last_error, locked_by, locked_at, next_attempt_at)
                        VALUES (%s, 0, NULL, NULL, NULL, NOW())
                        ON CONFLICT (chunk_id) DO UPDATE
                        SET tries = 0,
                            last_error = NULL,
                            locked_by = NULL,
                            locked_at = NULL,
                            next_attempt_at = NOW()
                        """,
                        (chunk_id,),
                    )

        conn.commit()

    return DocumentUpdateResponse(
        doc_id=str(doc_uuid),
        status="updated",
        chunks_requeued=chunks_requeued,
    )


@app.post("/v1/catalog/embeddings", response_model=EmbeddingSubmitResponse)
def submit_embedding(payload: EmbeddingSubmitRequest, _token: None = Depends(verify_token)) -> EmbeddingSubmitResponse:
    if not payload.vector:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Embedding vector is required")
    if payload.dimensions != len(payload.vector):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Vector length does not match dimensions")

    try:
        chunk_uuid = uuid.UUID(payload.chunk_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid chunk_id") from exc

    client = get_qdrant_client()
    ensure_qdrant_collection(client, payload.dimensions)

    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT c.chunk_id, c.doc_id, c.status, d.submission_id
                FROM chunks c
                JOIN documents d ON d.doc_id = c.doc_id
                WHERE c.chunk_id = %s
                FOR UPDATE
                """,
                (chunk_uuid,),
            )
            chunk_row = cur.fetchone()
            if not chunk_row:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Chunk not found")

            doc_id = chunk_row["doc_id"]
            submission_id = chunk_row["submission_id"]

            client.upsert(
                collection_name=settings.qdrant_collection,
                points=qm.Batch(
                    ids=[str(chunk_uuid)],
                    vectors=[payload.vector],
                    payloads=[
                        {
                            "doc_id": str(doc_id),
                            "submission_id": str(submission_id),
                            "model": payload.model,
                        }
                    ],
                ),
            )

            cur.execute(
                "UPDATE chunks SET status = 'embedded', updated_at = NOW() WHERE chunk_id = %s",
                (chunk_uuid,),
            )
            cur.execute("DELETE FROM embed_jobs WHERE chunk_id = %s", (chunk_uuid,))

            cur.execute(
                """
                SELECT
                    COUNT(*) AS total_chunks,
                    COUNT(*) FILTER (WHERE status = 'embedded') AS embedded_chunks
                FROM chunks
                WHERE doc_id = %s
                """,
                (doc_id,),
            )
            counts = cur.fetchone()
            if counts and counts["total_chunks"] == counts["embedded_chunks"]:
                cur.execute(
                    "UPDATE documents SET status = 'ingested_complete' WHERE doc_id = %s",
                    (doc_id,),
                )
                cur.execute(
                    "UPDATE ingest_submissions SET status = 'ingested_complete', error_json = NULL WHERE submission_id = %s",
                    (submission_id,),
                )
            else:
                cur.execute(
                    "UPDATE documents SET status = 'embedding_pending' WHERE doc_id = %s",
                    (doc_id,),
                )
                cur.execute(
                    "UPDATE ingest_submissions SET status = 'embedding_pending' WHERE submission_id = %s",
                    (submission_id,),
                )
        conn.commit()

    return EmbeddingSubmitResponse(chunk_id=str(chunk_uuid), status="embedded")


@app.delete(
    "/v1/catalog/documents/{doc_id}",
    response_model=DeleteDocumentResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def delete_document(doc_id: str, _token: None = Depends(verify_token)) -> DeleteDocumentResponse:
    try:
        doc_uuid = uuid.UUID(doc_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid doc_id") from exc

    chunk_ids: List[str] = []
    submission_id: Optional[uuid.UUID] = None

    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT doc_id, submission_id, status
                FROM documents
                WHERE doc_id = %s
                FOR UPDATE
                """,
                (doc_uuid,),
            )
            doc_row = cur.fetchone()
            if not doc_row:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Document not found")
            submission_id = doc_row["submission_id"]
            status_value = doc_row["status"]
            if status_value == "deleted":
                conn.commit()
                return DeleteDocumentResponse(doc_id=str(doc_uuid), status="deleted")

            cur.execute(
                "UPDATE documents SET status = 'deleting' WHERE doc_id = %s",
                (doc_uuid,),
            )
            if submission_id:
                cur.execute(
                    "UPDATE ingest_submissions SET status = 'deleting' WHERE submission_id = %s",
                    (submission_id,),
                )

            cur.execute(
                "SELECT chunk_id FROM chunks WHERE doc_id = %s",
                (doc_uuid,),
            )
            chunk_ids = [str(row["chunk_id"]) for row in cur.fetchall()]

            if chunk_ids:
                cur.execute(
                    "DELETE FROM chunks WHERE doc_id = %s",
                    (doc_uuid,),
                )
                cur.execute(
                    "DELETE FROM embed_jobs WHERE chunk_id = ANY(%s)",
                    (chunk_ids,),
                )

            cur.execute(
                "UPDATE documents SET status = 'deleted' WHERE doc_id = %s",
                (doc_uuid,),
            )
            if submission_id:
                cur.execute(
                    "UPDATE ingest_submissions SET status = 'deleted', error_json = NULL WHERE submission_id = %s",
                    (submission_id,),
                )
        conn.commit()

    if chunk_ids:
        client = get_qdrant_client()
        client.delete(
            collection_name=settings.qdrant_collection,
            points_selector=qm.PointIdsList(ids=chunk_ids),
        )

    return DeleteDocumentResponse(doc_id=str(doc_uuid), status="deleted")


class DocResponse(BaseModel):
    doc_id: str
    thread_id: str
    ts: datetime
    sender: str
    text: str
    attrs: Dict[str, Any]


class ContextThread(BaseModel):
    thread_id: str
    title: Optional[str]
    message_count: int


class ContextHighlight(BaseModel):
    doc_id: str
    thread_id: str
    ts: datetime
    sender: str
    text: str


class ContextGeneralResponse(BaseModel):
    total_threads: int
    total_messages: int
    last_message_ts: Optional[datetime] = None
    top_threads: List[ContextThread]
    recent_highlights: List[ContextHighlight]


@app.get("/contacts/export")
def export_contacts(
    request: Request,
    since_token: Optional[str] = Query(default=None),
    full: Optional[bool] = Query(default=False),
) -> StreamingResponse:
    verify_token(request)

    def iter_contacts() -> Iterator[bytes]:
        with get_connection() as conn:
            with conn.cursor() as cur:
                if since_token and not full:
                    try:
                        parsed = datetime.fromisoformat(since_token.replace("Z", "+00:00"))
                    except Exception:
                        parsed = None
                    if parsed:
                        cur.execute(
                            """
                            SELECT person_id, display_name, given_name, family_name, organization,
                                   nicknames, notes, photo_hash, version, deleted, updated_at
                            FROM people
                            WHERE updated_at > %s
                            ORDER BY updated_at ASC
                            """,
                            (parsed,),
                        )
                    else:
                        cur.execute(
                            """
                            SELECT person_id, display_name, given_name, family_name, organization,
                                   nicknames, notes, photo_hash, version, deleted, updated_at
                            FROM people
                            ORDER BY updated_at ASC
                            """,
                        )
                else:
                    cur.execute(
                        """
                        SELECT person_id, display_name, given_name, family_name, organization,
                               nicknames, notes, photo_hash, version, deleted, updated_at
                        FROM people
                        ORDER BY updated_at ASC
                        """,
                    )

                for row in cur.fetchall():
                    person = _row_to_dict(cur, row)
                    yield orjson.dumps(person) + b"\n"

    return StreamingResponse(iter_contacts(), media_type="application/x-ndjson")


@app.get("/v1/context/general", response_model=ContextGeneralResponse)
def get_context_general() -> ContextGeneralResponse:
    with get_connection() as conn:
        overview = fetch_context_overview(conn)

    top_threads = [
        ContextThread(
            thread_id=item["thread_id"],
            title=item["title"],
            message_count=item["message_count"],
        )
        for item in overview["top_threads"]
    ]

    recent_highlights = [
        ContextHighlight(
            doc_id=item["doc_id"],
            thread_id=item["thread_id"],
            ts=item["ts"],
            sender=item["sender"],
            text=item["text"],
        )
        for item in overview["recent_highlights"]
    ]

    return ContextGeneralResponse(
        total_threads=overview["total_threads"],
        total_messages=overview["total_messages"],
        last_message_ts=overview["last_message_ts"],
        top_threads=top_threads,
        recent_highlights=recent_highlights,
    )


@app.get("/v1/healthz")
def health_check() -> Dict[str, str]:
    return {"status": "ok"}
