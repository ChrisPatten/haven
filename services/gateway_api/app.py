from __future__ import annotations

import os
from typing import Any, Dict, List, Optional, Sequence, Union, Iterator

import httpx
from dataclasses import dataclass
from datetime import UTC, datetime

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field, ConfigDict, model_validator
try:  # pragma: no cover - optional dependency for tests
    from psycopg.rows import dict_row
except ImportError:  # pragma: no cover
    def dict_row(*_args, **_kwargs):  # type: ignore[misc]
        raise RuntimeError("psycopg is required for gateway database access; install haven-platform[common]")

from haven.search.models import PageCursor, SearchHit as SearchServiceHit, SearchRequest
from haven.search.sdk import SearchServiceClient

from shared.db import get_conn_str, get_connection
from shared.deps import assert_missing_dependencies
from shared.logging import get_logger, setup_logging
from shared.people_repository import (
    ContactAddress,
    ContactUrl,
    ContactValue,
    PeopleRepository,
    PersonIngestRecord,
)


assert_missing_dependencies(["authlib", "redis", "jinja2"], "Gateway API")

logger = get_logger("gateway.api")

CONTACT_SOURCE_DEFAULT = "macos_contacts"


class GatewaySettings(BaseModel):
    database_url: str = Field(default_factory=get_conn_str)
    api_token: str = Field(default_factory=lambda: os.getenv("AUTH_TOKEN", ""))
    catalog_base_url: str = Field(default_factory=lambda: os.getenv("CATALOG_BASE_URL", "http://catalog:8081"))
    catalog_token: str | None = Field(default_factory=lambda: os.getenv("CATALOG_TOKEN"))
    search_url: str = Field(default_factory=lambda: os.getenv("SEARCH_URL", "http://search:8080"))
    search_token: str | None = Field(default_factory=lambda: os.getenv("SEARCH_TOKEN"))
    contacts_default_region: str | None = Field(default_factory=lambda: os.getenv("CONTACTS_DEFAULT_REGION", "US"))
    # Helper service that exposes contact export (NDJSON). Gateway will proxy export requests to it.
    contacts_helper_url: str | None = Field(default_factory=lambda: os.getenv("CONTACTS_HELPER_URL"))
    contacts_helper_token: str | None = Field(default_factory=lambda: os.getenv("CONTACTS_HELPER_TOKEN"))


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


class ContactValueModel(BaseModel):
    value: str
    value_raw: Optional[str] = None
    label: Optional[str] = None
    priority: int = 100
    verified: bool = True

    model_config = ConfigDict(extra="ignore")


class ContactAddressModel(BaseModel):
    label: Optional[str] = None
    street: Optional[str] = None
    city: Optional[str] = None
    region: Optional[str] = None
    postal_code: Optional[str] = None
    country: Optional[str] = None

    model_config = ConfigDict(extra="ignore")


class ContactUrlModel(BaseModel):
    label: Optional[str] = None
    url: Optional[str] = None

    model_config = ConfigDict(extra="ignore")

    @model_validator(mode="before")
    @classmethod
    def populate_url(cls, value: Any) -> Any:
        if isinstance(value, dict) and "url" not in value and "value" in value:
            updated = dict(value)
            updated["url"] = updated.get("value")
            return updated
        return value


