from __future__ import annotations

import asyncio
import hashlib
import os
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
UTC = timezone.utc
from decimal import Decimal
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

import orjson
from fastapi import Depends, FastAPI, HTTPException, Request, Response, status
from pydantic import BaseModel, Field
from psycopg.rows import dict_row
from psycopg.types.json import Json

from shared.db import (
    create_document_version as create_document_version_record,
    get_connection,
)
from shared.logging import get_logger, setup_logging
from shared.people_repository import PeopleResolver
from shared.people_normalization import IdentifierKind
from shared.context import fetch_context_overview
from shared.people_repository import PeopleResolver
from shared.people_normalization import IdentifierKind
from services.catalog_api.models_v2 import (
    DeleteDocumentResponse,
    DocumentBatchIngestError,
    DocumentBatchIngestItem,
    DocumentBatchIngestRequest,
    DocumentBatchIngestResponse,
    DocumentFileLink,
    DocumentIngestRequest,
    DocumentIngestResponse,
    DocumentStatusResponse,
    DocumentVersionRequest,
    DocumentVersionResponse,
    EmbeddingSubmitRequest,
    EmbeddingSubmitResponse,
    FileDescriptor,
    IntentSignalCreateRequest,
    IntentSignalFeedbackRequest,
    IntentSignalResponse,
    IntentStatusResponse,
    PersonPayload,
    SubmissionStatusResponse,
)

print("catalog_api.app.py loaded")

logger = get_logger("catalog.api")


class CatalogSettings(BaseModel):
    database_url: str = Field(
        default_factory=lambda: os.getenv(
            "DATABASE_URL", "postgresql://postgres:postgres@postgres:5432/haven_v2"
        )
    )
    ingest_token: Optional[str] = Field(default_factory=lambda: os.getenv("CATALOG_TOKEN"))
    search_url: str = Field(default_factory=lambda: os.getenv("SEARCH_URL", "http://search:8080"))
    search_token: Optional[str] = Field(default_factory=lambda: os.getenv("SEARCH_TOKEN"))
    forward_to_search: bool = Field(
        default_factory=lambda: os.getenv("CATALOG_FORWARD_TO_SEARCH", "true").lower() == "true"
    )


settings = CatalogSettings()
app = FastAPI(title="Haven Catalog API", version="0.4.0")

_search_client = None  # Lazy-loaded search client


def get_search_client():
    """Return a cached search client instance if available."""
    global _search_client
    if _search_client is None and settings.forward_to_search:
        try:
            from haven.search.sdk import SearchServiceClient
        except ImportError:  # pragma: no cover - optional dependency
            logger.warning(
                "search_sdk_not_available",
                forward_to_search=settings.forward_to_search,
            )
            _search_client = False  # Sentinel to avoid repeated imports
        else:
            _search_client = SearchServiceClient(
                base_url=settings.search_url,
                auth_token=settings.search_token,
                timeout=30.0,
            )
            logger.info("search_client_initialized", search_url=settings.search_url)
    return _search_client if _search_client is not False else None


@app.on_event("startup")
def on_startup() -> None:
    setup_logging()
    os.environ.setdefault("DATABASE_URL", settings.database_url)
    logger.info("catalog_api_startup", forward_to_search=settings.forward_to_search)


def _link_document_people(conn, doc_id: uuid.UUID, people_json: List[Dict[str, Any]]) -> None:
    """Resolve identifiers to person_id and insert into document_people.
    Supports: phone, email, imessage, social, shortcode. Logs others.
    """
    from shared.people_normalization import IdentifierKind
    resolver = PeopleResolver(conn)
    resolved: Dict[tuple[uuid.UUID, uuid.UUID], str] = {}
    kind_map = {
        "phone": IdentifierKind.PHONE,
        "email": IdentifierKind.EMAIL,
        "imessage": IdentifierKind.IMESSAGE,
        "social": IdentifierKind.SOCIAL,
        "shortcode": IdentifierKind.SHORTCODE,
    }
    for person_entry in people_json:
        identifier = person_entry.get("identifier")
        identifier_type = (person_entry.get("identifier_type") or "").lower()
        role = person_entry.get("role") or "participant"
        if not identifier:
            continue
        kind = kind_map.get(identifier_type)
        if not kind:
            logger.info(
                "people_link_skip_unsupported_kind",
                identifier=identifier,
                identifier_type=identifier_type,
                role=role,
                doc_id=str(doc_id),
            )
            continue
        try:
            result = resolver.resolve(kind, identifier)
        except Exception as exc:  # pragma: no cover - defensive logging
            logger.warning(
                "person_resolve_exception", identifier=identifier, type=identifier_type, error=str(exc)
            )
            continue
        if result and result.get("person_id"):
            person_id = uuid.UUID(result["person_id"])
            resolved[(doc_id, person_id)] = role
        else:
            logger.info(
                "person_resolution_not_found",
                identifier=identifier,
                identifier_type=identifier_type,
                doc_id=str(doc_id),
            )
    if not resolved:
        return
    with conn.cursor() as cur:
        for (did, pid), role in resolved.items():
            try:
                cur.execute(
                    """
                    INSERT INTO document_people (doc_id, person_id, role)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (doc_id, person_id) DO UPDATE SET role = EXCLUDED.role
                    """,
                    (did, pid, role),
                )
            except Exception as exc:  # pragma: no cover - defensive logging
                logger.warning(
                    "document_people_insert_failed", doc_id=str(did), person_id=str(pid), error=str(exc)
                )


def verify_token(request: Request) -> None:
    if not settings.ingest_token:
        return
    header = request.headers.get("Authorization")
    if not header or not header.startswith("Bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Missing token")
    token = header.split(" ", 1)[1]
    if token != settings.ingest_token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")


def _normalize_text(value: str) -> str:
    return value.replace("\r\n", "\n").replace("\r", "\n").strip()


@dataclass
class ChunkCandidate:
    ordinal: int
    text: str
    text_sha256: str


@dataclass
class IngestExecutionResult:
    response: DocumentIngestResponse
    status_code: int
    doc_record: Optional[Dict[str, Any]] = None


def _chunk_text(text: str, *, max_chars: int = 1200, overlap: int = 200) -> List[ChunkCandidate]:
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


def _person_dicts(people: Iterable[PersonPayload]) -> List[Dict[str, Any]]:
    return [person.dict(exclude_none=True) for person in people]


def _thread_participants(participants: Iterable[PersonPayload]) -> List[Dict[str, Any]]:
    return [participant.dict(exclude_none=True) for participant in participants]


def _coerce_json(value: Any) -> Any:
    if isinstance(value, memoryview):
        return orjson.loads(value.tobytes())
    if isinstance(value, (bytes, bytearray)):
        return orjson.loads(value)
    return value


