from __future__ import annotations

from typing import List

from fastapi import APIRouter, Depends, HTTPException, status

from ..models import DeleteSelector, DocumentUpsert
from ..pipeline.ingest import IngestionPipeline

router = APIRouter(prefix="/v1/ingest", tags=["ingest"])


def get_pipeline() -> IngestionPipeline:
    return IngestionPipeline()


def get_org_id() -> str:
    # TODO: replace with real auth extraction once mTLS/JWT plumbing lands
    return "default"


@router.post("/documents:batchUpsert", status_code=status.HTTP_202_ACCEPTED)
async def batch_upsert(
    payload: List[DocumentUpsert],
    pipeline: IngestionPipeline = Depends(get_pipeline),
    org_id: str = Depends(get_org_id),
) -> dict[str, object]:
    if not payload:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Request body must include documents")

    try:
        results = await pipeline.upsert(org_id=org_id, documents=payload)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    ingested = [result.document_id for result in results if result.status == "stored"]
    pending = sum(1 for item in results if item.status == "stored" for chunk_id in item.chunk_ids if chunk_id)
    return {"ingested": ingested, "pending_embeddings": pending, "skipped": [r.document_id for r in results if r.status == "skipped"]}


@router.post("/delete", status_code=status.HTTP_202_ACCEPTED)
async def delete_documents(
    selector: DeleteSelector,
    pipeline: IngestionPipeline = Depends(get_pipeline),
    org_id: str = Depends(get_org_id),
) -> dict[str, object]:
    if selector.is_empty():
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Selector must specify doc_ids, source_ids, or query")

    deleted = await pipeline.delete(org_id=org_id, selector=selector.model_dump())
    return {"deleted": deleted}


__all__ = ["router"]
