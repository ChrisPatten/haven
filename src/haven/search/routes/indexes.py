from __future__ import annotations

from fastapi import APIRouter, Depends

from ..db import get_connection
from ..models import IndexStatus
from .ingest import get_org_id

router = APIRouter(prefix="/v1/index", tags=["index"])


@router.get("/status", response_model=IndexStatus)
async def index_status(org_id: str = Depends(get_org_id)) -> IndexStatus:
    async with get_connection() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                "SELECT COUNT(*) FROM search_documents WHERE org_id = %s",
                (org_id,),
            )
            doc_count = (await cur.fetchone() or [0])[0]
            await cur.execute(
                "SELECT COUNT(*) FROM search_chunks WHERE org_id = %s",
                (org_id,),
            )
            chunk_count = (await cur.fetchone() or [0])[0]
    return IndexStatus(
        collection=org_id,
        version="v1",
        health="green" if doc_count >= 0 else "yellow",
        document_count=doc_count,
        chunk_count=chunk_count,
        vector_count=chunk_count,
    )


__all__ = ["router"]
