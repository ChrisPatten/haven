from __future__ import annotations

from typing import Iterable, List

from ..models import ChunkInput, DocumentUpsert


def default_chunker(document: DocumentUpsert, max_tokens: int = 512) -> List[ChunkInput]:
    """Naive chunking implementation splitting text by paragraphs.

    Collectors can send explicit chunks; otherwise we split on double newlines as a
    placeholder until the semantic chunker is wired in upcoming iterations.
    """

    if document.chunks:
        return list(document.chunks)

    if not document.text:
        return []

    pieces = [part.strip() for part in document.text.split("\n\n") if part.strip()]
    chunks: List[ChunkInput] = []
    for idx, fragment in enumerate(pieces):
        chunks.append(
            ChunkInput(id=f"{document.document_id}:{idx}", text=fragment, meta={"chunk_index": idx})
        )
    if not chunks:
        chunks.append(ChunkInput(id=f"{document.document_id}:0", text=document.text, meta={"chunk_index": 0}))
    return chunks


def chunk_documents(documents: Iterable[DocumentUpsert]) -> Iterable[tuple[DocumentUpsert, List[ChunkInput]]]:
    for doc in documents:
        yield doc, default_chunker(doc)


__all__ = ["chunk_documents", "default_chunker"]
