from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, Field, HttpUrl, field_validator


class Facet(BaseModel):
    """Facet value captured during ingestion or search response decoration."""

    key: str
    value: str
    confidence: float | None = None


class Acl(BaseModel):
    """Represents tenant access control constraints for a document."""

    org_id: str
    allow_users: List[str] = Field(default_factory=list)
    allow_groups: List[str] = Field(default_factory=list)
    classification: str | None = None


class ChunkInput(BaseModel):
    """Optional client-provided chunk payload used for direct ingestion."""

    id: str | None = None
    text: str
    meta: Dict[str, Any] = Field(default_factory=dict)


class DocumentUpsert(BaseModel):
    """Public ingestion contract accepted by /v1/ingest/documents:batchUpsert."""

    document_id: str
    source_id: str
    title: str | None = None
    url: HttpUrl | None = None
    mime_type: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    author: str | None = None
    text: str | None = None
    chunks: List[ChunkInput] | None = None
    facets: List[Facet] = Field(default_factory=list)
    tags: List[str] = Field(default_factory=list)
    metadata: Dict[str, Any] = Field(default_factory=dict)
    acl: Acl
    idempotency_key: str | None = Field(default=None, description="Client supplied key for dedupe")

    @field_validator("chunks")
    @classmethod
    def ensure_chunks_or_text(
        cls, value: Optional[List[ChunkInput]], info: Field
    ) -> Optional[List[ChunkInput]]:
        if value is None:
            return value
        if not value:
            raise ValueError("chunks must be omitted or contain at least one entry")
        return value


class DeleteSelector(BaseModel):
    """Filters applied to delete operations."""

    doc_ids: List[str] = Field(default_factory=list)
    source_ids: List[str] = Field(default_factory=list)
    query: str | None = None

    def is_empty(self) -> bool:
        return not (self.doc_ids or self.source_ids or self.query)


class SearchVectorQuery(BaseModel):
    text: str | None = None
    doc_id: str | None = None
    weight: float = 1.0


class SearchKeywordQuery(BaseModel):
    weight: float = 1.0
    operator: Literal["AND", "OR"] = "OR"


class RangeFilter(BaseModel):
    field: str
    gte: datetime | float | None = None
    lte: datetime | float | None = None


class QueryFilter(BaseModel):
    term: str | None = None
    value: str | None = None
    range: RangeFilter | None = None


class Grouping(BaseModel):
    field: str


class PageCursor(BaseModel):
    cursor: str | None = None
    size: int = Field(default=20, ge=1, le=200)


class RerankSpec(BaseModel):
    top_k: int = Field(default=50, ge=1, le=200)
    model: str = "cross-encoder/ms-marco"


class IncludeSpec(BaseModel):
    snippets: bool = True
    highlights: bool = True
    explain: bool = False


class SearchRequest(BaseModel):
    query: str | None = None
    must: List[QueryFilter] = Field(default_factory=list)
    filter: List[QueryFilter] = Field(default_factory=list)
    facets: List[str] = Field(default_factory=list)
    vector: SearchVectorQuery | None = None
    keyword: SearchKeywordQuery | None = None
    rerank: RerankSpec | None = None
    group_by: Grouping | None = None
    page: PageCursor = Field(default_factory=PageCursor)
    include: IncludeSpec = Field(default_factory=IncludeSpec)


class SearchHit(BaseModel):
    document_id: str
    chunk_id: str | None = None
    title: str | None = None
    url: str | None = None
    snippet: str | None = None
    highlights: List[str] = Field(default_factory=list)
    score: float
    facets: List[Facet] = Field(default_factory=list)
    metadata: Dict[str, Any] = Field(default_factory=dict)
    sources: List[str] = Field(default_factory=list)


class SearchResult(BaseModel):
    total_estimated: int
    cursor: str | None
    hits: List[SearchHit]
    facet_counts: Dict[str, Dict[str, int]] = Field(default_factory=dict)


class IndexStatus(BaseModel):
    collection: str
    version: str
    health: Literal["green", "yellow", "red"] = "green"
    document_count: int = 0
    chunk_count: int = 0
    vector_count: int = 0


class ExtractResponse(BaseModel):
    document_id: str
    chunks: List[ChunkInput]
    facets: List[Facet]
    metadata: Dict[str, Any]


__all__ = [
    "Acl",
    "ChunkInput",
    "DeleteSelector",
    "DocumentUpsert",
    "ExtractResponse",
    "Facet",
    "Grouping",
    "IncludeSpec",
    "IndexStatus",
    "PageCursor",
    "QueryFilter",
    "RangeFilter",
    "RerankSpec",
    "SearchHit",
    "SearchKeywordQuery",
    "SearchRequest",
    "SearchResult",
    "SearchVectorQuery",
]
