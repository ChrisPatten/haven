from __future__ import annotations

from fastapi import FastAPI

from shared.deps import assert_missing_dependencies

from .config import get_settings
from .routes import admin, indexes, ingest, search, tools


assert_missing_dependencies(["qdrant-client", "sentence-transformers"], "Search Service")


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="Haven Search Service", version="0.1.0")

    @app.get("/v1/healthz", tags=["system"])
    async def healthz() -> dict[str, str]:
        return {"status": "ok", "service": settings.service_name}

    app.include_router(ingest.router)
    app.include_router(search.router)
    app.include_router(indexes.router)
    app.include_router(admin.router)
    app.include_router(tools.router)

    return app


__all__ = ["create_app"]