class PersonPayloadModel(BaseModel):
    external_id: str
    display_name: str
    given_name: Optional[str] = None
    family_name: Optional[str] = None
    organization: Optional[str] = None
    nicknames: List[str] = Field(default_factory=list)
    notes: Optional[str] = None
    photo_hash: Optional[str] = None
    emails: List[ContactValueModel] = Field(default_factory=list)
    phones: List[ContactValueModel] = Field(default_factory=list)
    addresses: List[ContactAddressModel] = Field(default_factory=list)
    urls: List[ContactUrlModel] = Field(default_factory=list)
    change_token: Optional[str] = None
    version: int = Field(default=1, ge=0)
    deleted: bool = False

    model_config = ConfigDict(extra="ignore")

    def to_record(self) -> PersonIngestRecord:
        return PersonIngestRecord(
            external_id=self.external_id,
            display_name=self.display_name,
            given_name=self.given_name,
            family_name=self.family_name,
            organization=self.organization,
            nicknames=tuple(self.nicknames),
            notes=self.notes,
            photo_hash=self.photo_hash,
            emails=tuple(
                ContactValue(
                    value=item.value,
                    value_raw=item.value_raw,
                    label=item.label,
                    priority=item.priority,
                    verified=item.verified,
                )
                for item in self.emails
            ),
            phones=tuple(
                ContactValue(
                    value=item.value,
                    value_raw=item.value_raw,
                    label=item.label,
                    priority=item.priority,
                    verified=item.verified,
                )
                for item in self.phones
            ),
            addresses=tuple(
                ContactAddress(
                    label=item.label,
                    street=item.street,
                    city=item.city,
                    region=item.region,
                    postal_code=item.postal_code,
                    country=item.country,
                )
                for item in self.addresses
            ),
            urls=tuple(
                ContactUrl(
                    label=item.label,
                    url=item.url,
                )
                for item in self.urls
            ),
            change_token=self.change_token,
            version=self.version,
            deleted=self.deleted,
        )


class ContactIngestRequest(BaseModel):
    source: str = Field(default="macos_contacts")
    device_id: str
    since_token: Optional[str] = None
    batch_id: str
    people: List[PersonPayloadModel] = Field(default_factory=list)

    model_config = ConfigDict(extra="ignore")


class ContactIngestResponse(BaseModel):
    accepted: int
    upserts: int
    deletes: int
    conflicts: int
    skipped: int
    since_token_next: Optional[str] = None


class ContactAddressSummary(BaseModel):
    label: Optional[str] = None
    city: Optional[str] = None
    region: Optional[str] = None
    country: Optional[str] = None


class PeopleSearchHit(BaseModel):
    person_id: str
    display_name: str
    given_name: Optional[str]
    family_name: Optional[str]
    organization: Optional[str]
    nicknames: List[str]
    emails: List[str]
    phones: List[str]
    addresses: List[ContactAddressSummary]


class PeopleSearchResponse(BaseModel):
    query: Optional[str]
    limit: int
    offset: int
    results: List[PeopleSearchHit]


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


@app.get("/catalog/contacts/export")
def proxy_contacts_export(
    request: Request,
    since_token: Optional[str] = Query(default=None),
    full: Optional[bool] = Query(default=False),
    _: None = Depends(require_token),
 ) -> StreamingResponse:
    """Proxy the contacts export NDJSON from the helper service through the gateway.

    This keeps the collector from needing direct access to the helper.
    """
    helper_base = settings.contacts_helper_url
    if not helper_base:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Contacts helper not configured")

    params: Dict[str, Union[str, bool]] = {}
    if since_token:
        params["since_token"] = since_token
    if full:
        params["full"] = "true"

    headers: Dict[str, str] = {"Accept": "application/x-ndjson"}
    if settings.contacts_helper_token:
        headers["Authorization"] = f"Bearer {settings.contacts_helper_token}"

    url = helper_base.rstrip("/") + "/contacts/export"

    try:
        def _stream_generator() -> Iterator[bytes]:
            # Open the httpx stream inside the generator so it remains open
            # for the duration of iteration by StreamingResponse.
            with httpx.stream("GET", url, params=params, headers=headers, timeout=30.0) as resp:
                resp.raise_for_status()
                for chunk in resp.iter_bytes():
                    yield chunk

        # Return a generator instance (not tied to a closed context) so
        # StreamingResponse can iterate and stream bytes to the client.
        return StreamingResponse(_stream_generator(), media_type="application/x-ndjson")
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=exc.response.status_code, detail=str(exc))
    except Exception as exc:  # pragma: no cover - defensive
        logger.exception("contacts_export_proxy_failed", error=str(exc))
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail="Failed to proxy contacts export")


