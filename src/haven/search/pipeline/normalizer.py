from __future__ import annotations

from collections.abc import Iterable
from datetime import datetime
from typing import Dict, Tuple

from ..models import DocumentUpsert


def normalize_document(document: DocumentUpsert) -> DocumentUpsert:
    """Apply lightweight normalization and ensure timestamps are timezone-aware."""

    normalized_meta: Dict[str, object] = {**document.metadata}
    if document.created_at and document.created_at.tzinfo is None:
        normalized_meta.setdefault("created_at_tz", "naive")
    if document.updated_at and document.updated_at.tzinfo is None:
        normalized_meta.setdefault("updated_at_tz", "naive")
    return document.model_copy(update={"metadata": normalized_meta})


def normalize_documents(documents: Iterable[DocumentUpsert]) -> Iterable[Tuple[str, DocumentUpsert]]:
    for doc in documents:
        yield doc.document_id, normalize_document(doc)


__all__ = ["normalize_document", "normalize_documents"]
