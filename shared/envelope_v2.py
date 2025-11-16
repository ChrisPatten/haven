from __future__ import annotations

from datetime import datetime
from hashlib import sha256
from typing import Any, Dict, List, Optional, Literal

from pydantic import BaseModel, Field, model_validator


class EnvelopeSource(BaseModel):
    source_type: str
    source_provider: Optional[str] = None
    source_account_id: Optional[str] = None


class PersonReference(BaseModel):
    identifier: str
    identifier_type: str
    role: Optional[str] = None
    display_name: Optional[str] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)


class ThreadHint(BaseModel):
    external_id: Optional[str] = None
    thread_type: Optional[str] = None
    is_group: Optional[bool] = None
    title: Optional[str] = None
    participants: List[PersonReference] = Field(default_factory=list)
    metadata: Dict[str, Any] = Field(default_factory=dict)


class DocumentRelationships(BaseModel):
    thread_id: Optional[str] = None
    parent_doc_id: Optional[str] = None
    source_doc_ids: List[str] = Field(default_factory=list)
    related_doc_ids: List[str] = Field(default_factory=list)


class DocumentFacets(BaseModel):
    has_attachments: Optional[bool] = None
    attachment_count: Optional[int] = None
    has_location: Optional[bool] = None
    has_due_date: Optional[bool] = None
    due_date: Optional[datetime] = None
    is_completed: Optional[bool] = None
    completed_at: Optional[datetime] = None


class DocumentPayload(BaseModel):
    external_id: str
    version_number: int = 1
    title: Optional[str] = None
    text: str
    text_sha256: Optional[str] = None
    mime_type: Optional[str] = "text/plain"
    canonical_uri: Optional[str] = None
    content_timestamp: datetime
    content_timestamp_type: str
    content_created_at: Optional[datetime] = None
    content_modified_at: Optional[datetime] = None
    people: List[PersonReference] = Field(default_factory=list)
    thread: Optional[ThreadHint] = None
    relationships: DocumentRelationships = Field(default_factory=DocumentRelationships)
    facets: DocumentFacets = Field(default_factory=DocumentFacets)
    metadata: Dict[str, Any] = Field(default_factory=dict)
    intent: Optional[Dict[str, Any]] = None

    model_config = {"extra": "allow"}

    def ensure_text_hash(self) -> None:
        if not self.text_sha256:
            self.text_sha256 = sha256(self.text.encode("utf-8")).hexdigest()


class PersonIdentifier(BaseModel):
    kind: str
    value_raw: str
    value_canonical: Optional[str] = None
    label: Optional[str] = None
    priority: Optional[int] = None
    verified: Optional[bool] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)


class PersonPayload(BaseModel):
    external_id: str
    display_name: str
    given_name: Optional[str] = None
    family_name: Optional[str] = None
    organization: Optional[str] = None
    nicknames: List[str] = Field(default_factory=list)
    notes: Optional[str] = None
    photo_hash: Optional[str] = None
    change_token: Optional[str] = None
    version: int = 1
    deleted: bool = False
    identifiers: List[PersonIdentifier] = Field(default_factory=list)

    model_config = {"extra": "allow"}


class DocumentEnvelope(BaseModel):
    schema_version: str
    kind: Literal["document"]
    source: EnvelopeSource
    payload: DocumentPayload

    @model_validator(mode="after")
    def _compute_text_hash(self) -> "DocumentEnvelope":
        self.payload.ensure_text_hash()
        return self


class PersonEnvelope(BaseModel):
    schema_version: str
    kind: Literal["person"]
    source: EnvelopeSource
    payload: PersonPayload


def is_v2_schema(schema_version: str) -> bool:
    return schema_version.startswith("2.")