@app.post("/catalog/contacts/ingest", response_model=ContactIngestResponse)
def ingest_contacts(
    payload: ContactIngestRequest,
    _: None = Depends(require_catalog_token),
) -> ContactIngestResponse:
    source = payload.source or CONTACT_SOURCE_DEFAULT

    records = [person.to_record() for person in payload.people]
    next_token = _resolve_next_token(payload.since_token, records)

    if not records:
        with get_connection(autocommit=False) as conn:
            _update_change_token(conn, source, payload.device_id, next_token)
            conn.commit()
        return ContactIngestResponse(
            accepted=0,
            upserts=0,
            deletes=0,
            conflicts=0,
            skipped=0,
            since_token_next=next_token,
        )

    with get_connection(autocommit=False) as conn:
        repo = PeopleRepository(conn, default_region=settings.contacts_default_region)
        try:
            stats = repo.upsert_batch(source, records)
            _update_change_token(conn, source, payload.device_id, next_token)
            conn.commit()
        except Exception:
            conn.rollback()
            logger.exception("contacts_ingest_failed", source=source, device_id=payload.device_id)
            raise

    return ContactIngestResponse(
        accepted=stats.accepted,
        upserts=stats.upserts,
        deletes=stats.deletes,
        conflicts=stats.conflicts,
        skipped=stats.skipped,
        since_token_next=next_token,
    )


def _resolve_next_token(
    initial_token: Optional[str],
    records: Sequence[PersonIngestRecord],
) -> Optional[str]:
    token = initial_token
    for record in records:
        if record.change_token:
            token = record.change_token
    return token


