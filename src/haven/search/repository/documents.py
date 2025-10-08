from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Iterable, Protocol

from ..models import DocumentUpsert, SearchResult


class DocumentRepository(ABC):
    """Abstract storage interface for canonical documents and chunk metadata."""

    @abstractmethod
    async def upsert_documents(self, org_id: str, documents: Iterable[DocumentUpsert]) -> None:
        """Persist a list of documents and their chunk metadata."""

    @abstractmethod
    async def delete_documents(self, org_id: str, selector: dict[str, object]) -> int:
        """Delete documents matching the selector returning number removed."""

    @abstractmethod
    async def search(self, org_id: str, query: dict[str, object]) -> SearchResult:
        """Execute hybrid search using repository specific implementation."""


class ChunkIterator(Protocol):
    async def __anext__(self) -> tuple[str, str]:  # chunk_id, text
        ...


__all__ = ["DocumentRepository", "ChunkIterator"]
