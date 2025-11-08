"""Intents worker for processing document intent signals."""
from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import List
from uuid import UUID

import httpx
import psycopg
from psycopg.rows import dict_row
from pydantic import BaseModel, Field

from shared.logging import get_logger

from services.worker_service.base import BaseWorker, WorkerSettings

UTC = timezone.utc


class IntentsWorkerSettings(WorkerSettings):
    """Settings specific to intents worker."""
    ollama_base_url: str = Field(default_factory=lambda: os.getenv("OLLAMA_BASE_URL", "http://localhost:11434"))
    intent_model: str = Field(default_factory=lambda: os.getenv("INTENT_MODEL", "llama3.2"))
    request_timeout: float = Field(default_factory=lambda: float(os.getenv("INTENT_REQUEST_TIMEOUT", "15.0")))
    taxonomy_path: str | None = Field(default_factory=lambda: os.getenv("TAXONOMY_PATH"))


@dataclass
class IntentsJob:
    """Intents job data."""
    doc_id: UUID
    artifact_id: UUID
    text: str
    source_type: str
    entities: dict | None = None
    
    def __str__(self) -> str:
        return f"IntentsJob(doc_id={self.doc_id}, artifact_id={self.artifact_id})"


class IntentsWorker(BaseWorker[IntentsJob]):
    """Worker for processing intent classification jobs.
    
    Phase 2.1 Implementation:
    - Polls documents with intent_status = 'pending'
    - Classifies intents using LLM
    - Fills slots from pre-processed entities
    - Generates evidence
    - Persists signals to intent_signals table
    """
    
    def __init__(self, settings: IntentsWorkerSettings | None = None):
        if settings is None:
            settings = IntentsWorkerSettings()
        super().__init__(settings)
        self.intents_settings = settings
        self.logger = get_logger("worker.intents")
    
    def worker_type(self) -> str:
        return "intents"
    
    def dequeue_jobs(self, conn: psycopg.Connection, limit: int) -> List[IntentsJob]:
        """Dequeue intent processing jobs from documents table."""
        jobs: List[IntentsJob] = []
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                WITH candidates AS (
                    SELECT doc_id
                      FROM documents
                     WHERE intent_status = 'pending'
                     ORDER BY created_at ASC
                     FOR UPDATE SKIP LOCKED
                     LIMIT %(limit)s
                ),
                updated AS (
                    UPDATE documents d
                       SET intent_status = 'processing',
                           intent_processing_started_at = NOW(),
                           updated_at = NOW()
                     WHERE d.doc_id IN (SELECT doc_id FROM candidates)
                 RETURNING d.doc_id, d.artifact_id, d.text, d.source_type, d.people
                )
                SELECT u.doc_id, u.artifact_id, u.text, u.source_type, u.people
                  FROM updated u
                """,
                {"limit": limit},
            )
            rows = cur.fetchall()
        
        for row in rows:
            # Extract entities from people field (pre-processed entities)
            entities = None
            if row.get("people"):
                # people field contains entity data from client-side NER
                entities = row["people"]
            
            jobs.append(
                IntentsJob(
                    doc_id=UUID(str(row["doc_id"])),
                    artifact_id=UUID(str(row["artifact_id"])),
                    text=row.get("text") or "",
                    source_type=row.get("source_type") or "",
                    entities=entities,
                )
            )
        
        conn.commit()
        return jobs
    
    def process_job(self, job: IntentsJob) -> None:
        """Process a single intent classification job.
        
        TODO: Phase 2.1 - Implement full processing pipeline:
        1. Load taxonomy
        2. Classify intents using LLM
        3. Fill slots from entities
        4. Generate evidence
        5. Check deduplication
        6. Validate signals
        7. Persist signals via Catalog API
        """
        self.logger.info(
            "intents_job_processing",
            doc_id=str(job.doc_id),
            artifact_id=str(job.artifact_id),
            source_type=job.source_type,
        )
        
        # TODO: Implement intent classification
        # TODO: Implement slot filling
        # TODO: Implement evidence generation
        # TODO: Implement deduplication check
        # TODO: Implement signal validation
        # TODO: Persist signals via Catalog API
        
        # Placeholder: Mark as processed for now
        # In full implementation, this will be done after signal persistence
        with httpx.Client(
            base_url=self.settings.catalog_base_url,
            timeout=self.intents_settings.request_timeout
        ) as catalog_client:
            # For now, just mark as processed
            # TODO: Replace with actual signal persistence
            self._mark_document_processed(catalog_client, job.doc_id)
    
    def mark_job_failed(self, conn: psycopg.Connection, job: IntentsJob, error_message: str) -> None:
        """Mark an intent processing job as failed."""
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE documents
                   SET intent_status = 'failed',
                       intent_processing_completed_at = NOW(),
                       intent_processing_error = %s,
                       updated_at = NOW()
                 WHERE doc_id = %s
                """,
                (error_message[:1000], job.doc_id),  # Limit error message length
            )
        conn.commit()
    
    def _mark_document_processed(self, client: httpx.Client, doc_id: UUID) -> None:
        """Mark document as processed (placeholder until full implementation).
        
        TODO: Replace with actual signal persistence via Catalog API endpoint.
        For now, this is a placeholder that will be replaced when signal
        persistence is implemented.
        """
        # In full implementation, this will be done after signal persistence
        # via the Catalog API endpoint POST /v1/catalog/intent-signals
        self.logger.info("intents_job_completed", doc_id=str(doc_id))

