from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List

from ..models import ChunkInput, DocumentUpsert


@dataclass(slots=True)
class PreparedDocument:
    document: DocumentUpsert
    chunks: List[ChunkInput]

    @property
    def document_id(self) -> str:
        return self.document.document_id


@dataclass(slots=True)
class IngestResult:
    document_id: str
    chunk_ids: List[str]
    status: str = "pending"
    error: str | None = None


__all__ = ["PreparedDocument", "IngestResult"]
