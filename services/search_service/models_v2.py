from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Literal, Optional
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


# Conversational Search Models (matching OpenAPI spec)

class FacetRange(BaseModel):
    start: str
    end: str
    start_inclusive: bool = True
    end_inclusive: bool = True


class FacetFilter(BaseModel):
    name: str
    type: Literal["term", "range", "boolean"]
    values: List[str] = Field(default_factory=list)
    range: Optional[FacetRange] = None
    exclude: bool = False


class FacetValue(BaseModel):
    value: str
    display_name: str = ""
    count: int
    selected: bool = False
    metadata: Dict[str, Any] = Field(default_factory=dict)


class Facet(BaseModel):
    name: str
    display_name: str = ""
    type: Literal["term", "range", "boolean"]
    values: List[FacetValue] = Field(default_factory=list)
    selected_values: List[str] = Field(default_factory=list)
    range: Optional[FacetRange] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)


class SearchConverseRequest(BaseModel):
    question: str = Field(..., min_length=1)
    conversation_id: Optional[str] = None
    top_k: int = Field(default=5, ge=1, le=20)
    facet_filters: List[FacetFilter] = Field(default_factory=list)


class SearchConverseResponse(BaseModel):
    query: str
    conversation_id: str
    answer: str
    confidence: float = Field(default=0.0, ge=0.0, le=1.0)
    documents: List[Any] = Field(default_factory=list)  # Will be SearchHit from haven.search
    document_count: int
    facets: List[Facet] = Field(default_factory=list)
    inferred_filters: List[FacetFilter] = Field(default_factory=list)
    metadata: Dict[str, Any] = Field(default_factory=dict)


class SearchFacetsRequest(BaseModel):
    question: str = Field(..., min_length=1)
    conversation_id: Optional[str] = None
    facet_filters: List[FacetFilter] = Field(default_factory=list)
    facet_limit: int = Field(default=5, ge=1, le=10)


class SearchFacetsResponse(BaseModel):
    query: str
    conversation_id: str
    document_count: int
    facets: List[Facet] = Field(default_factory=list)
    metadata: Dict[str, Any] = Field(default_factory=dict)


# Internal models for search planning

class SearchPlan(BaseModel):
    """Internal model for LLM-generated search plan."""
    keyword_query: str  # Keywords for lexical search
    similarity_query: str  # Query for semantic/vector search
    facet_filters: List[FacetFilter] = Field(default_factory=list)
    retrieval_strategy: str = "hybrid"  # "lexical", "vector", "hybrid"
    summarization_intent: str = "summary"  # "summary", "list", "comparison"


class ConversationState(BaseModel):
    """In-memory conversation state."""
    conversation_id: str
    latest_filters: List[FacetFilter] = Field(default_factory=list)
    conversation_metadata: Dict[str, Any] = Field(default_factory=dict)
    created_at: datetime
    updated_at: datetime


__all__ = [
    "SearchDocument",
    "SearchPerson",
    "SearchChunk",
    "FacetRange",
    "FacetFilter",
    "FacetValue",
    "Facet",
    "SearchConverseRequest",
    "SearchConverseResponse",
    "SearchFacetsRequest",
    "SearchFacetsResponse",
    "SearchPlan",
    "ConversationState",
]