def _upsert_file(cur, file_: FileDescriptor) -> uuid.UUID:
    storage_backend = file_.storage_backend or "minio"
    enrichment_status = file_.enrichment_status or "pending"
    cur.execute(
        """
        INSERT INTO files (
            content_sha256,
            object_key,
            storage_backend,
            filename,
            mime_type,
            size_bytes,
            enrichment_status,
            enrichment
        )
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (content_sha256) DO UPDATE
        SET object_key = COALESCE(EXCLUDED.object_key, files.object_key),
            storage_backend = COALESCE(EXCLUDED.storage_backend, files.storage_backend),
            filename = COALESCE(EXCLUDED.filename, files.filename),
            mime_type = COALESCE(EXCLUDED.mime_type, files.mime_type),
            size_bytes = COALESCE(EXCLUDED.size_bytes, files.size_bytes),
            enrichment_status = CASE
                WHEN EXCLUDED.enrichment_status IS NOT NULL THEN EXCLUDED.enrichment_status
                ELSE files.enrichment_status
            END,
            enrichment = COALESCE(EXCLUDED.enrichment, files.enrichment),
            updated_at = NOW()
        RETURNING file_id
        """,
        (
            file_.content_sha256,
            file_.object_key,
            storage_backend,
            file_.filename,
            file_.mime_type,
            file_.size_bytes,
            enrichment_status,
            Json(file_.enrichment) if file_.enrichment is not None else None,
        ),
    )
    row = cur.fetchone()
    if not row:
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to upsert file")
    return row["file_id"]


def _link_document_file(cur, doc_id: uuid.UUID, file_id: uuid.UUID, link: DocumentFileLink) -> None:
    cur.execute(
        """
        INSERT INTO document_files (doc_id, file_id, role, attachment_index, filename, caption)
        VALUES (%s, %s, %s, %s, %s, %s)
        ON CONFLICT (doc_id, file_id, role) DO UPDATE
        SET attachment_index = COALESCE(EXCLUDED.attachment_index, document_files.attachment_index),
            filename = COALESCE(EXCLUDED.filename, document_files.filename),
            caption = COALESCE(EXCLUDED.caption, document_files.caption)
        """,
        (doc_id, file_id, link.role, link.attachment_index, link.filename, link.caption),
    )


def _create_chunks(cur, doc_id: uuid.UUID, chunk_candidates: List[ChunkCandidate]) -> None:
    doc_uuid = uuid.UUID(str(doc_id))
    for candidate in chunk_candidates:
        chunk_uuid = uuid.uuid5(doc_uuid, f"chunk:{candidate.ordinal}")
        cur.execute(
            """
            INSERT INTO chunks (chunk_id, text, text_sha256, ordinal, embedding_status)
            VALUES (%s, %s, %s, %s, 'pending')
            ON CONFLICT (chunk_id) DO UPDATE
            SET text = EXCLUDED.text,
                text_sha256 = EXCLUDED.text_sha256,
                ordinal = EXCLUDED.ordinal,
                embedding_status = 'pending',
                updated_at = NOW()
            """,
            (chunk_uuid, candidate.text, candidate.text_sha256, candidate.ordinal),
        )
        cur.execute(
            """
            INSERT INTO chunk_documents (chunk_id, doc_id, ordinal, weight)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (chunk_id, doc_id) DO UPDATE
            SET ordinal = EXCLUDED.ordinal,
                weight = EXCLUDED.weight
            """,
            (chunk_uuid, doc_id, 0, Decimal("1.0")),
        )


def _apply_document_files(
    cur,
    doc_id: uuid.UUID,
    attachments: List[DocumentFileLink],
) -> Tuple[List[uuid.UUID], bool, int]:
    file_ids: List[uuid.UUID] = []
    attachment_count = 0
    for link in attachments:
        file_id = _upsert_file(cur, link.file)
        _link_document_file(cur, doc_id, file_id, link)
        file_ids.append(file_id)
        if link.role == "attachment":
            attachment_count += 1
    return file_ids, attachment_count > 0, attachment_count


def _copy_document_files(
    cur,
    source_doc_id: uuid.UUID,
    target_doc_id: uuid.UUID,
) -> Tuple[List[uuid.UUID], bool, int]:
    file_ids: List[uuid.UUID] = []
    attachment_count = 0
    cur.execute(
        """
        SELECT file_id, role, attachment_index, filename, caption
        FROM document_files
        WHERE doc_id = %s
        """,
        (source_doc_id,),
    )
    for row in cur.fetchall():
        cur.execute(
            """
            INSERT INTO document_files (doc_id, file_id, role, attachment_index, filename, caption)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (doc_id, file_id, role) DO NOTHING
            """,
            (
                target_doc_id,
                row["file_id"],
                row["role"],
                row["attachment_index"],
                row["filename"],
                row["caption"],
            ),
        )
        file_ids.append(row["file_id"])
        if row["role"] == "attachment":
            attachment_count += 1
    return file_ids, attachment_count > 0, attachment_count


def _chunk_stats(cur, doc_id: uuid.UUID) -> Tuple[int, int, int]:
    cur.execute(
        """
        SELECT
            COUNT(*) AS total_chunks,
            COUNT(*) FILTER (WHERE c.embedding_status = 'embedded') AS embedded_chunks,
            COUNT(*) FILTER (
                WHERE c.embedding_status IN ('pending', 'processing')
            ) AS pending_chunks
        FROM chunk_documents cd
        JOIN chunks c ON c.chunk_id = cd.chunk_id
        WHERE cd.doc_id = %s
        """,
        (doc_id,),
    )
    row = cur.fetchone() or {"total_chunks": 0, "embedded_chunks": 0, "pending_chunks": 0}
    return int(row["total_chunks"] or 0), int(row["embedded_chunks"] or 0), int(row["pending_chunks"] or 0)


def _vector_literal(vector: List[float]) -> str:
    return "[" + ",".join(str(component) for component in vector) + "]"


def _extract_sender(people: Iterable[Dict[str, Any]]) -> Optional[str]:
    for entry in people:
        if entry.get("role") == "sender":
            return entry.get("display_name") or entry.get("identifier")
    return None


def _ensure_submission(
    cur,
    payload: DocumentIngestRequest,
    *,
    batch_id: Optional[uuid.UUID] = None,
) -> Dict[str, Any]:
    cur.execute(
        """
        INSERT INTO ingest_submissions (
            idempotency_key,
            source_type,
            source_id,
            content_sha256,
            batch_id,
            status
        )
        VALUES (%s, %s, %s, %s, %s, 'submitted')
        ON CONFLICT (idempotency_key) DO UPDATE
        SET source_type = EXCLUDED.source_type,
            source_id = EXCLUDED.source_id,
            content_sha256 = EXCLUDED.content_sha256,
            batch_id = COALESCE(ingest_submissions.batch_id, EXCLUDED.batch_id)
        RETURNING submission_id, status, result_doc_id, batch_id
        """,
        (
            payload.idempotency_key,
            payload.source_type,
            payload.source_id,
            payload.content_sha256,
            batch_id,
        ),
    )
    return cur.fetchone()  # type: ignore[return-value]


def _fetch_document_response(
    cur, doc_id: uuid.UUID, duplicate: bool, submission_id: uuid.UUID
) -> DocumentIngestResponse:
    cur.execute(
        """
        SELECT doc_id, external_id, version_number, thread_id, status
        FROM documents
        WHERE doc_id = %s
        """,
        (doc_id,),
    )
    doc_row = cur.fetchone()
    if not doc_row:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Document not found")
    cur.execute(
        "SELECT file_id FROM document_files WHERE doc_id = %s",
        (doc_id,),
    )
    file_ids = [row["file_id"] for row in cur.fetchall()]
    return DocumentIngestResponse(
        submission_id=submission_id,
        doc_id=doc_row["doc_id"],
        external_id=doc_row["external_id"],
        version_number=doc_row["version_number"],
        thread_id=doc_row["thread_id"],
        file_ids=file_ids,
        status=doc_row["status"],
        duplicate=duplicate,
    )


