from __future__ import annotations

import contextlib
import os
from typing import Any, Dict, Iterator, Optional
from uuid import UUID, uuid4

try:
    import psycopg
    from psycopg.rows import dict_row
    from psycopg.types.json import Json
except ImportError:  # pragma: no cover - optional guard for tests
    psycopg = None  # type: ignore[assignment]
    dict_row = None  # type: ignore[assignment]
    Json = None  # type: ignore[assignment]

from .models_v2 import Document, DocumentFile


DEFAULT_CONN_STR = "postgresql://postgres:postgres@localhost:5432/haven"


def get_conn_str() -> str:
    return os.getenv("DATABASE_URL", DEFAULT_CONN_STR)


@contextlib.contextmanager
def get_connection(autocommit: bool = True) -> Iterator[psycopg.Connection]:
    if psycopg is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    conn = psycopg.connect(get_conn_str())
    conn.autocommit = autocommit
    try:
        yield conn
    finally:
        conn.close()


@contextlib.contextmanager
def get_cursor(autocommit: bool = True) -> Iterator[psycopg.Cursor]:
    if psycopg is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    with get_connection(autocommit=autocommit) as conn:
        with conn.cursor() as cur:
            yield cur


def _json(value: Any) -> Any:
    if value is None or Json is None:
        return value
    return Json(value)


def _document_from_row(row: Dict[str, Any]) -> Document:
    return Document(**row)


def _document_file_from_row(row: Dict[str, Any]) -> DocumentFile:
    return DocumentFile(**row)


def get_active_document(external_id: str) -> Optional[Document]:
    """Return the active (latest) document version for the given external ID."""
    if psycopg is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT *
                FROM documents
                WHERE external_id = %s
                ORDER BY is_active_version DESC, version_number DESC
                LIMIT 1
                """,
                (external_id,),
            )
            row = cur.fetchone()
            if not row or not row.get("is_active_version"):
                return None
            return _document_from_row(row)


def create_document_version(doc_id: UUID, changes: Dict[str, Any]) -> Document:
    """Create a new document version derived from the existing document."""
    if psycopg is None or dict_row is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")

    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                "SELECT * FROM documents WHERE doc_id = %s FOR UPDATE",
                (doc_id,),
            )
            current = cur.fetchone()
            if current is None:
                conn.rollback()
                raise ValueError(f"Document not found for doc_id={doc_id}")

            new_doc_id = uuid4()
            merged: Dict[str, Any] = dict(current)
            merged.update(changes)

            # Ensure defaults for required structured fields.
            merged["people"] = merged.get("people") or []
            merged["metadata"] = merged.get("metadata") or {}
            merged["source_doc_ids"] = merged.get("source_doc_ids") or []
            merged["related_doc_ids"] = merged.get("related_doc_ids") or []
            merged["error_details"] = merged.get("error_details")
            merged["has_attachments"] = merged.get("has_attachments", False)
            merged["attachment_count"] = merged.get("attachment_count", 0)
            merged["has_location"] = merged.get("has_location", False)
            merged["has_due_date"] = merged.get("has_due_date", False)
            merged["extraction_failed"] = merged.get("extraction_failed", False)
            merged["enrichment_failed"] = merged.get("enrichment_failed", False)
            merged["status"] = merged.get("status", current.get("status", "submitted"))

            # Set version metadata.
            merged["doc_id"] = new_doc_id
            merged["version_number"] = int(current.get("version_number", 1)) + 1
            merged["previous_version_id"] = current["doc_id"]
            merged["is_active_version"] = True
            merged.pop("superseded_at", None)
            merged.pop("superseded_by_id", None)
            merged.pop("created_at", None)
            merged.pop("updated_at", None)
            merged.pop("ingested_at", None)

            # Ensure required immutable values remain consistent.
            merged["external_id"] = current["external_id"]
            merged["source_type"] = current["source_type"]
            if merged.get("source_provider") is None:
                merged["source_provider"] = current.get("source_provider")
            merged["thread_id"] = merged.get("thread_id", current.get("thread_id"))

            # Persist changes.
            cur.execute(
                """
                UPDATE documents
                SET is_active_version = false,
                    superseded_at = NOW(),
                    superseded_by_id = %s,
                    updated_at = NOW()
                WHERE doc_id = %s
                """,
                (new_doc_id, doc_id),
            )

            columns = list(merged.keys())
            placeholders = ", ".join(["%s"] * len(columns))
            values = [
                _json(merged[col]) if col in {"people", "metadata", "error_details"} else merged[col]
                for col in columns
            ]

            cur.execute(
                f"""
                INSERT INTO documents ({', '.join(columns)})
                VALUES ({placeholders})
                RETURNING *
                """,
                values,
            )
            new_row = cur.fetchone()
        conn.commit()
    return _document_from_row(new_row)


def link_document_to_thread(doc_id: UUID, thread_id: UUID) -> Document:
    """Assign a document to a thread and return the updated document."""
    if psycopg is None or dict_row is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                UPDATE documents
                SET thread_id = %s,
                    updated_at = NOW()
                WHERE doc_id = %s
                RETURNING *
                """,
                (thread_id, doc_id),
            )
            row = cur.fetchone()
            if row is None:
                conn.rollback()
                raise ValueError(f"Document not found for doc_id={doc_id}")
        conn.commit()
    return _document_from_row(row)


def link_document_to_file(
    doc_id: UUID,
    file_id: UUID,
    role: str,
    *,
    attachment_index: Optional[int] = None,
    filename: Optional[str] = None,
    caption: Optional[str] = None,
) -> DocumentFile:
    """Link a document to a file with the provided role."""
    if psycopg is None or dict_row is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    with get_connection(autocommit=False) as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                INSERT INTO document_files (doc_id, file_id, role, attachment_index, filename, caption)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (doc_id, file_id, role) DO UPDATE
                SET attachment_index = COALESCE(EXCLUDED.attachment_index, document_files.attachment_index),
                    filename = COALESCE(EXCLUDED.filename, document_files.filename),
                    caption = COALESCE(EXCLUDED.caption, document_files.caption)
                RETURNING *
                """,
                (doc_id, file_id, role, attachment_index, filename, caption),
            )
            row = cur.fetchone()
        conn.commit()
    return _document_file_from_row(row)
