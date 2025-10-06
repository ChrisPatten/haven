from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Any, Dict, List, Optional

from fastapi import Depends, FastAPI, HTTPException, Request, status
from pydantic import BaseModel, Field, field_validator
from psycopg.types.json import Json

from shared.db import get_connection
from shared.logging import get_logger, setup_logging

logger = get_logger("catalog.api")


class CatalogSettings(BaseModel):
    database_url: str = Field(
        default_factory=lambda: os.getenv(
            "DATABASE_URL", "postgresql://postgres:postgres@postgres:5432/haven"
        )
    )
    ingest_token: Optional[str] = Field(default_factory=lambda: os.getenv("CATALOG_TOKEN"))
    embedding_model: str = Field(default_factory=lambda: os.getenv("EMBEDDING_MODEL", "bge-m3"))


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
            return DocResponse(
                doc_id=row[0],
                thread_id=row[1],
                ts=row[2],
                sender=row[3],
                text=row[4],
                attrs=row[5],
            )


@app.get("/v1/context/general", response_model=ContextGeneralResponse)
def get_context_general() -> ContextGeneralResponse:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM threads")
            total_threads = cur.fetchone()[0]

            cur.execute("SELECT COUNT(*) FROM messages")
            total_messages = cur.fetchone()[0]

            cur.execute(
                """
                SELECT m.thread_id, t.title, COUNT(*) AS message_count
                FROM messages m
                JOIN threads t ON t.id = m.thread_id
                GROUP BY m.thread_id, t.title
                ORDER BY message_count DESC
                LIMIT 5
                """
            )
            top_threads = [
                ContextThread(thread_id=row[0], title=row[1], message_count=row[2])
                for row in cur.fetchall()
            ]

            cur.execute(
                """
                SELECT doc_id, thread_id, ts, sender, text
                FROM messages
                ORDER BY ts DESC
                LIMIT 5
                """
            )
            recent_highlights = [
                ContextHighlight(
                    doc_id=row[0],
                    thread_id=row[1],
                    ts=row[2],
                    sender=row[3],
                    text=row[4],
                )
                for row in cur.fetchall()
            ]

    return ContextGeneralResponse(
        total_threads=total_threads,
        total_messages=total_messages,
        top_threads=top_threads,
        recent_highlights=recent_highlights,
    )


@app.get("/v1/healthz")
def healthcheck() -> Dict[str, str]:
    return {"status": "ok"}