def _upsert_thread(cur, payload: DocumentIngestRequest) -> Optional[uuid.UUID]:
    if payload.thread_id:
        client_tid = uuid.UUID(str(payload.thread_id))
        thread_payload = payload.thread
        if thread_payload:
            # Client provided both thread_id and thread payload - ensure thread row exists
            participants = _thread_participants(thread_payload.participants)
            participant_count = thread_payload.participant_count or (len(participants) if participants else None)
            first_message_at = thread_payload.first_message_at or payload.content_timestamp
            last_message_at = thread_payload.last_message_at or payload.content_timestamp
            
            cur.execute(
                """
                INSERT INTO threads (
                    thread_id,
                    external_id,
                    source_type,
                    source_provider,
                    title,
                    participants,
                    thread_type,
                    is_group,
                    participant_count,
                    metadata,
                    first_message_at,
                    last_message_at
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (external_id) DO UPDATE
                SET title = COALESCE(EXCLUDED.title, threads.title),
                    participants = CASE
                        WHEN jsonb_array_length(EXCLUDED.participants) > 0 THEN EXCLUDED.participants
                        ELSE threads.participants
                    END,
                    thread_type = COALESCE(EXCLUDED.thread_type, threads.thread_type),
                    is_group = COALESCE(EXCLUDED.is_group, threads.is_group),
                    participant_count = COALESCE(EXCLUDED.participant_count, threads.participant_count),
                    metadata = threads.metadata || COALESCE(EXCLUDED.metadata, '{}'::jsonb),
                    first_message_at = LEAST(
                        COALESCE(threads.first_message_at, EXCLUDED.first_message_at),
                        COALESCE(EXCLUDED.first_message_at, threads.first_message_at)
                    ),
                    last_message_at = GREATEST(
                        COALESCE(threads.last_message_at, EXCLUDED.last_message_at),
                        COALESCE(EXCLUDED.last_message_at, threads.last_message_at)
                    ),
                    updated_at = NOW()
                RETURNING thread_id
                """,
                (
                    client_tid,
                    thread_payload.external_id,
                    thread_payload.source_type or payload.source_type,
                    thread_payload.source_provider or payload.source_provider,
                    thread_payload.title,
                    Json(participants if participants else []),
                    thread_payload.thread_type,
                    thread_payload.is_group,
                    participant_count,
                    Json(thread_payload.metadata or {}),
                    first_message_at,
                    last_message_at,
                ),
            )
            row = cur.fetchone()
            if row:
                db_tid = row["thread_id"]
                if db_tid != client_tid:
                    logger.warning(
                        "thread_id_mismatch",
                        client_thread_id=str(client_tid),
                        db_thread_id=str(db_tid),
                        external_id=thread_payload.external_id,
                    )
                return db_tid
            return client_tid
        else:
            # Client provided thread_id only - verify it exists
            cur.execute("SELECT thread_id FROM threads WHERE thread_id = %s", (client_tid,))
            row = cur.fetchone()
            if row:
                return client_tid
            logger.warning("thread_id_missing_no_payload", thread_id=str(client_tid))
            return None
    
    thread_payload = payload.thread
    if not thread_payload:
        return None
    participants = _thread_participants(thread_payload.participants)
    participant_count = thread_payload.participant_count or (len(participants) if participants else None)
    first_message_at = thread_payload.first_message_at or payload.content_timestamp
    last_message_at = thread_payload.last_message_at or payload.content_timestamp
    cur.execute(
        """
        INSERT INTO threads (
            external_id,
            source_type,
            source_provider,
            title,
            participants,
            thread_type,
            is_group,
            participant_count,
            metadata,
            first_message_at,
            last_message_at
        )
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (external_id) DO UPDATE
        SET title = COALESCE(EXCLUDED.title, threads.title),
            participants = CASE
                WHEN jsonb_array_length(EXCLUDED.participants) > 0 THEN EXCLUDED.participants
                ELSE threads.participants
            END,
            thread_type = COALESCE(EXCLUDED.thread_type, threads.thread_type),
            is_group = COALESCE(EXCLUDED.is_group, threads.is_group),
            participant_count = COALESCE(EXCLUDED.participant_count, threads.participant_count),
            metadata = threads.metadata || COALESCE(EXCLUDED.metadata, '{}'::jsonb),
            first_message_at = LEAST(
                COALESCE(threads.first_message_at, EXCLUDED.first_message_at),
                COALESCE(EXCLUDED.first_message_at, threads.first_message_at)
            ),
            last_message_at = GREATEST(
                COALESCE(threads.last_message_at, EXCLUDED.last_message_at),
                COALESCE(EXCLUDED.last_message_at, threads.last_message_at)
            ),
            updated_at = NOW()
        RETURNING thread_id
        """,
        (
            thread_payload.external_id,
            thread_payload.source_type or payload.source_type,
            thread_payload.source_provider or payload.source_provider,
            thread_payload.title,
            Json(participants if participants else []),
            thread_payload.thread_type,
            thread_payload.is_group,
            participant_count,
            Json(thread_payload.metadata or {}),
            first_message_at,
            last_message_at,
        ),
    )
    row = cur.fetchone()
    return row["thread_id"] if row else None


def _mark_submission_failed(submission_id: uuid.UUID, message: str) -> None:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE ingest_submissions
                SET status = 'failed',
                    error_details = %s,
                    updated_at = NOW()
                WHERE submission_id = %s
                """,
                (Json({"message": message}), submission_id),
            )


def _derive_batch_idempotency_key(documents: Sequence[DocumentIngestRequest]) -> str:
    keys = sorted(document.idempotency_key for document in documents if document.idempotency_key)
    seed = "|".join(keys)
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()


def _ensure_batch(cur, batch_key: str, total_count: int) -> Dict[str, Any]:
    cur.execute(
        """
        INSERT INTO ingest_batches (idempotency_key, total_count, status)
        VALUES (%s, %s, 'submitted')
        ON CONFLICT (idempotency_key) DO UPDATE
        SET total_count = GREATEST(ingest_batches.total_count, EXCLUDED.total_count),
            updated_at = NOW()
        RETURNING batch_id, status, total_count, success_count, failure_count
        """,
        (batch_key, total_count),
    )
    return cur.fetchone()


def _set_batch_status(cur, batch_id: uuid.UUID, status_value: str, *, total_count: Optional[int] = None) -> None:
    cur.execute(
        """
        UPDATE ingest_batches
        SET status = %s,
            total_count = COALESCE(%s, total_count),
            updated_at = NOW()
        WHERE batch_id = %s
        """,
        (status_value, total_count, batch_id),
    )


def _finalize_batch(
    batch_id: uuid.UUID,
    total_count: int,
    success_count: int,
    failure_count: int,
) -> Dict[str, Any]:
    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                UPDATE ingest_batches
                SET total_count = %s,
                    success_count = %s,
                    failure_count = %s,
                    status = CASE
                        WHEN %s = 0 AND %s = %s THEN 'completed'
                        WHEN %s = 0 AND %s > 0 THEN 'failed'
                        ELSE 'partial'
                    END,
                    updated_at = NOW()
                WHERE batch_id = %s
                RETURNING batch_id, status, total_count, success_count, failure_count
                """,
                (
                    total_count,
                    success_count,
                    failure_count,
                    failure_count,
                    success_count,
                    total_count,
                    success_count,
                    failure_count,
                    batch_id,
                ),
            )
            row = cur.fetchone()
        conn.commit()
    if not row:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Batch not found")
    return row


