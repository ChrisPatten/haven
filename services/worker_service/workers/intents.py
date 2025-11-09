"""Intents worker for processing document intent signals."""
from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional
from uuid import UUID

import httpx
import orjson
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
from haven.intents.slots import SlotFiller, SlotFillerResult, SlotFillerSettings

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
    metadata: Dict[str, Any]
    people: List[Dict[str, Any]]
    thread_id: Optional[UUID] = None
    entities: Optional[Dict[str, Any]] = None

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
        self._slot_filler = SlotFiller(
            settings=SlotFillerSettings(
                ollama_base_url=self.intents_settings.ollama_base_url,
                slot_model=self.intents_settings.intent_model,
                request_timeout=self.intents_settings.request_timeout,
            )
        )
    
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
                 RETURNING d.doc_id,
                           d.artifact_id,
                           d.text,
                           d.source_type,
                           d.people,
                           d.metadata,
                           d.thread_id
                )
                SELECT u.doc_id,
                       u.artifact_id,
                       u.text,
                       u.source_type,
                       u.people,
                       u.metadata,
                       u.thread_id
                  FROM updated u
                """,
                {"limit": limit},
            )
            rows = cur.fetchall()
        
        for row in rows:
            metadata = self._coerce_json_dict(row.get("metadata")) or {}
            people = self._coerce_json_list(row.get("people")) or []
            entities = self._extract_entities(metadata)

            thread_id = row.get("thread_id")
            jobs.append(
                IntentsJob(
                    doc_id=UUID(str(row["doc_id"])),
                    artifact_id=UUID(str(row["artifact_id"])),
                    text=row.get("text") or "",
                    source_type=row.get("source_type") or "",
                    metadata=metadata,
                    people=people,
                    thread_id=UUID(str(thread_id)) if thread_id else None,
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

        thread_context = self._fetch_thread_context(job)
        slot_result = self._slot_filler.fill_slots(
            job_text=job.text,
            classification=classification,
            taxonomy=taxonomy,
            entity_payload=self._prepare_entity_payload(job),
            artifact_id=str(job.artifact_id),
            source_type=job.source_type,
            thread_context=thread_context,
        )
        self._log_slot_filling(job, slot_result)

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
                thread_context = self._fetch_thread_context(job)
                classification = classify_artifact(
                    text=job.text,
                    taxonomy=taxonomy,
                    entities=self._prepare_entity_payload(job),
                    thread_context=thread_context,
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

    def _log_slot_filling(self, job: IntentsJob, result: SlotFillerResult) -> None:
        assignments_summary = [
            {
                "intent": assignment.intent_name,
                "resolved_slots": assignment.slots,
                "missing_slots": assignment.missing_slots,
                "slot_sources": assignment.slot_sources,
            }
            for assignment in result.assignments
        ]
        self.logger.info(
            "intents_slots_filled",
            doc_id=str(job.doc_id),
            artifact_id=str(job.artifact_id),
            assignments=assignments_summary,
            extraction_notes=result.notes,
        )

    def _prepare_entity_payload(self, job: IntentsJob) -> Dict[str, Any]:
        """Augment raw entities with channel context for downstream processing."""
        entities = dict(job.entities or {})
        channel_context = self._build_channel_context(job)
        if channel_context:
            entities.setdefault("channel_context", {}).update(channel_context)
        return entities

    def _build_channel_context(self, job: IntentsJob) -> Dict[str, Any]:
        """Construct consistent channel context including from/to participants."""
        context: Dict[str, Any] = {
            "source_type": job.source_type or "unknown",
            "metadata": job.metadata or {},
        }
        participants = self._extract_participants(job.people)
        if participants["from"] is not None:
            context["from"] = participants["from"]
        if participants["to"]:
            context["to"] = participants["to"]
        if job.source_type in {"imessage", "email", "email_local"}:
            context.setdefault("from", self._fallback_sender(job.metadata))
            context.setdefault("to", self._fallback_recipients(job.metadata))
        return {key: value for key, value in context.items() if value not in (None, [], {})}

    def _extract_participants(self, people: List[Dict[str, Any]]) -> Dict[str, Any]:
        """Extract sender and recipient participants from document people payload."""
        sender_roles = {"sender", "from", "author", "owner"}
        recipient_roles = {"recipient", "to", "addressee", "participant"}
        sender: Optional[Dict[str, Any]] = None
        recipients: List[Dict[str, Any]] = []
        for person in people or []:
            role = str(person.get("role") or "").lower()
            normalized = self._normalize_person(person)
            if role in sender_roles and sender is None:
                sender = normalized
                continue
            if role in recipient_roles:
                recipients.append(normalized)
        return {"from": sender, "to": recipients}

    def _normalize_person(self, person: Dict[str, Any]) -> Dict[str, Any]:
        """Normalize person payload for LLM context."""
        normalized: Dict[str, Any] = {}
        if not person:
            return normalized
        display_name = person.get("display_name") or person.get("name")
        identifier = person.get("identifier")
        identifier_type = person.get("identifier_type")
        if display_name:
            normalized["display_name"] = display_name
        if identifier:
            normalized["identifier"] = identifier
        if identifier_type:
            normalized["identifier_type"] = identifier_type
        metadata = person.get("metadata")
        if isinstance(metadata, dict) and metadata:
            normalized["metadata"] = metadata
        return normalized

    def _fallback_sender(self, metadata: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Fallback sender extraction using document metadata."""
        channel_meta = self._coerce_json_dict(metadata.get("channel")) if metadata else None
        if not channel_meta:
            return None
        sender = channel_meta.get("sender") or channel_meta.get("from")
        if isinstance(sender, dict):
            return self._normalize_person(sender)
        if isinstance(sender, str) and sender.strip():
            return {"display_name": sender.strip()}
        return None

    def _fallback_recipients(self, metadata: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Fallback recipients extraction using document metadata."""
        channel_meta = self._coerce_json_dict(metadata.get("channel")) if metadata else None
        if not channel_meta:
            return []
        recipients = channel_meta.get("recipients") or channel_meta.get("to") or []
        normalized: List[Dict[str, Any]] = []
        if isinstance(recipients, dict):
            recipients = [recipients]
        if isinstance(recipients, list):
            for recipient in recipients:
                if isinstance(recipient, str) and recipient.strip():
                    normalized.append({"display_name": recipient.strip()})
                elif isinstance(recipient, dict):
                    normalized.append(self._normalize_person(recipient))
        return [recipient for recipient in normalized if recipient]

    def _extract_entities(self, metadata: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Extract entity payload from metadata if present."""
        if not metadata:
            return None
        entities = metadata.get("entities") or metadata.get("entity_set")
        if not entities:
            return None
        if isinstance(entities, (bytes, bytearray, memoryview)):
            return self._coerce_json_dict(entities)
        if isinstance(entities, dict):
            return entities
        return None

    def _coerce_json_dict(self, value: Any) -> Optional[Dict[str, Any]]:
        if value is None:
            return None
        if isinstance(value, dict):
            return value
        if isinstance(value, memoryview):
            return self._coerce_json_dict(value.tobytes())
        if isinstance(value, (bytes, bytearray)):
            try:
                return orjson.loads(value)
            except orjson.JSONDecodeError:
                return None
        return None

    def _coerce_json_list(self, value: Any) -> Optional[List[Dict[str, Any]]]:
        if value is None:
            return None
        if isinstance(value, list):
            return value
        if isinstance(value, memoryview):
            return self._coerce_json_list(value.tobytes())
        if isinstance(value, (bytes, bytearray)):
            try:
                decoded = orjson.loads(value)
            except orjson.JSONDecodeError:
                return None
            if isinstance(decoded, list):
                return decoded
        return None

    def _fetch_thread_context(self, job: IntentsJob) -> Optional[List[Dict[str, Any]]]:
        """Fetch recent messages from the same thread for conversational context.
        
        Returns up to 5 previous messages from the thread, ordered by timestamp.
        Each message includes text, sender, and timestamp for pronoun resolution.
        """
        if not job.thread_id:
            return None
        
        try:
            # Query recent documents from the same thread, excluding the current one
            with self.settings.get_db_connection() as conn:
                with conn.cursor(row_factory=dict_row) as cur:
                    cur.execute(
                        """
                        SELECT text, metadata, content_timestamp
                        FROM documents
                        WHERE thread_id = %s
                          AND doc_id != %s
                          AND text IS NOT NULL
                          AND text != ''
                        ORDER BY content_timestamp DESC
                        LIMIT 5
                        """,
                        (job.thread_id, job.doc_id),
                    )
                    rows = cur.fetchall()
            
            if not rows:
                return None
            
            context_messages = []
            for row in rows:
                msg_metadata = self._coerce_json_dict(row.get("metadata")) or {}
                channel_meta = self._coerce_json_dict(msg_metadata.get("channel")) or {}
                sender = channel_meta.get("sender") or channel_meta.get("from")
                
                context_messages.append({
                    "text": row.get("text") or "",
                    "sender": sender,
                    "timestamp": str(row.get("content_timestamp", "")),
                })
            
            # Reverse to chronological order (oldest first)
            return list(reversed(context_messages))
        except Exception as exc:
            self.logger.warning(
                "thread_context_fetch_failed",
                doc_id=str(job.doc_id),
                thread_id=str(job.thread_id),
                error=str(exc),
            )
            return None

