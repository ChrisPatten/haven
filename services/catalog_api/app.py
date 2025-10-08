from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Any, Dict, List, Optional

from fastapi import Depends, FastAPI, HTTPException, Request, Query, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field, field_validator
from typing import Iterator
import orjson
from psycopg.types.json import Json

from shared.db import get_connection
from shared.logging import get_logger, setup_logging
from shared.context import fetch_context_overview
from shared.people_repository import PeopleResolver
from shared.people_normalization import IdentifierKind, normalize_identifier

logger = get_logger("catalog.api")


class CatalogSettings(BaseModel):
    database_url: str = Field(
        default_factory=lambda: os.getenv(
            "DATABASE_URL", "postgresql://postgres:postgres@postgres:5432/haven"
        )
    )
    ingest_token: Optional[str] = Field(default_factory=lambda: os.getenv("CATALOG_TOKEN"))
    embedding_model: str = Field(default_factory=lambda: os.getenv("EMBEDDING_MODEL", "BAAI/bge-m3"))
    contacts_default_region: str | None = Field(default_factory=lambda: os.getenv("CONTACTS_DEFAULT_REGION", "US"))


settings = CatalogSettings()


class ThreadPayload(BaseModel):
    id: str
    kind: str
    participants: List[str] = Field(default_factory=list)
    title: Optional[str] = None


class MessagePayload(BaseModel):
    row_id: Optional[int] = None
    guid: str
    thread_id: str
    ts: Optional[datetime] = None
    sender: str
    sender_service: Optional[str] = None
    is_from_me: bool
    text: str
    attrs: Dict[str, Any] = Field(default_factory=dict)

    @field_validator("ts", mode="before")
    @classmethod
    def parse_ts(cls, value: Any) -> Optional[datetime]:
        if value is None or isinstance(value, datetime):
            return value
        if isinstance(value, str):
            value = value.replace("Z", "+00:00")
            return datetime.fromisoformat(value)
        raise ValueError("Unsupported timestamp format")


class ChunkPayload(BaseModel):
    id: str
    chunk_index: int
    text: str
    meta: Dict[str, Any] = Field(default_factory=dict)


class CatalogEventItem(BaseModel):
    source: str
    doc_id: str
    thread: ThreadPayload
    message: MessagePayload
    chunks: List[ChunkPayload]


class CatalogEventsRequest(BaseModel):
    items: List[CatalogEventItem]


class DocResponse(BaseModel):
    doc_id: str
    thread_id: str
    ts: datetime
    sender: str
    text: str
    attrs: Dict[str, Any]


class ContextThread(BaseModel):
    thread_id: str
    title: Optional[str]
    message_count: int


class ContextHighlight(BaseModel):
    doc_id: str
    thread_id: str
    ts: datetime
    sender: str
    text: str


class ContextGeneralResponse(BaseModel):
    total_threads: int
    total_messages: int
    last_message_ts: Optional[datetime] = None
    top_threads: List[ContextThread]
    recent_highlights: List[ContextHighlight]


app = FastAPI(title="Haven Catalog API", version="0.1.0")


def verify_token(request: Request) -> None:
    if not settings.ingest_token:
        return
    header = request.headers.get("Authorization")
    if not header or not header.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing token")
    token = header.split(" ", 1)[1]
    if token != settings.ingest_token:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid token")


@app.on_event("startup")
def on_startup() -> None:
    setup_logging()
    os.environ.setdefault("DATABASE_URL", settings.database_url)
    logger.info("catalog_api_startup")


def _row_to_dict(cur, row) -> dict:
    # Build a dict for a cursor row using description
    cols = [d[0] for d in cur.description]
    return {k: v for k, v in zip(cols, row)}


