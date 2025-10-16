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


class DocumentFileLink(BaseModel):
    role: Literal["attachment", "extracted_from", "thumbnail", "preview", "related"] = "attachment"
    attachment_index: Optional[int] = None
    filename: Optional[str] = None
    caption: Optional[str] = None
    file: FileDescriptor


class DocumentIngestRequest(BaseModel):
    idempotency_key: str
    source_type: str
    source_provider: Optional[str] = None
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
    content_created_at: Optional[datetime] = None
    content_modified_at: Optional[datetime] = None
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

    @validator("content_timestamp_type")
    def normalize_timestamp_type(cls, value: str) -> str:
        return value.lower()


class DocumentIngestResponse(BaseModel):
    submission_id: UUID
    doc_id: UUID
    external_id: str
    version_number: int
    thread_id: Optional[UUID] = None
    file_ids: List[UUID] = Field(default_factory=list)
    status: str
    duplicate: bool = False


class DocumentVersionRequest(BaseModel):
    text: Optional[str] = None
    title: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None
    content_timestamp: Optional[datetime] = None
    content_timestamp_type: Optional[str] = None
    content_modified_at: Optional[datetime] = None
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
    file_ids: List[UUID] = Field(default_factory=list)
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
