from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any, Dict, List, Optional
from uuid import UUID

from pydantic import BaseModel, Field


class Document(BaseModel):
    doc_id: UUID
    external_id: str
    source_type: str
    source_provider: Optional[str] = None
    version_number: int = 1
    previous_version_id: Optional[UUID] = None
    is_active_version: bool = True
    superseded_at: Optional[datetime] = None
    superseded_by_id: Optional[UUID] = None
    title: Optional[str] = None
    text: str
    text_sha256: str
    mime_type: Optional[str] = None
    canonical_uri: Optional[str] = None
    content_timestamp: datetime
    content_timestamp_type: str
    content_created_at: Optional[datetime] = None
    content_modified_at: Optional[datetime] = None
    people: List[Dict[str, Any]] = Field(default_factory=list)
    thread_id: Optional[UUID] = None
    parent_doc_id: Optional[UUID] = None
    source_doc_ids: List[UUID] = Field(default_factory=list)
    related_doc_ids: List[UUID] = Field(default_factory=list)
    has_attachments: bool = False
    attachment_count: int = 0
    has_location: bool = False
    has_due_date: bool = False
    due_date: Optional[datetime] = None
    is_completed: Optional[bool] = None
    completed_at: Optional[datetime] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)
    status: str = "submitted"
    extraction_failed: bool = False
    enrichment_failed: bool = False
    error_details: Optional[Dict[str, Any]] = None
    ingested_at: datetime
    created_at: datetime
    updated_at: datetime


class Thread(BaseModel):
    thread_id: UUID
    external_id: str
    source_type: str
    source_provider: Optional[str] = None
    title: Optional[str] = None
    participants: List[Dict[str, Any]] = Field(default_factory=list)
    thread_type: Optional[str] = None
    is_group: Optional[bool] = None
    participant_count: Optional[int] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)
    first_message_at: Optional[datetime] = None
    last_message_at: Optional[datetime] = None
    created_at: datetime
    updated_at: datetime


class File(BaseModel):
    file_id: UUID
    content_sha256: str
    object_key: str
    storage_backend: str
    filename: Optional[str] = None
    mime_type: Optional[str] = None
    size_bytes: Optional[int] = None
    enrichment_status: str
    enrichment: Optional[Dict[str, Any]] = None
    first_seen_at: datetime
    last_enriched_at: Optional[datetime] = None
    created_at: datetime
    updated_at: datetime


class DocumentFile(BaseModel):
    doc_id: UUID
    file_id: UUID
    role: str
    attachment_index: Optional[int] = None
    filename: Optional[str] = None
    caption: Optional[str] = None
    created_at: datetime


class Chunk(BaseModel):
    chunk_id: UUID
    text: str
    text_sha256: str
    ordinal: int
    source_ref: Optional[Dict[str, Any]] = None
    embedding_status: str
    embedding_model: Optional[str] = None
    embedding_vector: Optional[List[float]] = None
    created_at: datetime
    updated_at: datetime


class ChunkDocument(BaseModel):
    chunk_id: UUID
    doc_id: UUID
    ordinal: Optional[int] = None
    weight: Optional[Decimal] = None
    created_at: datetime


class IngestSubmission(BaseModel):
    submission_id: UUID
    idempotency_key: str
    source_type: str
    source_id: str
    content_sha256: str
    status: str
    result_doc_id: Optional[UUID] = None
    error_details: Optional[Dict[str, Any]] = None
    created_at: datetime
    updated_at: datetime
