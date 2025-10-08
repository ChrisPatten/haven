from __future__ import annotations

from typing import Iterable, List, Sequence

import httpx

from ..models import DeleteSelector, DocumentUpsert, SearchRequest, SearchResult


class SearchServiceClient:
    """Lightweight SDK for interacting with the Search Service."""

    def __init__(self, base_url: str, auth_token: str | None = None, timeout: float = 10.0) -> None:
        self._base_url = base_url.rstrip("/")
        self._auth_token = auth_token
        self._timeout = timeout

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self._auth_token:
            headers["Authorization"] = f"Bearer {self._auth_token}"
        return headers

    def batch_upsert(self, documents: Sequence[DocumentUpsert]) -> dict[str, object]:
        payload = [doc.model_dump(mode="json") for doc in documents]
        response = httpx.post(
            f"{self._base_url}/v1/ingest/documents:batchUpsert",
            json=payload,
            headers=self._headers(),
            timeout=self._timeout,
        )
        response.raise_for_status()
        return response.json()

    def delete(self, selector: DeleteSelector) -> dict[str, object]:
        response = httpx.post(
            f"{self._base_url}/v1/ingest/delete",
            json=selector.model_dump(mode="json"),
            headers=self._headers(),
            timeout=self._timeout,
        )
        response.raise_for_status()
        return response.json()

    def search(self, request: SearchRequest) -> SearchResult:
        response = httpx.post(
            f"{self._base_url}/v1/search/query",
            json=request.model_dump(mode="json"),
            headers=self._headers(),
            timeout=self._timeout,
        )
        response.raise_for_status()
        return SearchResult.model_validate(response.json())

    async def abatch_upsert(self, documents: Sequence[DocumentUpsert]) -> dict[str, object]:
        payload = [doc.model_dump(mode="json") for doc in documents]
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            response = await client.post(
                f"{self._base_url}/v1/ingest/documents:batchUpsert",
                json=payload,
                headers=self._headers(),
            )
        response.raise_for_status()
        return response.json()

    async def asearch(self, request: SearchRequest) -> SearchResult:
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            response = await client.post(
                f"{self._base_url}/v1/search/query",
                json=request.model_dump(mode="json"),
                headers=self._headers(),
            )
        response.raise_for_status()
        return SearchResult.model_validate(response.json())


__all__ = ["SearchServiceClient"]
