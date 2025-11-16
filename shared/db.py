from __future__ import annotations

import contextlib
import os
from typing import Any, Dict, Iterator, Optional, List, Tuple
from uuid import UUID, uuid4
from datetime import timedelta

try:
    import psycopg
    from psycopg.rows import dict_row
    from psycopg.types.json import Json
except ImportError:  # pragma: no cover - optional guard for tests
    psycopg = None  # type: ignore[assignment]
    dict_row = None  # type: ignore[assignment]
    Json = None  # type: ignore[assignment]

from .models_v2 import Document, DocumentFile, Person


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

def _person_and_role_from_row(row: Dict[str, Any]) -> Tuple[Person, str]:
    person_role = row.pop("role")
    return Person(**row), person_role

def _person_from_row(row: Dict[str, Any]) -> Person:
    return Person(**row)

def get_document_by_id(doc_id: UUID) -> Optional[Document]:
    """Return the document with the given ID."""
    if psycopg is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT * FROM documents WHERE doc_id = %s", (doc_id,))
            row = cur.fetchone()
            return _document_from_row(row) if row else None

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

def get_person_by_id(person_id: UUID) -> Optional[Person]:
    """Return the person with the given ID."""
    if psycopg is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT * FROM people WHERE person_id = %s", (person_id,))
            row = cur.fetchone()
            return _person_from_row(row) if row else None

def resolve_people_from_document(document: Document) -> List[Tuple[Person, str]]:
    """Resolve the people from the document."""
    if psycopg is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute("""
            SELECT p.*, dp.role FROM people p
            JOIN document_people dp ON p.person_id = dp.person_id
            WHERE dp.doc_id = %s
            """, (document.doc_id,))
            rows = cur.fetchall()
            return [_person_and_role_from_row(row) for row in rows]

def resolve_people_from_identifiers(identifiers: List[str]) -> Dict[str, Tuple[Person, str]]:
    """Resolve a batch of people from their canonical identifiers.
    
    Args:
        identifiers: List of canonical person identifiers (e.g., email addresses, phone numbers)
    
    Returns:
        Dictionary mapping identifier -> (Person object, identifier_value)
    """
    if psycopg is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    
    if not identifiers:
        return {}
    
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            # Query people by their canonical identifiers
            placeholders = ", ".join(["%s"] * len(identifiers))
            cur.execute(f"""
            SELECT p.*, pi.value_canonical
            FROM people p
            JOIN person_identifiers pi ON p.person_id = pi.person_id
            WHERE pi.value_canonical = ANY(ARRAY[{placeholders}])
            """, identifiers)
            rows = cur.fetchall()
            
            # Map identifier -> (Person, identifier_value)
            result = {}
            for row in rows:
                identifier_value = row.pop("value_canonical")
                person = _person_from_row(row)
                result[identifier_value] = (person, identifier_value)
            return result

def get_thread_messages_from_document(document: Document, limit: int = 10, time_window: timedelta = timedelta(days=1)) -> List[Document]:
    """Return the thread messages for the document."""
    if psycopg is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute("""
WITH doc_thread AS (
    SELECT doc_id, thread_id, content_timestamp
    FROM documents
    WHERE doc_id = %s::uuid
)
SELECT d.*
FROM documents d
JOIN doc_thread ON d.thread_id = doc_thread.thread_id
WHERE d.content_timestamp < doc_thread.content_timestamp
  --AND d.content_timestamp > (doc_thread.content_timestamp - INTERVAL '8 hours')
  AND d.is_active_version = true
ORDER BY content_timestamp DESC
LIMIT %s
            """, (document.doc_id, limit))
            rows = cur.fetchall()
            return [_document_from_row(row) for row in rows]

def get_self_person_data() -> Optional[Tuple[Person, Dict[str, str]]]:
    """Get the self person's data and all their identifiers.
    
    Queries system_settings for self_person_id, then fetches the person and
    all their identifiers (email, phone, etc.) in a single optimized query.
    
    Returns:
        Tuple of (Person, identifiers_dict) where identifiers_dict maps
        canonical_identifier -> kind (e.g., {'user@example.com': 'email', '+1234567890': 'phone'})
        or None if self_person_id not set
    """
    if psycopg is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            # Single optimized query: fetch person data and all identifiers
            cur.execute(
                """
                SELECT 
                    p.*,
                    pi.value_canonical,
                    pi.kind
                FROM people p
                LEFT JOIN person_identifiers pi ON p.person_id = pi.person_id
                WHERE p.person_id = (
                    SELECT CAST(value->>'self_person_id' AS UUID)
                    FROM system_settings
                    WHERE key = 'self_person_id'
                )
                """
            )
            rows = cur.fetchall()
            
            if not rows or not rows[0]:
                return None
            
            # First row contains the person data (will be same across all rows due to LEFT JOIN)
            first_row = rows[0]
            
            # Extract person data (remove identifier-specific columns)
            person_data = {k: v for k, v in first_row.items() 
                          if k not in ('value_canonical', 'kind')}
            person = _person_from_row(person_data)
            
            # Build identifiers dict from all rows: canonical_value -> kind
            identifiers = {}
            for row in rows:
                if row.get("value_canonical") and row.get("kind"):
                    identifiers[row["value_canonical"]] = row["kind"]
            
            return (person, identifiers)


def get_batch_thread_documents(as_of: datetime, lookback_minutes: int = 60) -> List[Tuple[str, str, datetime, datetime, str, List[Dict[str, Any]], Dict[str, Any], str]]:
    """Query documents within a lookback window for batch intent classification.
    
    Returns list of tuples: (doc_id, external_id, content_timestamp, ingested_at, text, people, metadata, source_type)
    
    Args:
        as_of: Query for documents with content_timestamp before this datetime
        lookback_minutes: How far back to look for active threads (by content_timestamp)
    """
    if psycopg is None:  # pragma: no cover
        raise RuntimeError("psycopg is not installed; install haven-platform[common]")
    
    lookback_cutoff = as_of - timedelta(minutes=lookback_minutes)
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            query = """
            WITH recent_threads AS (
                SELECT DISTINCT thread_id
                FROM documents
                WHERE content_timestamp <= %s
                    AND content_timestamp > %s
                    AND is_active_version = true
                    AND thread_id IS NOT NULL
            )
            SELECT 
                d.doc_id,
                t.external_id,
                d.content_timestamp,
                d.ingested_at,
                d.text,
                d.people,
                d.metadata,
                d.source_type
            FROM documents d
            JOIN recent_threads rt ON d.thread_id = rt.thread_id
            JOIN threads t ON d.thread_id = t.thread_id
            WHERE d.is_active_version = true
                AND d.content_timestamp <= %s
            ORDER BY t.external_id, d.content_timestamp ASC
            """
            
            cur.execute(query, (as_of, lookback_cutoff, as_of))
            rows = cur.fetchall()
            return rows