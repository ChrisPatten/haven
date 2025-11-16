from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional, Literal
from uuid import UUID

from pydantic import BaseModel, Field, validator

class PersonPayload(BaseModel):
    identifier: str
    identifier_type: Optional[str] = None
    role: Optional[str] = None
    display_name: Optional[str] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)


class ThreadPayload(BaseModel):
    external_id: str
    source_type: Optional[str] = None
    source_provider: Optional[str] = None
    source_account_id: Optional[str] = None
    title: Optional[str] = None
    participants: List[PersonPayload] = Field(default_factory=list)
    thread_type: Optional[str] = None
    is_group: Optional[bool] = None
    participant_count: Optional[int] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)
    first_message_at: Optional[datetime] = None
    last_message_at: Optional[datetime] = None


class FileDescriptor(BaseModel):
    content_sha256: str
    object_key: str
    storage_backend: Optional[str] = None
    filename: Optional[str] = None
    mime_type: Optional[str] = None
    size_bytes: Optional[int] = None
    enrichment_status: Optional[str] = None
    enrichment: Optional[Dict[str, Any]] = None


class AttachmentSourceRef(BaseModel):
    path: Optional[str] = None
    message_attachment_id: Optional[int] = None
    page: Optional[int] = None


class AttachmentOCR(BaseModel):
    text: str
    confidence: Optional[float] = None
    language: Optional[str] = None
    regions: Optional[List[Dict[str, Any]]] = Field(default_factory=list)


class AttachmentCaption(BaseModel):
    text: str
    model: Optional[str] = None
    confidence: Optional[float] = None
    generated_at: Optional[datetime] = None


class AttachmentVision(BaseModel):
    faces: Optional[List[Dict[str, Any]]] = Field(default_factory=list)
    objects: Optional[List[Dict[str, Any]]] = Field(default_factory=list)
    scene: Optional[str] = None


class AttachmentEXIF(BaseModel):
    camera: Optional[str] = None
    taken_at: Optional[datetime] = None
    location: Optional[Dict[str, float]] = None
    width: Optional[int] = None
    height: Optional[int] = None


class DocumentFileLink(BaseModel):
    index: int
    kind: str  # e.g. "image" | "pdf" | "file" | "other"
    role: Literal["attachment", "inline", "thumbnail", "related"] = "attachment"
    mime_type: str
    size_bytes: Optional[int] = None
    source_ref: Optional[AttachmentSourceRef] = None
    ocr: Optional[AttachmentOCR] = None
    caption: Optional[AttachmentCaption] = None
    vision: Optional[AttachmentVision] = None
    exif: Optional[AttachmentEXIF] = None


class DocumentIngestRequest(BaseModel):
    idempotency_key: str
    source_type: str
    source_provider: Optional[str] = None
    source_account_id: Optional[str] = None
    source_id: str
    content_sha256: str
    external_id: Optional[str] = None
    title: Optional[str] = None
    text: str
    mime_type: Optional[str] = "text/plain"
    canonical_uri: Optional[str] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)
    content_timestamp: datetime
    content_timestamp_type: str
    people: List[PersonPayload] = Field(default_factory=list)
    thread_id: Optional[UUID] = None
    thread: Optional[ThreadPayload] = None
    parent_doc_id: Optional[UUID] = None
    source_doc_ids: List[UUID] = Field(default_factory=list)
    related_doc_ids: List[UUID] = Field(default_factory=list)
    has_location: Optional[bool] = None
    has_due_date: Optional[bool] = None
    due_date: Optional[datetime] = None
    is_completed: Optional[bool] = None
    completed_at: Optional[datetime] = None
    attachments: List[DocumentFileLink] = Field(default_factory=list)
    facet_overrides: Dict[str, Any] = Field(default_factory=dict)
    intent: Optional[Dict[str, Any]] = None

    @validator("content_timestamp_type")
    def normalize_timestamp_type(cls, value: str) -> str:
        return value.lower()


class DocumentIngestResponse(BaseModel):
    submission_id: UUID
    doc_id: UUID
    external_id: str
    version_number: int
    thread_id: Optional[UUID] = None
    status: str
    duplicate: bool = False


class DocumentBatchIngestRequest(BaseModel):
    documents: List[DocumentIngestRequest] = Field(default_factory=list)
    batch_idempotency_key: Optional[str] = None

    @validator("documents")
    def ensure_documents(cls, documents: List[DocumentIngestRequest]) -> List[DocumentIngestRequest]:
        if not documents:
            raise ValueError("Batch must include at least one document")
        return documents


class DocumentBatchIngestError(BaseModel):
    code: str
    message: str
    details: Dict[str, Any] = Field(default_factory=dict)


class DocumentBatchIngestItem(BaseModel):
    index: int
    status_code: int
    document: Optional[DocumentIngestResponse] = None
    error: Optional[DocumentBatchIngestError] = None


class DocumentBatchIngestResponse(BaseModel):
    batch_id: UUID
    batch_status: str
    total_count: int
    success_count: int
    failure_count: int
    results: List[DocumentBatchIngestItem] = Field(default_factory=list)


class PersonIngestResponse(BaseModel):
    person_id: UUID
    external_id: str
    version: int
    status: str = "upserted"
    deleted: bool = False