@app.get("/contacts/export")
def export_contacts(
    request: Request,
    since_token: Optional[str] = Query(default=None),
    full: Optional[bool] = Query(default=False),
) -> StreamingResponse:
    """Stream contacts as NDJSON. Each line is a JSON object with fields:
    {"change_token": "...", "contact": {...}}

    since_token may be an ISO timestamp produced by this endpoint previously; when provided
    only contacts with updated_at > since_token will be emitted. If `full` is true, all
    contacts are emitted regardless of since_token.
    """

    def iter_contacts() -> Iterator[bytes]:
        with get_connection() as conn:
            with conn.cursor() as cur:
                # Fetch people, optionally filtering by since_token (which we expect to be an ISO ts)
                if since_token and not full:
                    try:
                        parsed = datetime.fromisoformat(since_token.replace("Z", "+00:00"))
                    except Exception:
                        parsed = None
                    if parsed:
                        cur.execute(
                            """
                            SELECT person_id, display_name, given_name, family_name, organization,
                                   nicknames, notes, photo_hash, version, deleted, updated_at
                            FROM people
                            WHERE updated_at > %s
                            ORDER BY updated_at ASC
                            """,
                            (parsed,)
                        )
                    else:
                        cur.execute(
                            """
                            SELECT person_id, display_name, given_name, family_name, organization,
                                   nicknames, notes, photo_hash, version, deleted, updated_at
                            FROM people
                            ORDER BY updated_at ASC
                            """,
                        )
                else:
                    cur.execute(
                        """
                        SELECT person_id, display_name, given_name, family_name, organization,
                               nicknames, notes, photo_hash, version, deleted, updated_at
                        FROM people
                        ORDER BY updated_at ASC
                        """,
                    )

                for row in cur.fetchall():
                    p = _row_to_dict(cur, row)
                    person_id = p["person_id"]

                    # identifiers
                    with conn.cursor() as cur_ids:
                        cur_ids.execute(
                            """
                            SELECT kind, value_raw, value_canonical, label, priority, verified
                            FROM person_identifiers
                            WHERE person_id = %s
                            """,
                            (person_id,)
                        )
                        ids = [ _row_to_dict(cur_ids, r) for r in cur_ids.fetchall() ]

                    phones = [
                        {"value": i["value_canonical"], "value_raw": i.get("value_raw"), "label": i.get("label"), "priority": i.get("priority"), "verified": i.get("verified")}
                        for i in ids if i.get("kind") == "phone"
                    ]
                    emails = [
                        {"value": i["value_canonical"], "value_raw": i.get("value_raw"), "label": i.get("label"), "priority": i.get("priority"), "verified": i.get("verified")}
                        for i in ids if i.get("kind") == "email"
                    ]

                    # addresses
                    with conn.cursor() as cur_addr:
                        cur_addr.execute(
                            """
                            SELECT label, street, city, region, postal_code, country
                            FROM person_addresses
                            WHERE person_id = %s
                            """,
                            (person_id,)
                        )
                        addrs = [ _row_to_dict(cur_addr, r) for r in cur_addr.fetchall() ]

                    addresses = [
                        {"label": a.get("label"), "street": a.get("street"), "city": a.get("city"), "region": a.get("region"), "postal_code": a.get("postal_code"), "country": a.get("country")}
                        for a in addrs
                    ]

                    # urls
                    with conn.cursor() as cur_urls:
                        cur_urls.execute(
                            """
                            SELECT label, url
                            FROM person_urls
                            WHERE person_id = %s
                            """,
                            (person_id,)
                        )
                        urls_r = [ _row_to_dict(cur_urls, r) for r in cur_urls.fetchall() ]

                    urls = [{"label": u.get("label"), "url": u.get("url")} for u in urls_r]

                    contact = {
                        "external_id": str(person_id),
                        "display_name": p.get("display_name"),
                        "given_name": p.get("given_name"),
                        "family_name": p.get("family_name"),
                        "organization": p.get("organization"),
                        "nicknames": p.get("nicknames") or [],
                        "notes": p.get("notes"),
                        "photo_hash": p.get("photo_hash"),
                        "emails": emails,
                        "phones": phones,
                        "addresses": addresses,
                        "urls": urls,
                        "version": int(p.get("version") or 1),
                        "deleted": bool(p.get("deleted")),
                    }

                    change_token = None
                    if p.get("updated_at"):
                        try:
                            change_token = p["updated_at"].isoformat()
                        except Exception:
                            change_token = None

                    out = {"change_token": change_token, "contact": contact}
                    yield orjson.dumps(out) + b"\n"

    return StreamingResponse(iter_contacts(), media_type="application/x-ndjson")


