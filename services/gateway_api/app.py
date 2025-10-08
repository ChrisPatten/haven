from __future__ import annotations

import os
from typing import Any, Dict, List

import httpx
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Dict, List, Sequence, Union

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response, status
from pydantic import BaseModel, Field

from haven.search.models import PageCursor, SearchHit as SearchServiceHit, SearchRequest
from haven.search.sdk import SearchServiceClient

from shared.db import get_conn_str
from shared.deps import assert_missing_dependencies
from shared.logging import get_logger, setup_logging


assert_missing_dependencies(["authlib", "redis", "jinja2"], "Gateway API")

logger = get_logger("gateway.api")


class GatewaySettings(BaseModel):
    database_url: str = Field(default_factory=get_conn_str)
    api_token: str = Field(default_factory=lambda: os.getenv("AUTH_TOKEN", ""))
    catalog_base_url: str = Field(default_factory=lambda: os.getenv("CATALOG_BASE_URL", "http://catalog:8081"))
    catalog_token: str | None = Field(default_factory=lambda: os.getenv("CATALOG_TOKEN"))
    search_url: str = Field(default_factory=lambda: os.getenv("SEARCH_URL", "http://search:8080"))
    search_token: str | None = Field(default_factory=lambda: os.getenv("SEARCH_TOKEN"))


settings = GatewaySettings()
app = FastAPI(title="Haven Gateway API", version="0.2.0")

_search_client: SearchServiceClient | None = None


@app.on_event("startup")
def on_startup() -> None:
    setup_logging()
    os.environ.setdefault("DATABASE_URL", settings.database_url)
    global _search_client
    _search_client = SearchServiceClient(base_url=settings.search_url, auth_token=settings.search_token)
    logger.info("gateway_api_ready", search_url=settings.search_url)


def get_search_client() -> SearchServiceClient:
    if _search_client is None:
        raise RuntimeError("search client not initialized")
    return _search_client


class SearchHit(BaseModel):
    document_id: str
    chunk_id: str | None
    title: str | None
    url: str | None
    snippet: str | None
    score: float
    sources: List[str]
    metadata: Dict[str, Any]


class SearchResponse(BaseModel):
    query: str
    results: List[SearchHit]


class AskRequest(BaseModel):
    query: str
    k: int = 5


class AskResponse(BaseModel):
    query: str
    answer: str
    citations: List[Dict[str, Any]]


@dataclass
class MessageDoc:
    doc_id: str
    thread_id: str
    ts: datetime
    sender: str
    text: str


def require_token(request: Request) -> None:
    if not settings.api_token:
        return
    header = request.headers.get("Authorization")
    if not header or not header.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing token")
    token = header.split(" ", 1)[1]
    if token != settings.api_token:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid token")


def require_catalog_token(request: Request) -> None:
    catalog_token = settings.catalog_token
    if not catalog_token:
        return
    header = request.headers.get("Authorization")
    if not header or not header.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing catalog token")
    token = header.split(" ", 1)[1]
    if token != catalog_token:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid catalog token")


@app.get("/v1/search", response_model=SearchResponse)
async def search_endpoint(
    q: str = Query(..., min_length=1),
    k: int = Query(20, ge=1, le=50),
    _: None = Depends(require_token),
    client: SearchServiceClient = Depends(get_search_client),
) -> SearchResponse:
    request = SearchRequest(query=q, page=PageCursor(size=k))
    result = await client.asearch(request)
    hits = [convert_hit(hit) for hit in result.hits]
    return SearchResponse(query=q, results=hits)


@app.post("/v1/ask", response_model=AskResponse)
async def ask_endpoint(
    payload: AskRequest,
    _: None = Depends(require_token),
    client: SearchServiceClient = Depends(get_search_client),
) -> AskResponse:
    k = min(max(payload.k, 1), 10)
    request = SearchRequest(query=payload.query, page=PageCursor(size=k))
    result = await client.asearch(request)
    ordered_docs = [convert_hit(hit) for hit in result.hits[:k]]

    answer = build_summary_text(payload.query, ordered_docs)
    citations = [
        {"document_id": hit.document_id, "chunk_id": hit.chunk_id, "score": hit.score}
        for hit in ordered_docs
    ]
    return AskResponse(query=payload.query, answer=answer, citations=citations)


