"""Embedding worker for vectorizing document chunks."""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Dict, List

import httpx
import psycopg
from psycopg.rows import dict_row
from pydantic import BaseModel, Field

from shared.logging import get_logger

from services.worker_service.base import BaseWorker, WorkerSettings


class EmbeddingWorkerSettings(WorkerSettings):
    """Settings specific to embedding worker."""
    ollama_base_url: str = Field(default_factory=lambda: os.getenv("OLLAMA_BASE_URL", "http://localhost:11434"))
    embedding_model: str = Field(default_factory=lambda: os.getenv("EMBEDDING_MODEL", "bge-m3"))
    request_timeout: float = Field(default_factory=lambda: float(os.getenv("EMBEDDING_REQUEST_TIMEOUT", "15.0")))


@dataclass
class EmbeddingJob:
    """Embedding job data."""
    chunk_id: str
    doc_ids: List[str]
    text: str
    
    def __str__(self) -> str:
        return f"EmbeddingJob(chunk_id={self.chunk_id})"


class EmbeddingError(Exception):
    """Marker for embedding failures that should trigger retries."""


class EmbeddingWorker(BaseWorker[EmbeddingJob]):
    """Worker for processing embedding jobs."""
    
    def __init__(self, settings: EmbeddingWorkerSettings | None = None):
        if settings is None:
            settings = EmbeddingWorkerSettings()
        super().__init__(settings)
        self.embedding_settings = settings
        self.logger = get_logger("worker.embedding")
    
    def worker_type(self) -> str:
        return "embedding"
    
    def dequeue_jobs(self, conn: psycopg.Connection, limit: int) -> List[EmbeddingJob]:
        """Dequeue embedding jobs from chunks table."""
        jobs: List[EmbeddingJob] = []
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
                EmbeddingJob(
                    chunk_id=chunk_id,
                    doc_ids=list({*payload.get("doc_ids", [])}),
                    text=text,
                )
            )

        conn.commit()
        return jobs
    
    def process_job(self, job: EmbeddingJob) -> None:
        """Process a single embedding job."""
        with httpx.Client(
            base_url=self.embedding_settings.ollama_base_url,
            timeout=self.embedding_settings.request_timeout
        ) as ollama_client, httpx.Client(
            base_url=self.settings.catalog_base_url,
            timeout=self.embedding_settings.request_timeout
        ) as catalog_client:
            vector = self._request_embedding(ollama_client, job.text)
            self._submit_embedding(catalog_client, job.chunk_id, vector)
            primary_doc = job.doc_ids[0] if job.doc_ids else None
            self.logger.info("embedding_job_completed", chunk_id=job.chunk_id, doc_id=primary_doc)
    
    def mark_job_failed(self, conn: psycopg.Connection, job: EmbeddingJob, error_message: str) -> None:
        """Mark an embedding job as failed."""
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
    
    def _request_embedding(self, client: httpx.Client, text: str) -> List[float]:
        """Request embedding from Ollama."""
        response = client.post(
            "/api/embeddings",
            json={"model": self.embedding_settings.embedding_model, "prompt": text},
        )
        response.raise_for_status()
        data = response.json()
        vector = data.get("embedding")
        if not isinstance(vector, list):
            raise EmbeddingError("Embedding response missing 'embedding' list")
        return vector
    
    def _submit_embedding(self, client: httpx.Client, chunk_id: str, vector: List[float]) -> None:
        """Submit embedding to catalog API."""
        headers: dict[str, str] = {}
        if self.settings.catalog_token:
            headers["Authorization"] = f"Bearer {self.settings.catalog_token}"
        headers["X-Correlation-ID"] = f"embed_{chunk_id}"
        payload = {
            "chunk_id": chunk_id,
            "vector": vector,
            "model": self.embedding_settings.embedding_model,
            "dimensions": len(vector),
        }
        response = client.post("/v1/catalog/embeddings", json=payload, headers=headers)
        response.raise_for_status()

