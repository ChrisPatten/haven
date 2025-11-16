from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional
from uuid import UUID

from pydantic import BaseModel, Field


class SearchPerson(BaseModel):
    identifier: str
    identifier_type: Optional[str] = None
    role: Optional[str] = None
    display_name: Optional[str] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)


class SearchDocument(BaseModel):
    doc_id: UUID
    external_id: str
    source_type: str
    source_provider: Optional[str] = None
    title: Optional[str] = None
    canonical_uri: Optional[str] = None
    mime_type: Optional[str] = None
    content_timestamp: datetime
    content_timestamp_type: str
    people: List[SearchPerson] = Field(default_factory=list)
    has_attachments: bool = False
    attachment_count: int = 0
    has_location: bool = False
    has_due_date: bool = False
    due_date: Optional[datetime] = None
    is_completed: Optional[bool] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)
    thread_id: Optional[UUID] = None

    @classmethod
    def from_record(cls, record: Dict[str, Any]) -> "SearchDocument":
        people_raw = record.get("people") or []
        people = [SearchPerson(**person) for person in people_raw if isinstance(person, dict)]
        metadata = record.get("metadata") or {}
        return cls(
            doc_id=record["doc_id"],
            external_id=record["external_id"],
            source_type=record["source_type"],
            source_provider=record.get("source_provider"),
            title=record.get("title"),
            canonical_uri=record.get("canonical_uri"),
            mime_type=record.get("mime_type"),
            content_timestamp=record["content_timestamp"],
            content_timestamp_type=record["content_timestamp_type"],
            people=people,
            has_attachments=bool(record.get("has_attachments")),
            attachment_count=int(record.get("attachment_count") or 0),
            has_location=bool(record.get("has_location")),
            has_due_date=bool(record.get("has_due_date")),
            due_date=record.get("due_date"),
            is_completed=record.get("is_completed"),
            metadata=metadata,
            thread_id=record.get("thread_id"),
        )


class SearchChunk(BaseModel):
    chunk_id: UUID
    text: str


__all__ = ["SearchDocument", "SearchPerson", "SearchChunk"]
