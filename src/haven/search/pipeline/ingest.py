from __future__ import annotations

from typing import Iterable, List

from ..models import DocumentUpsert
from ..repository.postgres import PostgresDocumentRepository
from .chunker import default_chunker
from .normalizer import normalize_document
from .types import IngestResult, PreparedDocument


class IngestionPipeline:
    """Coordinates normalization, chunking, and persistence."""

    def __init__(self, repository: PostgresDocumentRepository | None = None) -> None:
        self._repository = repository or PostgresDocumentRepository()

    async def prepare_documents(self, documents: Iterable[DocumentUpsert]) -> List[PreparedDocument]:
        prepared: List[PreparedDocument] = []
        for doc in documents:
            normalized = normalize_document(doc)
            chunks = default_chunker(normalized)
            prepared.append(PreparedDocument(document=normalized, chunks=chunks))
        return prepared

    async def upsert(self, org_id: str, documents: Iterable[DocumentUpsert]) -> List[IngestResult]:
        prepared = await self.prepare_documents(documents)
        for item in prepared:
            if item.document.acl.org_id != org_id:
                raise ValueError(
                    f"document {item.document_id} ACL org_id {item.document.acl.org_id} mismatches request scope {org_id}"
                )
        stored_ids = await self._repository.upsert_documents(org_id, prepared)
        results: List[IngestResult] = []
        stored_set = set(stored_ids)
        for item in prepared:
            status = "stored" if item.document_id in stored_set else "skipped"
            results.append(
                IngestResult(
                    document_id=item.document_id,
                    chunk_ids=[chunk.id or "" for chunk in item.chunks],
                    status=status,
                )
            )
        return results

    async def delete(self, org_id: str, selector: dict[str, object]) -> int:
        return await self._repository.delete_documents(org_id, selector)


__all__ = ["IngestionPipeline"]