def _build_search_document(doc_record: Dict[str, Any]):
    try:
        from haven.search.models import Acl, DocumentUpsert, Facet
    except ImportError:  # pragma: no cover - optional dependency
        logger.warning("search_models_not_available", doc_id=doc_record.get("doc_id"))
        return None

    metadata = _coerce_json(doc_record.get("metadata") or {}) or {}
    if not isinstance(metadata, dict):
        metadata = dict(metadata)
    metadata.setdefault("source_type", doc_record["source_type"])
    if doc_record.get("source_provider"):
        metadata.setdefault("source_provider", doc_record["source_provider"])
    if isinstance(doc_record.get("content_timestamp"), datetime):
        metadata["content_timestamp"] = doc_record["content_timestamp"].isoformat()
    metadata["content_timestamp_type"] = doc_record["content_timestamp_type"]
    if doc_record.get("thread_id"):
        metadata["thread_id"] = str(doc_record["thread_id"])

    people = _coerce_json(doc_record.get("people") or [])
    metadata["people"] = people if isinstance(people, list) else []

    facets = {
        "has_attachments": doc_record["has_attachments"],
        "has_location": doc_record["has_location"],
        "has_due_date": doc_record["has_due_date"],
        "is_completed": doc_record["is_completed"],
    }

    facet_payload = [
        Facet(key=key, value=str(value))
        for key, value in facets.items()
        if value not in (None, False)
    ]

    canonical_uri = doc_record.get("canonical_uri")
    safe_url = None
    if canonical_uri and isinstance(canonical_uri, str):
        lower = canonical_uri.lower()
        if lower.startswith("http://") or lower.startswith("https://"):
            safe_url = canonical_uri
        else:
            logger.debug("skip_non_http_canonical_uri", doc_id=doc_record["doc_id"], canonical_uri=canonical_uri)

    return DocumentUpsert(
        document_id=str(doc_record["doc_id"]),
        source_id=doc_record["external_id"],
        title=doc_record.get("title"),
        url=safe_url,
        text=doc_record["text"],
        metadata=metadata,
        facets=facet_payload,
        acl=Acl(org_id="default"),
    )


def _schedule_forward_to_search(doc_records: Sequence[Dict[str, Any]]) -> None:
    if not doc_records or not settings.forward_to_search:
        return
    client = get_search_client()
    if client is None:
        return

    search_documents = []
    doc_ids: List[str] = []
    for record in doc_records:
        document = _build_search_document(record)
        if document is None:
            continue
        search_documents.append(document)
        doc_ids.append(str(record["doc_id"]))

    if not search_documents:
        return

    async def _forward() -> None:
        await client.abatch_upsert(search_documents)

    def _task() -> None:
        try:
            asyncio.run(_forward())
            logger.info("search_forward_complete", doc_ids=doc_ids)
        except Exception as exc:  # pragma: no cover - defensive
            logger.warning("search_forward_failed", doc_ids=doc_ids, error=str(exc))

    threading.Thread(target=_task, daemon=True).start()


