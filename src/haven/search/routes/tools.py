from __future__ import annotations

from fastapi import APIRouter, Depends

from ..models import DocumentUpsert, ExtractResponse
from ..pipeline.chunker import default_chunker
from .ingest import get_org_id

router = APIRouter(prefix="/v1/tools", tags=["tools"])


@router.post("/extract", response_model=ExtractResponse)
async def extract_chunks(
    document: DocumentUpsert,
    org_id: str = Depends(get_org_id),
) -> ExtractResponse:
    # org_id currently unused but reserved for audit pipeline
    chunks = default_chunker(document)
    return ExtractResponse(
        document_id=document.document_id,
        chunks=chunks,
        facets=document.facets,
        metadata=document.metadata,
    )


__all__ = ["router"]