def convert_hit(hit: SearchServiceHit) -> SearchHit:
    return SearchHit(
        document_id=hit.document_id,
        chunk_id=hit.chunk_id,
        title=hit.title,
        url=hit.url,
        snippet=hit.snippet,
        score=hit.score,
        sources=hit.sources,
        metadata=hit.metadata,
    )


SummaryInput = Union[SearchHit, MessageDoc]


def build_summary_text(query: str, docs: Sequence[SummaryInput]) -> str:
    if not docs:
        return "No relevant messages found."

    summary_sentences: List[str] = []
    for doc in docs[:3]:
        if isinstance(doc, MessageDoc):
            ts_str = doc.ts.astimezone(UTC).strftime("%Y-%m-%d %H:%M")
            summary_sentences.append(f"{doc.sender} mentioned '{doc.text}' on {ts_str} UTC.")
        else:
            title = doc.title or doc.metadata.get("title") or doc.document_id
            snippet = (doc.snippet or doc.metadata.get("snippet", "")).strip().replace("\n", " ")
            snippet = snippet[:160] + ("…" if len(snippet) > 160 else "")
            summary_sentences.append(f"Document '{title}' scored {doc.score:.2f}: {snippet}")

    intro = f"Summary for query '{query}':"
    return intro + " " + " ".join(summary_sentences)


@app.get("/v1/doc/{doc_id}")
async def doc_endpoint(doc_id: str, _: None = Depends(require_token)) -> Dict[str, Any]:
    """Proxy document lookups to the Catalog service which owns record-wise access.

    The Catalog service is responsible for create/update/delete and record lookups.
    Gateway will forward the request and surface the same 404/200 behavior.
    """
    headers: Dict[str, str] = {}
    if settings.catalog_token:
        headers["Authorization"] = f"Bearer {settings.catalog_token}"

    async with httpx.AsyncClient(base_url=settings.catalog_base_url, timeout=10.0) as client:
        response = await client.get(f"/v1/doc/{doc_id}", headers=headers)

    if response.status_code == 404:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Document not found")
    if response.status_code >= 400:
        try:
            detail: Any = response.json()
        except ValueError:
            detail = response.text
        raise HTTPException(status_code=response.status_code, detail=detail)

    return response.json()


@app.get("/v1/context/general")
async def context_general(_: None = Depends(require_token)) -> Dict[str, Any]:
    headers: Dict[str, str] = {}
    if settings.catalog_token:
        headers["Authorization"] = f"Bearer {settings.catalog_token}"

    async with httpx.AsyncClient(base_url=settings.catalog_base_url, timeout=10.0) as client:
        response = await client.get("/v1/context/general", headers=headers)

    if response.status_code >= 400:
        try:
            detail: Any = response.json()
        except ValueError:
            detail = response.text
        raise HTTPException(status_code=response.status_code, detail=detail)

    return response.json()


@app.post("/v1/catalog/events", status_code=status.HTTP_202_ACCEPTED)
async def proxy_catalog_events(
    request: Request,
    _: None = Depends(require_catalog_token),
) -> Response:
    payload = await request.body()

    headers: Dict[str, str] = {"Content-Type": request.headers.get("content-type", "application/json")}
    if settings.catalog_token:
        headers["Authorization"] = f"Bearer {settings.catalog_token}"

    async with httpx.AsyncClient(base_url=settings.catalog_base_url, timeout=10.0) as client:
        response = await client.post("/v1/catalog/events", content=payload, headers=headers)

    return Response(
        content=response.content,
        status_code=response.status_code,
        media_type=response.headers.get("content-type", "application/json"),
    )


@app.get("/v1/healthz")
async def health() -> Dict[str, str]:
    return {"status": "ok"}