def _ingest_document(
    payload: DocumentIngestRequest,
    *,
    batch_id: Optional[uuid.UUID] = None,
) -> IngestExecutionResult:
    logger.debug("ingest_document", payload=payload)
    chunk_candidates = _chunk_text(payload.text)
    if not chunk_candidates:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            detail="Document produced no valid chunks",
        )

    normalized_text = _normalize_text(payload.text)
    text_sha = hashlib.sha256(normalized_text.encode("utf-8")).hexdigest()
    external_id = payload.external_id or payload.source_id

    log = logger.bind(external_id=external_id, source_type=payload.source_type)
    submission_id: Optional[uuid.UUID] = None
    file_ids: List[uuid.UUID] = []
    doc_record: Optional[Dict[str, Any]] = None

    try:
        with get_connection(autocommit=False) as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                submission = _ensure_submission(cur, payload, batch_id=batch_id)
                submission_id = submission["submission_id"]
                # Acquire a row-level lock on the submission to serialize processing of
                # concurrent requests that share the same idempotency_key.
                cur.execute(
                    "SELECT submission_id FROM ingest_submissions WHERE submission_id = %s FOR UPDATE",
                    (submission_id,),
                )
                if submission["result_doc_id"] and submission["status"] != "failed":
                    log.info("ingest_duplicate_submission", submission_id=submission_id)
                    # Even for duplicates, ensure document_people is populated based on incoming payload
                    people_json = _person_dicts(payload.people)
                    try:
                        logger.debug("linking document people (ingest duplicate submission)", doc_id=str(submission["result_doc_id"]), people_json=people_json)
                        _link_document_people(conn, submission["result_doc_id"], people_json)
                    except Exception as exc:  # pragma: no cover - defensive logging
                        logger.warning(
                            "people_linking_failed_duplicate",
                            doc_id=str(submission["result_doc_id"]),
                            error=str(exc),
                        )
                    duplicate = _fetch_document_response(
                        cur,
                        submission["result_doc_id"],
                        True,
                        submission_id=submission_id,
                    )
                    conn.commit()
                    return IngestExecutionResult(
                        response=duplicate,
                        status_code=status.HTTP_200_OK,
                    )

                people_json = _person_dicts(payload.people)
                thread_id = _upsert_thread(cur, payload)

                immutable_source_types = ("email", "email_local", "sms")
                if payload.source_type in immutable_source_types:
                    cur.execute(
                        """
                        SELECT doc_id, version_number
                        FROM documents
                        WHERE external_id = %s AND is_active_version = true
                        """,
                        (external_id,),
                    )
                    existing_doc = cur.fetchone()
                    if existing_doc:
                        log.info(
                            "ingest_duplicate_immutable_document",
                            doc_id=str(existing_doc["doc_id"]),
                            version_number=existing_doc["version_number"],
                        )
                        # Ensure people links are created/updated for duplicates as well
                        people_json = _person_dicts(payload.people)
                        try:
                            logger.debug("linking document people (ingest duplicate immutable document)", doc_id=str(existing_doc["doc_id"]), people_json=people_json)
                            _link_document_people(conn, existing_doc["doc_id"], people_json)
                        except Exception as exc:  # pragma: no cover - defensive logging
                            logger.warning(
                                "people_linking_failed_duplicate",
                                doc_id=str(existing_doc["doc_id"]),
                                error=str(exc),
                            )
                        cur.execute(
                            """
                            UPDATE ingest_submissions
                            SET result_doc_id = %s,
                                status = 'completed',
                                updated_at = NOW()
                            WHERE submission_id = %s
                            """,
                            (existing_doc["doc_id"], submission_id),
                        )
                        duplicate = _fetch_document_response(
                            cur,
                            existing_doc["doc_id"],
                            True,
                            submission_id=submission_id,
                        )
                        conn.commit()
                        return IngestExecutionResult(
                            response=duplicate,
                            status_code=status.HTTP_200_OK,
                        )

                facet_overrides = payload.facet_overrides or {}
                source_doc_ids = list(payload.source_doc_ids or [])
                related_doc_ids = list(payload.related_doc_ids or [])

                has_location = facet_overrides.get("has_location", payload.has_location or False)
                has_due_date = facet_overrides.get(
                    "has_due_date",
                    payload.has_due_date if payload.has_due_date is not None else payload.due_date is not None,
                )
                is_completed = facet_overrides.get("is_completed", payload.is_completed)
                has_attachments_override = facet_overrides.get("has_attachments")
                attachment_count_override = facet_overrides.get("attachment_count")

                cur.execute(
                    """
                    INSERT INTO documents (
                        external_id,
                        source_type,
                        source_provider,
                        title,
                        text,
                        text_sha256,
                        mime_type,
                        canonical_uri,
                        content_timestamp,
                        content_timestamp_type,
                        content_created_at,
                        content_modified_at,
                        people,
                        thread_id,
                        parent_doc_id,
                        source_doc_ids,
                        related_doc_ids,
                        has_attachments,
                        attachment_count,
                        has_location,
                        has_due_date,
                        due_date,
                        is_completed,
                        completed_at,
                        metadata,
                        status,
                        intent_status
                    )
                    VALUES (
                        %s, %s, %s, %s, %s, %s, %s, %s,
                        %s, %s, %s, %s, %s, %s, %s, %s,
                        %s, %s, %s, %s, %s, %s, %s, %s,
                        %s, %s, %s
                    )
                    RETURNING *
                    """,
                    (
                        external_id,
                        payload.source_type,
                        payload.source_provider,
                        payload.title,
                        normalized_text,
                        text_sha,
                        payload.mime_type or "text/plain",
                        payload.canonical_uri,
                        payload.content_timestamp,
                        payload.content_timestamp_type,
                        payload.content_created_at,
                        payload.content_modified_at,
                        Json(people_json),
                        thread_id,
                        payload.parent_doc_id,
                        source_doc_ids if source_doc_ids else [],
                        related_doc_ids if related_doc_ids else [],
                        has_attachments_override if has_attachments_override is not None else False,
                        attachment_count_override if attachment_count_override is not None else 0,
                        has_location,
                        has_due_date,
                        payload.due_date,
                        is_completed,
                        payload.completed_at,
                        Json(payload.metadata or {}),
                        "submitted",
                        "pending",  # intent_status defaults to 'pending' for automatic queueing
                    ),
                )
                doc_record = cur.fetchone()
                if not doc_record:
                    conn.rollback()
                    raise HTTPException(
                        status.HTTP_500_INTERNAL_SERVER_ERROR,
                        detail="Failed to create document",
                    )

                doc_id = doc_record["doc_id"]
                log = log.bind(doc_id=str(doc_id), version_number=doc_record["version_number"])
                if thread_id:
                    log = log.bind(thread_id=str(thread_id))

                cur.execute(
                    """
                    UPDATE ingest_submissions
                    SET status = 'processing',
                        updated_at = NOW()
                    WHERE submission_id = %s
                    """,
                    (submission_id,),
                )

                cur.execute(
                    """
                    UPDATE documents
                    SET status = 'extracting',
                        updated_at = NOW()
                    WHERE doc_id = %s
                    """,
                    (doc_id,),
                )

                if payload.attachments:
                    file_ids, computed_has_attachments, computed_attachment_count = _apply_document_files(
                        cur, doc_id, payload.attachments
                    )
                else:
                    computed_has_attachments = bool(has_attachments_override)
                    computed_attachment_count = attachment_count_override or 0

                has_attachments = (
                    has_attachments_override if has_attachments_override is not None else computed_has_attachments
                )
                attachment_count = (
                    attachment_count_override if attachment_count_override is not None else computed_attachment_count
                )

                _create_chunks(cur, doc_id, chunk_candidates)

                cur.execute(
                    """
                    UPDATE documents
                    SET has_attachments = %s,
                        attachment_count = %s,
                        status = 'extracted',
                        extraction_failed = false,
                        enrichment_failed = false,
                        updated_at = NOW()
                    WHERE doc_id = %s
                    """,
                    (has_attachments, attachment_count, doc_id),
                )

                cur.execute(
                    """
                    UPDATE ingest_submissions
                    SET status = 'cataloged',
                        result_doc_id = %s,
                        updated_at = NOW()
                    WHERE submission_id = %s
                    """,
                    (doc_id, submission_id),
                )

                # hv-111: Link resolved people to document_people
                try:
                    logger.debug("linking document people (ingest document)", doc_id=str(doc_id), people_json=people_json)
                    _link_document_people(conn, doc_id, people_json)
                except Exception as exc:
                    logger.warning("people_linking_failed", doc_id=str(doc_id), error=str(exc))

            conn.commit()

        doc_record.update(
            {
                "text": normalized_text,
                "has_attachments": has_attachments,
                "attachment_count": attachment_count,
                "has_location": has_location,
                "has_due_date": has_due_date,
                "is_completed": is_completed,
                "people": people_json,
                "metadata": payload.metadata or {},
                "status": "extracted",
            }
        )

        return IngestExecutionResult(
            response=DocumentIngestResponse(
                submission_id=submission_id,
                doc_id=doc_record["doc_id"],
                external_id=doc_record["external_id"],
                version_number=doc_record["version_number"],
                thread_id=doc_record["thread_id"],
                file_ids=file_ids,
                status=doc_record["status"],
                duplicate=False,
            ),
            status_code=status.HTTP_202_ACCEPTED,
            doc_record=doc_record,
        )
    except HTTPException as exc:
        if submission_id:
            _mark_submission_failed(submission_id, str(exc.detail))
        log.warning("ingest_failed", error=str(exc.detail))
        raise
    except Exception as exc:  # pragma: no cover - defensive
        if submission_id:
            _mark_submission_failed(submission_id, str(exc))
        log.exception("ingest_failed_unexpected")
        raise HTTPException(
            status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to ingest document",
        ) from exc

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
    logger.info("register_document", payload=payload)
    result = _ingest_document(payload)
    if result.doc_record:
        _schedule_forward_to_search([result.doc_record])
    response.status_code = result.status_code
    return result.response