def _update_change_token(
    conn,
    source: str,
    device_id: str,
    token: Optional[str],
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO source_change_tokens (source, device_id, change_token_b64)
            VALUES (%s, %s, %s)
            ON CONFLICT (source, device_id) DO UPDATE
            SET change_token_b64 = EXCLUDED.change_token_b64,
                updated_at = NOW()
            """,
            (source, device_id, token),
        )


@app.get("/search/people", response_model=PeopleSearchResponse)
def search_people(
    request: Request,
    q: Optional[str] = Query(default=None, min_length=1),
    limit: int = Query(20, ge=1, le=200),
    offset: int = Query(0, ge=0),
    _: None = Depends(require_token),
) -> PeopleSearchResponse:
    facets = _parse_facets(request)
    conditions: List[str] = ["p.deleted = FALSE"]
    params: List[Any] = []

    if q:
        like = f"%{q}%"
        conditions.append(
            """
            (
                p.display_name ILIKE %s OR
                p.given_name ILIKE %s OR
                p.family_name ILIKE %s OR
                p.organization ILIKE %s OR
                %s = ANY(p.nicknames)
            )
            """
        )
        params.extend([like, like, like, like, q])

    labels = [value.lower() for value in facets.get("label", [])]
    if labels:
        conditions.append(
            """
            EXISTS (
                SELECT 1 FROM person_identifiers pi_label
                WHERE pi_label.person_id = p.person_id
                  AND pi_label.label = ANY(%s)
            )
            """
        )
        params.append(tuple(labels))

    kinds = [value for value in facets.get("kind", [])]
    if kinds:
        conditions.append(
            """
            EXISTS (
                SELECT 1 FROM person_identifiers pi_kind
                WHERE pi_kind.person_id = p.person_id
                  AND pi_kind.kind = ANY(%s)
            )
            """
        )
        params.append(tuple(kinds))

    cities = facets.get("city", [])
    if cities:
        conditions.append(
            """
            EXISTS (
                SELECT 1 FROM person_addresses pa_city
                WHERE pa_city.person_id = p.person_id
                  AND pa_city.city = ANY(%s)
            )
            """
        )
        params.append(tuple(cities))

    regions = facets.get("region", [])
    if regions:
        conditions.append(
            """
            EXISTS (
                SELECT 1 FROM person_addresses pa_region
                WHERE pa_region.person_id = p.person_id
                  AND pa_region.region = ANY(%s)
            )
            """
        )
        params.append(tuple(regions))

    countries = facets.get("country", [])
    if countries:
        conditions.append(
            """
            EXISTS (
                SELECT 1 FROM person_addresses pa_country
                WHERE pa_country.person_id = p.person_id
                  AND pa_country.country = ANY(%s)
            )
            """
        )
        params.append(tuple(countries))

    orgs = facets.get("organization", [])
    if orgs:
        conditions.append("p.organization = ANY(%s)")
        params.append(tuple(orgs))

    conditions_sql = " AND ".join(conditions) if conditions else "TRUE"

    base_query = f"""
        SELECT
            p.person_id,
            p.display_name,
            p.given_name,
            p.family_name,
            p.organization,
            p.nicknames,
            COALESCE(
                jsonb_agg(DISTINCT jsonb_build_object(
                    'kind', pi.kind,
                    'value_raw', pi.value_raw,
                    'value_canonical', pi.value_canonical,
                    'label', pi.label
                )) FILTER (WHERE pi.person_id IS NOT NULL),
                '[]'::jsonb
            ) AS identifiers,
            COALESCE(
                jsonb_agg(DISTINCT jsonb_build_object(
                    'label', pa.label,
                    'city', pa.city,
                    'region', pa.region,
                    'country', pa.country
                )) FILTER (WHERE pa.person_id IS NOT NULL),
                '[]'::jsonb
            ) AS addresses
        FROM people p
        LEFT JOIN person_identifiers pi ON pi.person_id = p.person_id
        LEFT JOIN person_addresses pa ON pa.person_id = p.person_id
        WHERE {conditions_sql}
        GROUP BY p.person_id
    """

    order_clause = "ORDER BY p.display_name ASC"
    order_params: List[Any] = []
    if q:
        order_clause = "ORDER BY similarity(p.display_name, %s) DESC, p.display_name ASC"
        order_params.append(q)

    sql = f"{base_query} {order_clause} LIMIT %s OFFSET %s"
    query_params = params + order_params + [limit, offset]

    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(sql, query_params)
            rows = cur.fetchall()

    results: List[PeopleSearchHit] = []
    for row in rows:
        identifiers = row.get("identifiers") or []
        emails = [
            ident.get("value_canonical") or ident.get("value_raw")
            for ident in identifiers
            if ident.get("kind") == "email"
        ]
        phones = [
            ident.get("value_canonical") or ident.get("value_raw")
            for ident in identifiers
            if ident.get("kind") == "phone"
        ]
        address_entries = [
            ContactAddressSummary(
                label=item.get("label"),
                city=item.get("city"),
                region=item.get("region"),
                country=item.get("country"),
            )
            for item in (row.get("addresses") or [])
        ]

        results.append(
            PeopleSearchHit(
                person_id=str(row["person_id"]),
                display_name=row.get("display_name"),
                given_name=row.get("given_name"),
                family_name=row.get("family_name"),
                organization=row.get("organization"),
                nicknames=row.get("nicknames") or [],
                emails=emails,
                phones=phones,
                addresses=address_entries,
            )
        )

    return PeopleSearchResponse(
        query=q,
        limit=limit,
        offset=offset,
        results=results,
    )


def _parse_facets(request: Request) -> Dict[str, List[str]]:
    facets: Dict[str, List[str]] = {}
    for key, value in request.query_params.multi_items():
        if key.startswith("facets[") and key.endswith("]"):
            facet_key = key[7:-1]
            facets.setdefault(facet_key, []).append(value)
    return facets

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
