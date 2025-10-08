from __future__ import annotations

from fastapi import APIRouter, Depends

from .ingest import get_org_id

router = APIRouter(prefix="/v1/admin", tags=["admin"])


@router.post("/reindex")
async def trigger_reindex(org_id: str = Depends(get_org_id)) -> dict[str, str]:
    # Placeholder implementation until index workers are wired in.
    return {"status": "scheduled", "org_id": org_id}


__all__ = ["router"]