@app.post(
    "/v1/catalog/documents/batch",
    response_model=DocumentBatchIngestResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def register_documents_batch(
    payload: DocumentBatchIngestRequest,
    response: Response,
    _token: None = Depends(verify_token),
) -> DocumentBatchIngestResponse:
    logger.info("register_documents_batch", payload=payload)
    if not payload.documents:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            detail="Batch documents payload must include at least one document",
        )

    batch_key = payload.batch_idempotency_key or _derive_batch_idempotency_key(payload.documents)
    total_documents = len(payload.documents)

    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            batch_record = _ensure_batch(cur, batch_key, total_documents)
            batch_id = batch_record["batch_id"]
            _set_batch_status(cur, batch_id, "processing", total_count=total_documents)
        conn.commit()

    results: List[DocumentBatchIngestItem] = []
    search_records: List[Dict[str, Any]] = []
    success_count = 0
    failure_count = 0
    batch_id_uuid = uuid.UUID(str(batch_id)) if not isinstance(batch_id, uuid.UUID) else batch_id

    for index, document in enumerate(payload.documents):
        try:
            result = _ingest_document(document, batch_id=batch_id_uuid)
        except HTTPException as exc:
            failure_count += 1
            detail = exc.detail if isinstance(exc.detail, str) else str(exc.detail)
            results.append(
                DocumentBatchIngestItem(
                    index=index,
                    status_code=exc.status_code,
                    error=DocumentBatchIngestError(
                        code="INGEST.BATCH_HTTP_ERROR",
                        message=detail,
                        details={"status_code": exc.status_code},
                    ),
                )
            )
        except Exception as exc:  # pragma: no cover - defensive
            failure_count += 1
            results.append(
                DocumentBatchIngestItem(
                    index=index,
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    error=DocumentBatchIngestError(
                        code="INGEST.BATCH_UNEXPECTED_ERROR",
                        message="Unexpected error during batch ingest",
                        details={"error": str(exc)},
                    ),
                )
            )
        else:
            results.append(
                DocumentBatchIngestItem(
                    index=index,
                    status_code=result.status_code,
                    document=result.response,
                )
            )
            if result.doc_record:
                search_records.append(result.doc_record)
            if 200 <= result.status_code < 300:
                success_count += 1
            else:
                failure_count += 1

    batch_summary = _finalize_batch(batch_id_uuid, total_documents, success_count, failure_count)

    if search_records:
        _schedule_forward_to_search(search_records)

    response.status_code = (
        status.HTTP_202_ACCEPTED if failure_count == 0 else status.HTTP_207_MULTI_STATUS
    )

    return DocumentBatchIngestResponse(
        batch_id=batch_summary["batch_id"],
        batch_status=batch_summary["status"],
        total_count=batch_summary["total_count"],
        success_count=batch_summary["success_count"],
        failure_count=batch_summary["failure_count"],
        results=results,
    )

@app.patch(
    "/v1/catalog/documents/{doc_id}/version",
    response_model=DocumentVersionResponse,
)
def create_document_version_endpoint(
    doc_id: str,
    payload: DocumentVersionRequest,
    _token: None = Depends(verify_token),
) -> DocumentVersionResponse:
    try:
        doc_uuid = uuid.UUID(doc_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid doc_id") from exc

    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT * FROM documents WHERE doc_id = %s", (doc_uuid,))
            current_doc = cur.fetchone()
            if not current_doc:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Document not found")

    preview_text = payload.text if payload.text is not None else current_doc["text"]
    preview_chunks = _chunk_text(preview_text)
    if not preview_chunks:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            detail="Document produced no valid chunks",
        )

    changes: Dict[str, Any] = {}
    if payload.text is not None:
        normalized = _normalize_text(payload.text)
        changes["text"] = normalized
        changes["text_sha256"] = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
    if payload.title is not None:
        changes["title"] = payload.title
    if payload.metadata is not None:
        changes["metadata"] = payload.metadata
    elif payload.metadata_overrides:
        base_metadata = _coerce_json(current_doc.get("metadata") or {}) or {}
        if not isinstance(base_metadata, dict):
            base_metadata = dict(base_metadata)
        merged_metadata = base_metadata.copy()
        merged_metadata.update(payload.metadata_overrides)
        changes["metadata"] = merged_metadata
    if payload.content_timestamp is not None:
        changes["content_timestamp"] = payload.content_timestamp
    if payload.content_timestamp_type is not None:
        changes["content_timestamp_type"] = payload.content_timestamp_type
    if payload.content_modified_at is not None:
        changes["content_modified_at"] = payload.content_modified_at
    if payload.people is not None:
        changes["people"] = _person_dicts(payload.people)
    if payload.thread_id is not None:
        changes["thread_id"] = payload.thread_id
    if payload.has_location is not None:
        changes["has_location"] = payload.has_location
    if payload.has_due_date is not None:
        changes["has_due_date"] = payload.has_due_date
    if payload.due_date is not None:
        changes["due_date"] = payload.due_date
    if payload.is_completed is not None:
        changes["is_completed"] = payload.is_completed
    if payload.completed_at is not None:
        changes["completed_at"] = payload.completed_at

    new_doc = create_document_version_record(doc_uuid, changes)
    version_log = logger.bind(
        doc_id=str(new_doc.doc_id),
        external_id=new_doc.external_id,
        source_type=new_doc.source_type,
        version_number=new_doc.version_number,
    )

    chunk_candidates = _chunk_text(new_doc.text)
    if not chunk_candidates:
        version_log.error("version_chunk_error")
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            detail="Document produced no valid chunks",
        )

    file_ids: List[uuid.UUID] = []
    has_attachments = False
    attachment_count = 0

    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute("DELETE FROM document_files WHERE doc_id = %s", (new_doc.doc_id,))
            if payload.attachments is not None:
                file_ids, has_attachments, attachment_count = _apply_document_files(
                    cur, new_doc.doc_id, payload.attachments
                )
            else:
                file_ids, has_attachments, attachment_count = _copy_document_files(
                    cur, doc_uuid, new_doc.doc_id
                )

            cur.execute("DELETE FROM chunk_documents WHERE doc_id = %s", (new_doc.doc_id,))
            _create_chunks(cur, new_doc.doc_id, chunk_candidates)

            cur.execute(
                """
                UPDATE documents
                SET has_attachments = %s,
                    attachment_count = %s,
                    status = 'extracted',
                    extraction_failed = false,
                    enrichment_failed = false,
                    updated_at = NOW()
                WHERE doc_id = %s
                """,
                (has_attachments, attachment_count, new_doc.doc_id),
            )

        conn.commit()

    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT * FROM documents WHERE doc_id = %s", (new_doc.doc_id,))
            doc_record = cur.fetchone()

    if doc_record:
        _schedule_forward_to_search([doc_record])

    return DocumentVersionResponse(
        doc_id=new_doc.doc_id,
        previous_version_id=new_doc.previous_version_id,
        external_id=new_doc.external_id,
        version_number=new_doc.version_number,
        thread_id=new_doc.thread_id,
        file_ids=file_ids,
        status=doc_record["status"] if doc_record else "extracted",
    )