class DocumentVersionRequest(BaseModel):
    text: Optional[str] = None
    title: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None
    content_timestamp: Optional[datetime] = None
    content_timestamp_type: Optional[str] = None
    people: Optional[List[PersonPayload]] = None
    thread_id: Optional[UUID] = None
    has_location: Optional[bool] = None
    has_due_date: Optional[bool] = None
    due_date: Optional[datetime] = None
    is_completed: Optional[bool] = None
    completed_at: Optional[datetime] = None
    attachments: Optional[List[DocumentFileLink]] = None
    metadata_overrides: Optional[Dict[str, Any]] = None

    @validator("content_timestamp_type")
    def normalize_timestamp_type(cls, value: Optional[str]) -> Optional[str]:
        return value.lower() if value else value


class DocumentVersionResponse(BaseModel):
    doc_id: UUID
    previous_version_id: UUID
    external_id: str
    version_number: int
    thread_id: Optional[UUID] = None
    status: str


class SubmissionStatusResponse(BaseModel):
    submission_id: UUID
    status: str
    doc_id: Optional[UUID] = None
    document_status: Optional[str] = None
    total_chunks: int = 0
    embedded_chunks: int = 0
    pending_chunks: int = 0
    error: Optional[Dict[str, Any]] = None


class DocumentStatusResponse(BaseModel):
    doc_id: UUID
    status: str
    total_chunks: int = 0
    embedded_chunks: int = 0
    pending_chunks: int = 0


class EmbeddingSubmitRequest(BaseModel):
    chunk_id: UUID
    vector: List[float]
    model: str
    dimensions: int


class EmbeddingSubmitResponse(BaseModel):
    chunk_id: UUID
    status: str


class DeleteDocumentResponse(BaseModel):
    doc_id: UUID
    status: str


# ============================================================================
# INTENT SIGNALS MODELS
# ============================================================================

class TextSpan(BaseModel):
    """Text span evidence for intent signals"""
    start_offset: int
    end_offset: int
    preview: str


class LayoutRef(BaseModel):
    """Layout reference for OCR/document evidence"""
    attachment_id: Optional[str] = None
    page: Optional[int] = None
    block_id: Optional[str] = None
    line_id: Optional[str] = None


class EntityRef(BaseModel):
    """Reference to an entity used in slot filling"""
    type: str
    index: int


class Evidence(BaseModel):
    """Evidence supporting the intent and slots"""
    text_spans: List[TextSpan] = Field(default_factory=list)
    layout_refs: List[LayoutRef] = Field(default_factory=list)
    entity_refs: List[EntityRef] = Field(default_factory=list)


class IntentResult(BaseModel):
    """Single intent with slots and evidence"""
    name: str
    confidence: float
    slots: Dict[str, Any] = Field(default_factory=dict)
    missing_slots: List[str] = Field(default_factory=list)
    follow_up_needed: bool = False
    follow_up_reason: Optional[str] = None
    evidence: Evidence


class ProcessingTimestamps(BaseModel):
    """Timing information for intent processing"""
    ner_started_at: Optional[datetime] = None
    ner_completed_at: Optional[datetime] = None
    received_at: datetime
    intent_started_at: datetime
    intent_completed_at: datetime
    emitted_at: datetime


class Provenance(BaseModel):
    """Processing provenance for intent signals"""
    ner_version: str
    ner_framework: str
    classifier_version: str
    slot_filler_version: str
    config_snapshot_id: str
    processing_location: Literal["client", "server", "hybrid"]


class IntentSignalData(BaseModel):
    """Complete Intent Signal schema (stored in signal_data JSONB)"""
    signal_id: str
    artifact_id: str
    taxonomy_version: str
    intents: List[IntentResult] = Field(default_factory=list)
    global_confidence: Optional[float] = None
    processing_notes: List[str] = Field(default_factory=list)
    processing_timestamps: ProcessingTimestamps
    provenance: Provenance
    parent_thread_id: Optional[str] = None
    conflict: bool = False
    conflicting_fields: List[str] = Field(default_factory=list)


class IntentSignalCreateRequest(BaseModel):
    """Request to create an intent signal"""
    artifact_id: UUID
    taxonomy_version: str
    signal_data: Dict[str, Any]  # IntentSignalData as dict
    parent_thread_id: Optional[UUID] = None
    conflict: bool = False
    conflicting_fields: List[str] = Field(default_factory=list)


class IntentSignalResponse(BaseModel):
    """Response for intent signal queries"""
    signal_id: UUID
    artifact_id: UUID
    taxonomy_version: str
    parent_thread_id: Optional[UUID] = None
    signal_data: Dict[str, Any]
    status: str
    user_feedback: Optional[Dict[str, Any]] = None
    conflict: bool
    conflicting_fields: List[str] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime


class IntentSignalFeedbackRequest(BaseModel):
    """Request to update user feedback on an intent signal"""
    action: Literal["confirm", "edit", "reject", "snooze"]
    corrected_slots: Optional[Dict[str, Any]] = None
    user_id: Optional[str] = None
    notes: Optional[str] = None


class IntentStatusResponse(BaseModel):
    """Response for document intent processing status"""
    doc_id: UUID
    intent_status: str
    intent_processing_started_at: Optional[datetime] = None
    intent_processing_completed_at: Optional[datetime] = None
    intent_processing_error: Optional[str] = None
