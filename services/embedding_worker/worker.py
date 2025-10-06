from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import List, Sequence

import psycopg
from pydantic import BaseModel, Field
from qdrant_client import QdrantClient
from qdrant_client.http import models as qm
from sentence_transformers import SentenceTransformer

from shared.db import get_conn_str
from shared.logging import get_logger, setup_logging

logger = get_logger("embedding.worker")


class WorkerSettings(BaseModel):
    database_url: str = Field(default_factory=get_conn_str)
    qdrant_url: str = Field(default_factory=lambda: os.getenv("QDRANT_URL", "http://qdrant:6333"))
    qdrant_collection: str = Field(default_factory=lambda: os.getenv("QDRANT_COLLECTION", "imessage_chunks"))
    embedding_model: str = Field(default_factory=lambda: os.getenv("EMBEDDING_MODEL", "BAAI/bge-m3"))
    embedding_dim: int = Field(default_factory=lambda: int(os.getenv("EMBEDDING_DIM", "1024")))
    poll_interval: float = Field(default_factory=lambda: float(os.getenv("WORKER_POLL_INTERVAL", "2.0")))
    batch_size: int = Field(default_factory=lambda: int(os.getenv("WORKER_BATCH_SIZE", "16")))


settings = WorkerSettings()


def ensure_collection(client: QdrantClient) -> None:
    try:
        client.get_collection(settings.qdrant_collection)
        return
    except Exception:
        logger.info("creating_qdrant_collection", collection=settings.qdrant_collection)

    client.create_collection(
        collection_name=settings.qdrant_collection,
        vectors_config=qm.VectorParams(size=settings.embedding_dim, distance=qm.Distance.COSINE),
    )


@dataclass
class PendingChunk:
    chunk_id: str
    doc_id: str
    text: str


def fetch_pending_chunks(conn: psycopg.Connection) -> List[PendingChunk]:
    pending: List[PendingChunk] = []
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT c.id::text, c.doc_id, c.text
            FROM embed_index_state e
            JOIN chunks c ON c.id = e.chunk_id
            WHERE e.status = 'pending'
            ORDER BY e.updated_at ASC
            LIMIT %s
            """,
            (settings.batch_size,),
        )
        for row in cur.fetchall():
            pending.append(PendingChunk(chunk_id=row[0], doc_id=row[1], text=row[2]))

        for chunk in pending:
            cur.execute(
                """
                UPDATE embed_index_state
                SET status = 'processing', updated_at = NOW(), last_error = NULL
                WHERE chunk_id = %s
                """,
                (chunk.chunk_id,),
            )
    conn.commit()
    return pending


def mark_chunks_ready(conn: psycopg.Connection, chunk_ids: Sequence[str]) -> None:
    with conn.cursor() as cur:
        for chunk_id in chunk_ids:
            cur.execute(
                """
                UPDATE embed_index_state
                SET status = 'ready', updated_at = NOW()
                WHERE chunk_id = %s
                """,
                (chunk_id,),
            )
    conn.commit()


def mark_chunks_failed(conn: psycopg.Connection, chunk_ids: Sequence[str], error: str) -> None:
    with conn.cursor() as cur:
        for chunk_id in chunk_ids:
            cur.execute(
                """
                UPDATE embed_index_state
                SET status = 'error', updated_at = NOW(), last_error = %s
                WHERE chunk_id = %s
                """,
                (error[:512], chunk_id),
            )
    conn.commit()


def run_worker() -> None:
    setup_logging()
    logger.info("starting_embedding_worker", model=settings.embedding_model)

    model = SentenceTransformer(settings.embedding_model)
    client = QdrantClient(url=settings.qdrant_url)
    ensure_collection(client)

    while True:
        try:
            with psycopg.connect(settings.database_url) as conn:
                conn.autocommit = False
                chunks = fetch_pending_chunks(conn)
                if not chunks:
                    time.sleep(settings.poll_interval)
                    continue

                texts = [chunk.text for chunk in chunks]
                embeddings = model.encode(texts, normalize_embeddings=True)

                payloads = []
                for chunk in chunks:
                    payloads.append({"doc_id": chunk.doc_id})

                client.upsert(
                    collection_name=settings.qdrant_collection,
                    points=qm.Batch(
                        ids=[chunk.chunk_id for chunk in chunks],
                        vectors=embeddings.tolist(),
                        payloads=payloads,
                    ),
                )

                mark_chunks_ready(conn, [chunk.chunk_id for chunk in chunks])
                logger.info("embedded_chunks", count=len(chunks))
        except Exception as exc:  # pragma: no cover
            logger.error("worker_error", error=str(exc))
            if 'chunks' in locals() and chunks:
                with psycopg.connect(settings.database_url) as conn:
                    conn.autocommit = False
                    mark_chunks_failed(conn, [chunk.chunk_id for chunk in chunks], str(exc))
            time.sleep(settings.poll_interval)


if __name__ == "__main__":
    run_worker()