@app.get(
    "/v1/catalog/submissions/{submission_id}",
    response_model=SubmissionStatusResponse,
)
def get_submission_status(
    submission_id: str,
    _token: None = Depends(verify_token),
) -> SubmissionStatusResponse:
    try:
        submission_uuid = uuid.UUID(submission_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid submission_id") from exc

    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT submission_id, status, error_details, result_doc_id
                FROM ingest_submissions
                WHERE submission_id = %s
                """,
                (submission_uuid,),
            )
            submission = cur.fetchone()
            if not submission:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Submission not found")

            doc_id = submission["result_doc_id"]
            doc_status = None
            total_chunks = embedded_chunks = pending_chunks = 0

            if doc_id:
                cur.execute(
                    "SELECT status FROM documents WHERE doc_id = %s",
                    (doc_id,),
                )
                doc_row = cur.fetchone()
                if doc_row:
                    doc_status = doc_row["status"]
                    total_chunks, embedded_chunks, pending_chunks = _chunk_stats(cur, doc_id)

    error_payload = _coerce_json(submission["error_details"]) if submission.get("error_details") else None

    return SubmissionStatusResponse(
        submission_id=submission["submission_id"],
        status=submission["status"],
        doc_id=doc_id,
        document_status=doc_status,
        total_chunks=total_chunks,
        embedded_chunks=embedded_chunks,
        pending_chunks=pending_chunks,
        error=error_payload,
    )


@app.get(
    "/v1/catalog/documents/{doc_id}/status",
    response_model=DocumentStatusResponse,
)
def get_document_status(
    doc_id: str,
    _token: None = Depends(verify_token),
) -> DocumentStatusResponse:
    try:
        doc_uuid = uuid.UUID(doc_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid doc_id") from exc

    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT status
                FROM documents
                WHERE doc_id = %s
                """,
                (doc_uuid,),
            )
            doc_row = cur.fetchone()
            if not doc_row:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Document not found")
            total_chunks, embedded_chunks, pending_chunks = _chunk_stats(cur, doc_uuid)

    return DocumentStatusResponse(
        doc_id=doc_uuid,
        status=doc_row["status"],
        total_chunks=total_chunks,
        embedded_chunks=embedded_chunks,
        pending_chunks=pending_chunks,
    )


@app.post(
    "/v1/catalog/embeddings",
    response_model=EmbeddingSubmitResponse,
)
def submit_embedding(
    payload: EmbeddingSubmitRequest,
    _token: None = Depends(verify_token),
) -> EmbeddingSubmitResponse:
    chunk_id = payload.chunk_id
    if len(payload.vector) != payload.dimensions:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            detail="Vector dimensions mismatch",
        )
    vector_literal = _vector_literal(payload.vector)

    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                "SELECT doc_id FROM chunk_documents WHERE chunk_id = %s",
                (chunk_id,),
            )
            mapping = cur.fetchone()
            if not mapping:
                conn.rollback()
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Chunk not found")
            doc_id = mapping["doc_id"]

            cur.execute(
                """
                UPDATE chunks
                SET embedding_status = 'embedded',
                    embedding_model = %s,
                    embedding_vector = %s::vector,
                    updated_at = NOW()
                WHERE chunk_id = %s
                RETURNING chunk_id
                """,
                (payload.model, vector_literal, chunk_id),
            )
            updated = cur.fetchone()
            if not updated:
                conn.rollback()
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Chunk not found")

            total_chunks, embedded_chunks, pending_chunks = _chunk_stats(cur, doc_id)
            new_status = "indexed" if total_chunks > 0 and embedded_chunks == total_chunks else "enriching"
            cur.execute(
                """
                UPDATE documents
                SET status = %s,
                    updated_at = NOW()
                WHERE doc_id = %s
                """,
                (new_status, doc_id),
            )
            conn.commit()

    return EmbeddingSubmitResponse(chunk_id=chunk_id, status="embedded")


