from __future__ import annotations

from functools import lru_cache

from fastapi import APIRouter, Depends, HTTPException, status

from ..models import SearchRequest, SearchResult
from ..services.hybrid import HybridSearchService
from .ingest import get_org_id

router = APIRouter(prefix="/v1/search", tags=["search"])


@lru_cache(maxsize=1)
def get_service() -> HybridSearchService:
    return HybridSearchService()


@router.post("/query", response_model=SearchResult)
async def query(
    request: SearchRequest,
    org_id: str = Depends(get_org_id),
    service: HybridSearchService = Depends(get_service),
) -> SearchResult:
    if not request.query and not request.vector:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="query or vector must be provided")
    return await service.search(org_id=org_id, request=request)


@router.post("/similar", response_model=SearchResult)
async def similar(
    request: SearchRequest,
    org_id: str = Depends(get_org_id),
    service: HybridSearchService = Depends(get_service),
) -> SearchResult:
    if not request.vector:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="vector spec required for /similar")
    return await service.search(org_id=org_id, request=request)


__all__ = ["router"]
