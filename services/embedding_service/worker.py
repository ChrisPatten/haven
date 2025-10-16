from __future__ import annotations

import os
import socket
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import httpx
import psycopg
from psycopg.rows import dict_row
from pydantic import BaseModel, Field

from shared.db import get_conn_str
from shared.logging import get_logger, setup_logging

logger = get_logger("embedding.service")


class WorkerSettings(BaseModel):
    database_url: str = Field(default_factory=get_conn_str)
    catalog_base_url: str = Field(default_factory=lambda: os.getenv("CATALOG_BASE_URL", "http://catalog:8081"))
    catalog_token: Optional[str] = Field(default_factory=lambda: os.getenv("CATALOG_TOKEN"))
    ollama_base_url: str = Field(default_factory=lambda: os.getenv("OLLAMA_BASE_URL", "http://localhost:11434"))
    embedding_model: str = Field(default_factory=lambda: os.getenv("EMBEDDING_MODEL", "bge-m3"))
    poll_interval: float = Field(default_factory=lambda: float(os.getenv("WORKER_POLL_INTERVAL", "2.0")))
    batch_size: int = Field(default_factory=lambda: int(os.getenv("WORKER_BATCH_SIZE", "8")))
    request_timeout: float = Field(default_factory=lambda: float(os.getenv("EMBEDDING_REQUEST_TIMEOUT", "15.0")))


settings = WorkerSettings()


@dataclass
class PendingJob:
    chunk_id: str
    doc_ids: List[str]
    text: str


class EmbeddingError(Exception):
    """Marker for embedding failures that should trigger retries."""


def _worker_id() -> str:
    hostname = socket.gethostname()
    pid = os.getpid()
    return f"{hostname}:{pid}"


def dequeue_jobs(conn: psycopg.Connection, limit: int) -> List[PendingJob]:
    jobs: List[PendingJob] = []
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            WITH candidates AS (
                SELECT chunk_id
                  FROM chunks
                 WHERE embedding_status = 'pending'
                 ORDER BY created_at ASC
                 FOR UPDATE SKIP LOCKED
                 LIMIT %(limit)s
            ),
            updated AS (
                UPDATE chunks c
                   SET embedding_status = 'processing',
                       updated_at = NOW()
                 WHERE c.chunk_id IN (SELECT chunk_id FROM candidates)
             RETURNING c.chunk_id, c.text
            )
            SELECT u.chunk_id, u.text, cd.doc_id
              FROM updated u
              LEFT JOIN chunk_documents cd ON cd.chunk_id = u.chunk_id
            """,
            {"limit": limit},
        )
        rows = cur.fetchall()

    chunk_map: Dict[str, Dict[str, Any]] = {}
    for row in rows:
        chunk_id = str(row["chunk_id"])
        record = chunk_map.setdefault(chunk_id, {"text": row["text"], "doc_ids": []})
        doc_id = row.get("doc_id")
        if doc_id:
            record.setdefault("doc_ids", []).append(str(doc_id))

    for chunk_id, payload in chunk_map.items():
        text = payload.get("text") or ""
        if not text.strip():
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE chunks
                       SET embedding_status = 'embedded',
                           embedding_model = NULL,
                           embedding_vector = NULL,
                           updated_at = NOW()
                     WHERE chunk_id = %s
                    """,
                    (chunk_id,),
                )
            continue
        jobs.append(
            PendingJob(
                chunk_id=chunk_id,
                doc_ids=list({*payload.get("doc_ids", [])}),
                text=text,
            )
        )

    conn.commit()
    return jobs


def mark_job_failed(conn: psycopg.Connection, job: PendingJob, error_message: str) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE chunks
               SET embedding_status = 'failed',
                   embedding_model = NULL,
                   updated_at = NOW()
             WHERE chunk_id = %s
            """,
            (job.chunk_id,),
        )
    conn.commit()


def request_embedding(client: httpx.Client, text: str) -> List[float]:
    response = client.post(
        "/api/embeddings",
        json={"model": settings.embedding_model, "prompt": text},
    )
    response.raise_for_status()
    data = response.json()
    vector = data.get("embedding")
    if not isinstance(vector, list):
        raise EmbeddingError("Embedding response missing 'embedding' list")
    return vector


def submit_embedding(client: httpx.Client, chunk_id: str, vector: List[float]) -> None:
    headers: dict[str, str] = {}
    if settings.catalog_token:
        headers["Authorization"] = f"Bearer {settings.catalog_token}"
    headers["X-Correlation-ID"] = f"embed_{chunk_id}"
    payload = {
        "chunk_id": chunk_id,
        "vector": vector,
        "model": settings.embedding_model,
        "dimensions": len(vector),
    }
    response = client.post("/v1/catalog/embeddings", json=payload, headers=headers)
    response.raise_for_status()


def run_worker() -> None:
    setup_logging()
    worker_id = _worker_id()
    logger.info(
        "embedding_service_start",
        worker_id=worker_id,
        catalog_base=settings.catalog_base_url,
        model=settings.embedding_model,
        poll_interval=settings.poll_interval,
        batch_size=settings.batch_size,
    )

    while True:
        jobs: List[PendingJob] = []
        try:
            with psycopg.connect(settings.database_url) as conn:
                conn.autocommit = False
                jobs = dequeue_jobs(conn, settings.batch_size)
        except Exception as exc:  # pragma: no cover - defensive logging
            logger.error("embedding_job_dequeue_failed", error=str(exc))
            time.sleep(settings.poll_interval)
            continue

        if not jobs:
            time.sleep(settings.poll_interval)
            continue

        with httpx.Client(
            base_url=settings.ollama_base_url, timeout=settings.request_timeout
        ) as ollama_client, httpx.Client(
            base_url=settings.catalog_base_url, timeout=settings.request_timeout
        ) as catalog_client:
            for job in jobs:
                try:
                    vector = request_embedding(ollama_client, job.text)
                    submit_embedding(catalog_client, job.chunk_id, vector)
                    primary_doc = job.doc_ids[0] if job.doc_ids else None
                    logger.info("embedding_job_completed", chunk_id=job.chunk_id, doc_id=primary_doc)
                except Exception as exc:  # pragma: no cover - error path
                    logger.error(
                        "embedding_job_failed",
                        chunk_id=job.chunk_id,
                        doc_ids=job.doc_ids,
                        error=str(exc),
                    )
                    try:
                        with psycopg.connect(settings.database_url) as conn:
                            conn.autocommit = False
                            mark_job_failed(conn, job, str(exc))
                    except Exception as db_exc:  # pragma: no cover
                        logger.error(
                            "embedding_job_failure_mark_failed",
                            chunk_id=job.chunk_id,
                            doc_ids=job.doc_ids,
                            error=str(db_exc),
                        )
                        # last resort: sleep briefly to avoid hot loop
                        time.sleep(1.0)
        # small pause to avoid immediate tight loop between batches
        time.sleep(0.01)


if __name__ == "__main__":
    run_worker()