@app.delete(
    "/v1/catalog/documents/{doc_id}",
    response_model=DeleteDocumentResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def delete_document(
    doc_id: str,
    _token: None = Depends(verify_token),
) -> DeleteDocumentResponse:
    try:
        doc_uuid = uuid.UUID(doc_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid doc_id") from exc

    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT doc_id, status
                FROM documents
                WHERE doc_id = %s
                FOR UPDATE
                """,
                (doc_uuid,),
            )
            doc_row = cur.fetchone()
            if not doc_row:
                conn.rollback()
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Document not found")

            cur.execute(
                "DELETE FROM document_files WHERE doc_id = %s",
                (doc_uuid,),
            )
            cur.execute(
                "DELETE FROM chunk_documents WHERE doc_id = %s RETURNING chunk_id",
                (doc_uuid,),
            )
            chunk_ids = [row["chunk_id"] for row in cur.fetchall()]

            for chunk_id in chunk_ids:
                cur.execute(
                    "SELECT COUNT(*) AS refs FROM chunk_documents WHERE chunk_id = %s",
                    (chunk_id,),
                )
                refs = cur.fetchone()
                if refs and int(refs["refs"] or 0) == 0:
                    cur.execute(
                        "DELETE FROM chunks WHERE chunk_id = %s",
                        (chunk_id,),
                    )

            cur.execute(
                """
                UPDATE documents
                SET status = 'deleted',
                    is_active_version = false,
                    updated_at = NOW()
                WHERE doc_id = %s
                """,
                (doc_uuid,),
            )

            cur.execute(
                """
                UPDATE ingest_submissions
                SET status = 'deleted',
                    result_doc_id = NULL,
                    updated_at = NOW()
                WHERE result_doc_id = %s
                """,
                (doc_uuid,),
            )

        conn.commit()

    return DeleteDocumentResponse(doc_id=doc_uuid, status="deleted")


class ContextThread(BaseModel):
    thread_id: uuid.UUID
    title: Optional[str]
    message_count: int


class ContextHighlight(BaseModel):
    doc_id: uuid.UUID
    thread_id: Optional[uuid.UUID]
    ts: datetime
    sender: Optional[str] = None
    text: str
    people: List[Dict[str, Any]] = Field(default_factory=list)


class ContextGeneralResponse(BaseModel):
    total_threads: int
    total_messages: int
    last_message_ts: Optional[datetime] = None
    top_threads: List[ContextThread] = Field(default_factory=list)
    recent_highlights: List[ContextHighlight] = Field(default_factory=list)


@app.get("/v1/context/general", response_model=ContextGeneralResponse)
def get_context_general() -> ContextGeneralResponse:
    with get_connection() as conn:
        overview = fetch_context_overview(conn)

    top_threads = [
        ContextThread(
            thread_id=item["thread_id"],
            title=item.get("title"),
            message_count=item.get("message_count", 0),
        )
        for item in overview.get("top_threads", [])
    ]

    recent_highlights = [
        ContextHighlight(
            doc_id=item["doc_id"],
            thread_id=item.get("thread_id"),
            ts=item.get("content_timestamp"),
            sender=_extract_sender(item.get("people", [])),
            text=item.get("text", ""),
            people=item.get("people", []),
        )
        for item in overview.get("recent_highlights", [])
    ]

    return ContextGeneralResponse(
        total_threads=overview.get("total_threads", 0),
        total_messages=overview.get("total_messages", 0),
        last_message_ts=overview.get("last_message_ts"),
        top_threads=top_threads,
        recent_highlights=recent_highlights,
    )


@app.get("/v1/healthz")
def health_check() -> Dict[str, str]:
    return {"status": "ok"}


# ============================================================================
# INTENT SIGNALS ENDPOINTS
# ============================================================================

@app.post(
    "/v1/catalog/intent-signals",
    response_model=IntentSignalResponse,
    status_code=status.HTTP_201_CREATED,
)
def create_intent_signal(
    payload: IntentSignalCreateRequest,
    _token: None = Depends(verify_token),
) -> IntentSignalResponse:
    """Persist an intent signal from the intents worker"""
    logger.info("create_intent_signal", artifact_id=str(payload.artifact_id))
    
    # Verify artifact exists and create signal
    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                "SELECT doc_id FROM documents WHERE doc_id = %s",
                (payload.artifact_id,),
            )
            artifact = cur.fetchone()
            if not artifact:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Artifact not found")
            
            # Generate signal_id from signal_data if not present
            signal_data = payload.signal_data
            signal_id_str = signal_data.get("signal_id")
            if not signal_id_str:
                # Generate a deterministic signal_id if not provided
                signal_id_str = str(uuid.uuid5(
                    uuid.NAMESPACE_URL,
                    f"intent:{payload.artifact_id}:{payload.taxonomy_version}:{orjson.dumps(signal_data, option=orjson.OPT_SORT_KEYS).decode()}"
                ))
            
            try:
                signal_id = uuid.UUID(signal_id_str)
            except ValueError:
                # If signal_id is not a valid UUID, generate one deterministically
                signal_id = uuid.uuid5(
                    uuid.NAMESPACE_URL,
                    f"intent:{payload.artifact_id}:{payload.taxonomy_version}:{signal_id_str}"
                )
            
            # Insert intent signal
            cur.execute(
                """
                INSERT INTO intent_signals (
                    signal_id,
                    artifact_id,
                    taxonomy_version,
                    parent_thread_id,
                    signal_data,
                    conflict,
                    conflicting_fields,
                    status
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (signal_id) DO UPDATE
                SET signal_data = EXCLUDED.signal_data,
                    conflict = EXCLUDED.conflict,
                    conflicting_fields = EXCLUDED.conflicting_fields,
                    updated_at = NOW()
                RETURNING *
                """,
                (
                    signal_id,
                    payload.artifact_id,
                    payload.taxonomy_version,
                    payload.parent_thread_id,
                    Json(signal_data),
                    payload.conflict,
                    payload.conflicting_fields if payload.conflicting_fields else [],
                    "pending",
                ),
            )
            signal_row = cur.fetchone()
            if not signal_row:
                raise HTTPException(
                    status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail="Failed to create intent signal",
                )
            
            # Update document intent_status to 'processed'
            cur.execute(
                """
                UPDATE documents
                SET intent_status = 'processed',
                    intent_processing_completed_at = NOW(),
                    intent_processing_error = NULL,
                    updated_at = NOW()
                WHERE doc_id = %s
                """,
                (payload.artifact_id,),
            )
            
            conn.commit()
    
    return IntentSignalResponse(
        signal_id=signal_row["signal_id"],
        artifact_id=signal_row["artifact_id"],
        taxonomy_version=signal_row["taxonomy_version"],
        parent_thread_id=signal_row["parent_thread_id"],
        signal_data=_coerce_json(signal_row["signal_data"]),
        status=signal_row["status"],
        user_feedback=_coerce_json(signal_row["user_feedback"]) if signal_row.get("user_feedback") else None,
        conflict=signal_row["conflict"],
        conflicting_fields=signal_row["conflicting_fields"] or [],
        created_at=signal_row["created_at"],
        updated_at=signal_row["updated_at"],
    )


@app.get(
    "/v1/catalog/intent-signals/{signal_id}",
    response_model=IntentSignalResponse,
)
def get_intent_signal(
    signal_id: str,
    _token: None = Depends(verify_token),
) -> IntentSignalResponse:
    """Retrieve an intent signal by ID"""
    try:
        signal_uuid = uuid.UUID(signal_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid signal_id") from exc
    
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT *
                FROM intent_signals
                WHERE signal_id = %s
                """,
                (signal_uuid,),
            )
            signal_row = cur.fetchone()
            if not signal_row:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Intent signal not found")
    
    return IntentSignalResponse(
        signal_id=signal_row["signal_id"],
        artifact_id=signal_row["artifact_id"],
        taxonomy_version=signal_row["taxonomy_version"],
        parent_thread_id=signal_row["parent_thread_id"],
        signal_data=_coerce_json(signal_row["signal_data"]),
        status=signal_row["status"],
        user_feedback=_coerce_json(signal_row["user_feedback"]) if signal_row.get("user_feedback") else None,
        conflict=signal_row["conflict"],
        conflicting_fields=signal_row["conflicting_fields"] or [],
        created_at=signal_row["created_at"],
        updated_at=signal_row["updated_at"],
    )


@app.patch(
    "/v1/catalog/intent-signals/{signal_id}/feedback",
    response_model=IntentSignalResponse,
)
def update_intent_signal_feedback(
    signal_id: str,
    payload: IntentSignalFeedbackRequest,
    _token: None = Depends(verify_token),
) -> IntentSignalResponse:
    """Update user feedback on an intent signal"""
    try:
        signal_uuid = uuid.UUID(signal_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid signal_id") from exc
    
    # Map action to status
    status_map = {
        "confirm": "confirmed",
        "edit": "edited",
        "reject": "rejected",
        "snooze": "snoozed",
    }
    new_status = status_map.get(payload.action)
    if not new_status:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid action: {payload.action}",
        )
    
    feedback_data = {
        "action": payload.action,
        "timestamp": datetime.now(tz=UTC).isoformat(),
    }
    if payload.corrected_slots:
        feedback_data["corrected_slots"] = payload.corrected_slots
    if payload.user_id:
        feedback_data["user_id"] = payload.user_id
    if payload.notes:
        feedback_data["notes"] = payload.notes
    
    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                UPDATE intent_signals
                SET status = %s,
                    user_feedback = %s,
                    updated_at = NOW()
                WHERE signal_id = %s
                RETURNING *
                """,
                (new_status, Json(feedback_data), signal_uuid),
            )
            signal_row = cur.fetchone()
            if not signal_row:
                conn.rollback()
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Intent signal not found")
            conn.commit()
    
    return IntentSignalResponse(
        signal_id=signal_row["signal_id"],
        artifact_id=signal_row["artifact_id"],
        taxonomy_version=signal_row["taxonomy_version"],
        parent_thread_id=signal_row["parent_thread_id"],
        signal_data=_coerce_json(signal_row["signal_data"]),
        status=signal_row["status"],
        user_feedback=_coerce_json(signal_row["user_feedback"]) if signal_row.get("user_feedback") else None,
        conflict=signal_row["conflict"],
        conflicting_fields=signal_row["conflicting_fields"] or [],
        created_at=signal_row["created_at"],
        updated_at=signal_row["updated_at"],
    )


@app.get(
    "/v1/catalog/documents/{doc_id}/intent-status",
    response_model=IntentStatusResponse,
)
def get_document_intent_status(
    doc_id: str,
    _token: None = Depends(verify_token),
) -> IntentStatusResponse:
    """Check intent processing status for a document"""
    try:
        doc_uuid = uuid.UUID(doc_id)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid doc_id") from exc
    
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT 
                    doc_id,
                    intent_status,
                    intent_processing_started_at,
                    intent_processing_completed_at,
                    intent_processing_error
                FROM documents
                WHERE doc_id = %s
                """,
                (doc_uuid,),
            )
            doc_row = cur.fetchone()
            if not doc_row:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Document not found")
    
    return IntentStatusResponse(
        doc_id=doc_row["doc_id"],
        intent_status=doc_row["intent_status"],
        intent_processing_started_at=doc_row["intent_processing_started_at"],
        intent_processing_completed_at=doc_row["intent_processing_completed_at"],
        intent_processing_error=doc_row["intent_processing_error"],
    )
