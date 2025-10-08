from __future__ import annotations

import json
from typing import Any, Iterable, List

import psycopg
from psycopg import AsyncConnection

from ..config import get_settings
from ..db import run_in_transaction
from ..pipeline.types import PreparedDocument


class PostgresDocumentRepository:
    """Postgres-backed implementation for document persistence."""

    def __init__(self) -> None:
        self._settings = get_settings()

    async def upsert_documents(self, org_id: str, documents: Iterable[PreparedDocument]) -> list[str]:
        prepared = list(documents)
        if not prepared:
            return []

        stored_ids: list[str] = []

        async def _execute(conn: AsyncConnection[Any]) -> None:
            async with conn.cursor() as cur:
                for item in prepared:
                    doc = item.document
                    if doc.idempotency_key:
                        await cur.execute(
                            """
                            SELECT 1 FROM search_ingest_log
                            WHERE org_id = %s AND idempotency_key = %s
                            """,
                            (org_id, doc.idempotency_key),
                        )
                        existing = await cur.fetchone()
                        if existing:
                            continue
                    await cur.execute(
                        """
                        INSERT INTO search_documents (
                            document_id, org_id, source_id, title, url, mime_type, author,
                            created_at, updated_at, metadata, facets, tags, acl, raw_text,
                            chunk_count, embedding_model
                        ) VALUES (
                            %(document_id)s, %(org_id)s, %(source_id)s, %(title)s, %(url)s,
                            %(mime_type)s, %(author)s, %(created_at)s, %(updated_at)s,
                            %(metadata)s, %(facets)s, %(tags)s, %(acl)s, %(raw_text)s,
                            %(chunk_count)s, %(embedding_model)s
                        )
                        ON CONFLICT (document_id)
                        DO UPDATE SET
                            source_id = EXCLUDED.source_id,
                            title = EXCLUDED.title,
                            url = EXCLUDED.url,
                            mime_type = EXCLUDED.mime_type,
                            author = EXCLUDED.author,
                            created_at = EXCLUDED.created_at,
                            updated_at = EXCLUDED.updated_at,
                            metadata = EXCLUDED.metadata,
                            facets = EXCLUDED.facets,
                            tags = EXCLUDED.tags,
                            acl = EXCLUDED.acl,
                            raw_text = EXCLUDED.raw_text,
                            chunk_count = EXCLUDED.chunk_count,
                            embedding_model = EXCLUDED.embedding_model,
                            updated_at_system = NOW()
                        """,
                        {
                            "document_id": doc.document_id,
                            "org_id": org_id,
                            "source_id": doc.source_id,
                            "title": doc.title,
                            "url": doc.url,
                            "mime_type": doc.mime_type,
                            "author": doc.author,
                            "created_at": doc.created_at,
                            "updated_at": doc.updated_at,
                            "metadata": json.dumps(doc.metadata),
                            "facets": json.dumps([facet.model_dump() for facet in doc.facets]),
                            "tags": doc.tags,
                            "acl": json.dumps(doc.acl.model_dump()),
                            "raw_text": doc.text.encode("utf-8") if doc.text else None,
                            "chunk_count": len(item.chunks),
                            "embedding_model": self._settings.embedding_model,
                        },
                    )
                    stored_ids.append(doc.document_id)

                    await cur.execute(
                        "DELETE FROM search_chunks WHERE document_id = %s",
                        (doc.document_id,),
                    )

                    for idx, chunk in enumerate(item.chunks):
                        chunk_id = chunk.id or f"{doc.document_id}:{idx}"
                        await cur.execute(
                            """
                            INSERT INTO search_chunks (
                                chunk_id, document_id, org_id, chunk_index, text, metadata, facets, embedding_status
                            ) VALUES (%(chunk_id)s, %(document_id)s, %(org_id)s, %(chunk_index)s, %(text)s,
                                      %(metadata)s, %(facets)s, %(embedding_status)s)
                            ON CONFLICT (chunk_id)
                            DO UPDATE SET
                                document_id = EXCLUDED.document_id,
                                org_id = EXCLUDED.org_id,
                                chunk_index = EXCLUDED.chunk_index,
                                text = EXCLUDED.text,
                                metadata = EXCLUDED.metadata,
                                facets = EXCLUDED.facets,
                                embedding_status = 'pending',
                                embedding_error = NULL,
                                created_at = NOW()
                            """,
                            {
                                "chunk_id": chunk_id,
                                "document_id": doc.document_id,
                                "org_id": org_id,
                                "chunk_index": idx,
                                "text": chunk.text,
                                "metadata": json.dumps(chunk.meta),
                                "facets": json.dumps([facet.model_dump() for facet in doc.facets]),
                                "embedding_status": "pending",
                            },
                        )

                    if doc.idempotency_key:
                        await cur.execute(
                            """
                            INSERT INTO search_ingest_log (org_id, idempotency_key, document_id, status)
                            VALUES (%s, %s, %s, %s)
                            ON CONFLICT (org_id, idempotency_key) DO NOTHING
                            """,
                            (org_id, doc.idempotency_key, doc.document_id, "stored"),
                        )
        await run_in_transaction(_execute)
        return stored_ids

    async def delete_documents(self, org_id: str, selector: dict[str, object]) -> int:
        doc_ids: List[str] = selector.get("doc_ids", [])  # type: ignore[assignment]
        source_ids: List[str] = selector.get("source_ids", [])  # type: ignore[assignment]

        async def _execute(conn: AsyncConnection[Any]) -> int:
            query = "DELETE FROM search_documents WHERE org_id = %s"
            params: List[object] = [org_id]
            if doc_ids:
                query += " AND document_id = ANY(%s)"
                params.append(doc_ids)
            if source_ids:
                query += " AND source_id = ANY(%s)"
                params.append(source_ids)
            async with conn.cursor() as cur:
                await cur.execute(query, params)
                deleted = cur.rowcount or 0
                await cur.execute(
                    """
                    INSERT INTO search_deletes (org_id, selector, deleted_count)
                    VALUES (%s, %s::jsonb, %s)
                    """,
                    (org_id, json.dumps(selector), deleted),
                )
                return deleted

        return await run_in_transaction(_execute)


__all__ = ["PostgresDocumentRepository"]
