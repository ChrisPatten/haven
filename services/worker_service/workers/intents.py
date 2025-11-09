"""Intents worker for processing document intent signals."""
from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import List
from uuid import UUID

import httpx
import psycopg
from psycopg.rows import dict_row
from pydantic import BaseModel, Field

from haven.intents.classifier.classifier import (
    ClassificationError,
    ClassifierSettings,
    classify_artifact,
)
from haven.intents.classifier.priors import PriorConfig, apply_channel_priors
from haven.intents.classifier.taxonomy import IntentTaxonomy, TaxonomyLoader, get_loader
from haven.intents.models import ClassificationResult

from shared.logging import get_logger

from services.worker_service.base import BaseWorker, WorkerSettings

UTC = timezone.utc
DEFAULT_TAXONOMY_PATH = (
    Path(__file__).resolve().parent.parent / "taxonomies" / "taxonomy_v1.0.0.yaml"
)


def _default_taxonomy_path() -> str:
    override = os.getenv("TAXONOMY_PATH")
    if override:
        return override
    return str(DEFAULT_TAXONOMY_PATH)


class IntentsWorkerSettings(WorkerSettings):
    """Settings specific to intents worker."""
    ollama_base_url: str = Field(default_factory=lambda: os.getenv("OLLAMA_BASE_URL", "http://localhost:11434"))
    intent_model: str = Field(default_factory=lambda: os.getenv("INTENT_MODEL", "llama3.2"))
    request_timeout: float = Field(default_factory=lambda: float(os.getenv("INTENT_REQUEST_TIMEOUT", "15.0")))
    taxonomy_path: str = Field(default_factory=_default_taxonomy_path)
    min_confidence: float = Field(default_factory=lambda: float(os.getenv("INTENT_MIN_CONFIDENCE", "0.5")))


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
        self._taxonomy_loader: TaxonomyLoader = get_loader(self.intents_settings.taxonomy_path)
        self._prior_config = PriorConfig()
    
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
        
        TODO: Phase 2.1 - Remaining steps after classification:
        1. Fill slots from entities
        2. Generate evidence
        3. Check deduplication
        4. Validate signals
        5. Persist signals via Catalog API
        """
        self.logger.info(
            "intents_job_processing",
            doc_id=str(job.doc_id),
            artifact_id=str(job.artifact_id),
            source_type=job.source_type,
        )

        taxonomy = self._load_taxonomy()
        classification = self._run_classification(job=job, taxonomy=taxonomy)
        filtered_intents = [
            intent
            for intent in classification.intents
            if intent.confidence >= self.intents_settings.min_confidence
        ]
        classification = classification.copy(update={"intents": filtered_intents})
        self._log_classification(job, classification)

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

    def _load_taxonomy(self) -> IntentTaxonomy:
        try:
            return self._taxonomy_loader.load()
        except Exception as exc:  # pragma: no cover - defensive
            raise RuntimeError(f"failed to load taxonomy: {exc}") from exc

    def _run_classification(
        self, *, job: IntentsJob, taxonomy: IntentTaxonomy
    ) -> ClassificationResult:
        classifier_settings = ClassifierSettings(
            base_url=self.intents_settings.ollama_base_url,
            model=self.intents_settings.intent_model,
            timeout=self.intents_settings.request_timeout,
            min_confidence=self.intents_settings.min_confidence,
        )

        with httpx.Client(
            base_url=self.intents_settings.ollama_base_url,
            timeout=self.intents_settings.request_timeout,
        ) as ollama_client:
            try:
                classification = classify_artifact(
                    text=job.text,
                    taxonomy=taxonomy,
                    entities=job.entities,
                    settings=classifier_settings,
                    client=ollama_client,
                )
            except ClassificationError as exc:
                raise RuntimeError(f"classification failed: {exc}") from exc

        adjusted_intents = apply_channel_priors(
            channel=job.source_type or "",
            candidates=classification.intents,
            taxonomy=taxonomy,
            config=self._prior_config,
        )
        return classification.copy(update={"intents": adjusted_intents})

    def _log_classification(self, job: IntentsJob, result: ClassificationResult) -> None:
        summary = [
            {"intent": intent.intent_name, "confidence": intent.confidence}
            for intent in result.intents
        ]
        self.logger.info(
            "intents_job_classified",
            doc_id=str(job.doc_id),
            artifact_id=str(job.artifact_id),
            source_type=job.source_type,
            taxonomy_version=result.taxonomy_version,
            intents=summary,
            notes=result.processing_notes,
        )