@app.post("/v1/catalog/events", status_code=status.HTTP_202_ACCEPTED)
def ingest_events(payload: CatalogEventsRequest, _: None = Depends(verify_token)) -> Dict[str, Any]:
    if not payload.items:
        return {"ingested": 0}

    ingested = 0
    with get_connection() as conn:
        with conn.cursor() as cur:
            for item in payload.items:
                logger.info("ingest_event", doc_id=item.doc_id, source=item.source)
                cur.execute(
                    """
                    INSERT INTO threads (id, kind, participants, title)
                    VALUES (%s, %s, %s, %s)
                    ON CONFLICT (id) DO UPDATE
                    SET participants = EXCLUDED.participants,
                        title = EXCLUDED.title,
                        updated_at = NOW()
                    """,
                    (
                        item.thread.id,
                        item.thread.kind,
                        Json(item.thread.participants),
                        item.thread.title,
                    ),
                )

                ts_value = item.message.ts or datetime.now(tz=UTC)

                cur.execute(
                    """
                    INSERT INTO messages (doc_id, thread_id, message_guid, ts, sender, sender_service, is_from_me, text, attrs)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (doc_id) DO UPDATE
                    SET text = EXCLUDED.text,
                        attrs = EXCLUDED.attrs,
                        ts = EXCLUDED.ts,
                        sender = EXCLUDED.sender,
                        sender_service = EXCLUDED.sender_service,
                        updated_at = NOW()
                    """,
                    (
                        item.doc_id,
                        item.thread.id,
                        item.message.guid,
                        ts_value,
                        item.message.sender,
                        item.message.sender_service,
                        item.message.is_from_me,
                        item.message.text,
                        Json(item.message.attrs),
                    ),
                )

                for chunk in item.chunks:
                    cur.execute(
                        """
                        INSERT INTO chunks (id, doc_id, chunk_index, text, meta)
                        VALUES (%s, %s, %s, %s, %s)
                        ON CONFLICT (id) DO UPDATE
                        SET text = EXCLUDED.text,
                            meta = EXCLUDED.meta
                        RETURNING id
                        """,
                        (
                            chunk.id,
                            item.doc_id,
                            chunk.chunk_index,
                            chunk.text,
                            Json(chunk.meta),
                        ),
                    )
                    chunk_id = cur.fetchone()[0]
                    cur.execute(
                        """
                        INSERT INTO embed_index_state (chunk_id, model, status)
                        VALUES (%s, %s, 'pending')
                        ON CONFLICT (chunk_id) DO UPDATE
                        SET status = 'pending', updated_at = NOW(), last_error = NULL
                        """,
                        (chunk_id, settings.embedding_model),
                    )

                ingested += 1

    return {"ingested": ingested}


@app.get("/v1/doc/{doc_id}", response_model=DocResponse)
def get_document(doc_id: str) -> DocResponse:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT doc_id, thread_id, ts, sender, text, attrs
                FROM messages
                WHERE doc_id = %s
                """,
                (doc_id,),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Document not found")
            sender_value = row[3] or ""
            # Try to resolve sender to an ingested contact (skip 'me' and empty)
            if sender_value and sender_value != "me":
                try:
                    kind = IdentifierKind.EMAIL if "@" in sender_value else IdentifierKind.PHONE
                    ident = normalize_identifier(kind, sender_value, default_region=None)
                    resolver = PeopleResolver(conn, default_region=settings.contacts_default_region)
                    person = resolver.resolve(kind, sender_value)
                    if person and person.get("display_name"):
                        sender_value = person.get("display_name")
                except Exception:
                    # If normalization/resolution fails, fall back to raw sender
                    pass

            return DocResponse(
                doc_id=row[0],
                thread_id=row[1],
                ts=row[2],
                sender=str(sender_value),
                text=row[4],
                attrs=row[5],
            )


@app.get("/v1/context/general", response_model=ContextGeneralResponse)
def get_context_general() -> ContextGeneralResponse:
    with get_connection() as conn:
        overview = fetch_context_overview(conn)

    top_threads = [
        ContextThread(thread_id=t["thread_id"], title=t["title"], message_count=t["message_count"])
        for t in overview["top_threads"]
    ]
    recent_highlights = [
        ContextHighlight(**h) for h in overview["recent_highlights"]
    ]

    return ContextGeneralResponse(
        total_threads=overview["total_threads"],
        total_messages=overview["total_messages"],
        last_message_ts=overview.get("last_message_ts"),
        top_threads=top_threads,
        recent_highlights=recent_highlights,
    )


@app.get("/v1/healthz")
def healthcheck() -> Dict[str, str]:
    return {"status": "ok"}
