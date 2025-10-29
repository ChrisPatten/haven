from __future__ import annotations

import base64
import hashlib
import io
import json
import mimetypes
import os
import tempfile
import uuid
from dataclasses import dataclass, field, asdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Sequence, Union, Literal

import httpx
from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    Query,
    Request,
    Response,
    UploadFile,
    status,
)
from fastapi.responses import JSONResponse, StreamingResponse
from minio import Minio
from minio.error import S3Error
from pdfminer.high_level import extract_text as pdf_extract_text
from pydantic import BaseModel, Field, ConfigDict, ValidationError, model_validator

try:  # pragma: no cover - optional dependency for tests
    from psycopg.rows import dict_row
except ImportError:  # pragma: no cover

    def dict_row(*_args, **_kwargs):  # type: ignore[misc]
        raise RuntimeError(
            "psycopg is required for gateway database access; install haven-platform[common]"
        )


from haven.search.models import (
    PageCursor,
    QueryFilter,
    RangeFilter,
    SearchHit as SearchServiceHit,
    SearchRequest,
)
from haven.search.sdk import SearchServiceClient

from shared.db import get_conn_str, get_connection, get_active_document
from shared.deps import assert_missing_dependencies
from shared.logging import get_logger, setup_logging
from shared.people_repository import (
    ContactAddress,
    ContactUrl,
    ContactValue,
    PersonIngestRecord,
)


assert_missing_dependencies(["authlib", "redis", "jinja2"], "Gateway API")

logger = get_logger("gateway.api")

CONTACT_SOURCE_DEFAULT = "macos_contacts"


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.lower() in ("1", "true", "yes", "on")


SUPPORTED_LOCALFS_EXTENSIONS: dict[str, str] = {
    ".txt": "text/plain",
    ".md": "text/markdown",
    ".pdf": "application/pdf",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".heic": "image/heic",
}

IMAGE_PLACEHOLDER_TEXT = os.getenv("IMAGE_PLACEHOLDER_TEXT", "[image]")
FILE_PLACEHOLDER_TEXT = os.getenv("FILE_PLACEHOLDER_TEXT", "[file]")


class GatewaySettings(BaseModel):
    database_url: str = Field(default_factory=get_conn_str)
    api_token: str = Field(default_factory=lambda: os.getenv("AUTH_TOKEN", ""))
    catalog_base_url: str = Field(
        default_factory=lambda: os.getenv("CATALOG_BASE_URL", "http://catalog:8081")
    )
    catalog_token: str | None = Field(
        default_factory=lambda: os.getenv("CATALOG_TOKEN")
    )
    search_url: str = Field(
        default_factory=lambda: os.getenv("SEARCH_URL", "http://search:8080")
    )
    search_token: str | None = Field(default_factory=lambda: os.getenv("SEARCH_TOKEN"))
    search_timeout: float = Field(
        default_factory=lambda: float(os.getenv("SEARCH_TIMEOUT", "60.0"))
    )
    contacts_default_region: str | None = Field(
        default_factory=lambda: os.getenv("CONTACTS_DEFAULT_REGION", "US")
    )
    # Helper service that exposes contact export (NDJSON). Gateway will proxy export requests to it.
    contacts_helper_url: str | None = Field(
        default_factory=lambda: os.getenv("CONTACTS_HELPER_URL")
    )
    contacts_helper_token: str | None = Field(
        default_factory=lambda: os.getenv("CONTACTS_HELPER_TOKEN")
    )
    minio_endpoint: str = Field(
        default_factory=lambda: os.getenv("MINIO_ENDPOINT", "minio:9000")
    )
    minio_access_key: str = Field(
        default_factory=lambda: os.getenv("MINIO_ACCESS_KEY", "minioadmin")
    )
    minio_secret_key: str = Field(
        default_factory=lambda: os.getenv("MINIO_SECRET_KEY", "minioadmin")
    )
    minio_bucket: str = Field(
        default_factory=lambda: os.getenv("MINIO_BUCKET", "haven-files")
    )
    minio_secure: bool = Field(default_factory=lambda: _env_bool("MINIO_SECURE", False))


settings = GatewaySettings()
app = FastAPI(title="Haven Gateway API", version="0.2.0")

_search_client: SearchServiceClient | None = None
_minio_client: Minio | None = None
_minio_bucket_checked = False


@app.on_event("startup")
def on_startup() -> None:
    setup_logging()
    os.environ.setdefault("DATABASE_URL", settings.database_url)
    global _search_client
    _search_client = SearchServiceClient(
        base_url=settings.search_url,
        auth_token=settings.search_token,
        timeout=settings.search_timeout,
    )
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


def _contact_external_id(source: str, record: PersonIngestRecord) -> str:
    return f"contact:{source}:{record.external_id}"


def _contact_people_entries(record: PersonIngestRecord) -> List[Dict[str, Any]]:
    people: List[Dict[str, Any]] = []
    for email in record.emails:
        if email.value:
            people.append(
                {
                    "identifier": email.value,
                    "identifier_type": "email",
                    "role": "contact",
                    "label": email.label,
                }
            )
    for phone in record.phones:
        if phone.value:
            people.append(
                {
                    "identifier": phone.value,
                    "identifier_type": "phone",
                    "role": "contact",
                    "label": phone.label,
                }
            )
    if record.display_name:
        people.append(
            {
                "identifier": record.display_name,
                "identifier_type": "name",
                "role": "contact",
            }
        )
    return people


def _contact_metadata(record: PersonIngestRecord, text_sha: str) -> Dict[str, Any]:
    def _values_to_dict(values: Sequence[ContactValue]) -> List[Dict[str, Any]]:
        results: List[Dict[str, Any]] = []
        for value in values:
            results.append(
                {
                    "value": value.value,
                    "value_raw": value.value_raw,
                    "label": value.label,
                    "priority": value.priority,
                    "verified": value.verified,
                }
            )
        return results

    contact_dict: Dict[str, Any] = {
        "display_name": record.display_name,
        "given_name": record.given_name,
        "family_name": record.family_name,
        "organization": record.organization,
        "nicknames": list(record.nicknames),
        "notes": record.notes,
        "photo_hash": record.photo_hash,
        "version": record.version,
        "deleted": record.deleted,
        "emails": _values_to_dict(record.emails),
        "phones": _values_to_dict(record.phones),
        "addresses": [asdict(addr) for addr in record.addresses],
        "urls": [asdict(url) for url in record.urls],
    }
    return {
        "source": "contacts",
        "text_sha256": text_sha,
        "contact": contact_dict,
        "change_token": record.change_token,
        "ingested_at": datetime.now(tz=UTC).isoformat(),
    }


def _contact_text(record: PersonIngestRecord) -> str:
    lines: List[str] = []
    if record.display_name:
        lines.append(record.display_name)
    if record.given_name or record.family_name:
        parts = [part for part in (record.given_name, record.family_name) if part]
        if parts:
            lines.append("Name: " + " ".join(parts))
    if record.organization:
        lines.append(f"Organization: {record.organization}")
    if record.nicknames:
        lines.append("Nicknames: " + ", ".join(record.nicknames))
    if record.emails:
        lines.extend(f"Email: {value.value}" for value in record.emails if value.value)
    if record.phones:
        lines.extend(f"Phone: {value.value}" for value in record.phones if value.value)
    if record.addresses:
        for address in record.addresses:
            parts = [
                getattr(address, "street", None),
                getattr(address, "city", None),
                getattr(address, "region", None),
                getattr(address, "postal_code", None),
                getattr(address, "country", None),
            ]
            formatted = ", ".join(part for part in parts if part)
            if formatted:
                lines.append(f"Address: {formatted}")
    if record.urls:
        lines.extend(f"URL: {getattr(url, 'url', None)}" for url in record.urls if getattr(url, "url", None))
    if record.notes:
        lines.append("Notes: " + record.notes)
    if not lines:
        return f"Contact {record.external_id}"
    return "\n".join(line.strip() for line in lines if line and line.strip())


def _build_contact_document_payload(source: str, record: PersonIngestRecord) -> Dict[str, Any]:
    external_id = _contact_external_id(source, record)
    text = _contact_text(record)
    text_sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
    people = _contact_people_entries(record)
    metadata = _contact_metadata(record, text_sha)
    idempotency_key = hashlib.sha256(
        f"{external_id}:{text_sha}:{record.version}:{record.deleted}".encode("utf-8")
    ).hexdigest()
    timestamp = datetime.now(tz=UTC).isoformat()
    payload: Dict[str, Any] = {
        "idempotency_key": idempotency_key,
        "source_type": "contact",
        "source_provider": source,
        "source_id": external_id,
        "external_id": external_id,
        "title": record.display_name or record.organization or external_id,
        "content_sha256": text_sha,
        "content_timestamp": timestamp,
        "content_timestamp_type": "modified",
        "content_created_at": timestamp,
        "text": text,
        "mime_type": "text/plain",
        "metadata": metadata,
        "people": people,
        "facet_overrides": {
            "has_attachments": False,
            "attachment_count": 0,
        },
    }
    return payload


def _catalog_sync_request(
    method: str,
    path: str,
    correlation_id: str,
    *,
    json_payload: Optional[Dict[str, Any]] = None,
) -> httpx.Response:
    headers: Dict[str, str] = {"X-Correlation-ID": correlation_id}
    if settings.catalog_token:
        headers["Authorization"] = f"Bearer {settings.catalog_token}"
    with httpx.Client(
        base_url=settings.catalog_base_url,
        timeout=CATALOG_TIMEOUT_SECONDS,
    ) as client:
        return client.request(method, path, json=json_payload, headers=headers)


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


@dataclass
class FileExtractionResult:
    text: str
    status: Literal["ready", "failed"]
    attachment_text: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)
    error: Optional[Dict[str, Any]] = None


@dataclass
class PreparedIngestDocument:
    payload: Dict[str, Any]
    content_sha256: str


@dataclass
class PreparedBatchItem:
    index: int
    payload: Dict[str, Any]
    content_sha256: str
    correlation_id: str


class IngestPreparationError(Exception):
    def __init__(
        self,
        status_code: int,
        error_code: str,
        message: str,
        *,
        retryable: bool = False,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.error_code = error_code
        self.message = message
        self.retryable = retryable
        self.details = details or {}


class LocalFileMeta(BaseModel):
    source: str = "localfs"
    path: str
    filename: Optional[str] = None
    mtime: Optional[float] = None
    ctime: Optional[float] = None
    tags: List[str] = Field(default_factory=list)

    model_config = ConfigDict(extra="allow")


class IngestContentModel(BaseModel):
    mime_type: str = "text/plain"
    data: str
    encoding: Optional[str] = None


class DocumentPerson(BaseModel):
    identifier: str
    identifier_type: Optional[str] = None
    role: Optional[str] = None
    display_name: Optional[str] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)


class ThreadPayloadModel(BaseModel):
    external_id: str
    source_type: Optional[str] = None
    source_provider: Optional[str] = None
    title: Optional[str] = None
    participants: List[DocumentPerson] = Field(default_factory=list)
    thread_type: Optional[str] = None
    is_group: Optional[bool] = None
    participant_count: Optional[int] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)
    first_message_at: Optional[datetime] = None
    last_message_at: Optional[datetime] = None


class IngestRequestModel(BaseModel):
    source_type: str
    source_id: str
    source_provider: Optional[str] = None
    external_id: Optional[str] = None
    title: Optional[str] = None
    canonical_uri: Optional[str] = None
    content: IngestContentModel
    metadata: Dict[str, Any] = Field(default_factory=dict)
    content_timestamp: Optional[datetime] = None
    content_timestamp_type: Optional[str] = None
    content_created_at: Optional[datetime] = None
    content_modified_at: Optional[datetime] = None
    people: List[DocumentPerson] = Field(default_factory=list)
    thread_id: Optional[uuid.UUID] = None
    thread: Optional[ThreadPayloadModel] = None


class BatchIngestRequest(BaseModel):
    documents: List[IngestRequestModel] = Field(default_factory=list, min_items=1)


class BatchIngestItemResult(BaseModel):
    index: int
    status_code: int
    content_sha256: Optional[str] = None
    submission: Optional[IngestSubmissionResponse] = None
    error: Optional[ErrorEnvelope] = None


class BatchIngestResponse(BaseModel):
    batch_id: Optional[str] = None
    batch_status: Optional[str] = None
    total_count: Optional[int] = None
    success_count: int
    failure_count: int
    results: List[BatchIngestItemResult]


class IngestSubmissionResponse(BaseModel):
    submission_id: str
    doc_id: str
    external_id: str
    version_number: int
    status: str
    thread_id: Optional[str] = None
    file_ids: List[str] = Field(default_factory=list)
    duplicate: bool = False
    total_chunks: int = 0  # maintained for backward compatibility


class IngestStatusResponse(BaseModel):
    submission_id: str
    status: str
    document_status: Optional[str] = None
    doc_id: Optional[str] = None
    total_chunks: int = 0
    embedded_chunks: int = 0
    pending_chunks: int = 0
    error: Optional[Dict[str, Any]] = None


class FileIngestResponse(IngestSubmissionResponse):
    file_sha256: str
    object_key: str
    extraction_status: Literal["ready", "failed"]


class ErrorEnvelope(BaseModel):
    error_code: str
    message: str
    retryable: bool
    correlation_id: str
    details: Dict[str, Any] = Field(default_factory=dict)


CATALOG_TIMEOUT_SECONDS = float(os.getenv("CATALOG_TIMEOUT_SECONDS", "15"))
SUPPORTED_TEXT_MIME_TYPES = {"text/plain", "text/markdown"}
DEFAULT_SENT_SOURCES = {"imessage", "sms", "email"}
ALLOWED_TIMESTAMP_TYPES = {
    "sent",
    "received",
    "modified",
    "created",
    "event_start",
    "event_end",
    "due",
    "completed",
}


def _normalize_ingest_text(value: str) -> str:
    return value.replace("\r\n", "\n").replace("\r", "\n").strip()


def _compute_sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _build_idempotency_key(source_type: str, source_id: str, text_hash: str) -> str:
    seed = f"{source_type}:{source_id}:{text_hash}"
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()


def _derive_batch_idempotency_key(keys: Sequence[str]) -> str:
    seed = "|".join(sorted(keys))
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()


def _ensure_utc(ts: Optional[datetime]) -> Optional[datetime]:
    if ts is None:
        return None
    if ts.tzinfo is None:
        return ts.replace(tzinfo=UTC)
    return ts.astimezone(UTC)


def _timestamp_from_epoch(epoch: Optional[float]) -> Optional[datetime]:
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=UTC)


def _serialize_people(people: Sequence[DocumentPerson]) -> List[Dict[str, Any]]:
    return [person.model_dump(mode='json', exclude_none=True) for person in people]


def _serialize_thread(thread: Optional[ThreadPayloadModel]) -> Optional[Dict[str, Any]]:
    if thread is None:
        return None
    payload = thread.model_dump(mode='json', exclude_none=True)
    if participants := payload.get("participants"):
        payload["participants"] = [
            participant for participant in participants if participant  # already dict
        ]
    return payload


def _map_catalog_ingest_response(data: Dict[str, Any]) -> IngestSubmissionResponse:
    file_ids = [str(fid) for fid in data.get("file_ids", [])]
    return IngestSubmissionResponse(
        submission_id=str(data["submission_id"]),
        doc_id=str(data["doc_id"]),
        external_id=data.get("external_id", ""),
        version_number=int(data.get("version_number", 1)),
        status=data.get("status", "submitted"),
        thread_id=str(data["thread_id"]) if data.get("thread_id") else None,
        file_ids=file_ids,
        duplicate=bool(data.get("duplicate", False)),
        total_chunks=int(data.get("total_chunks") or 0),
    )


def _parse_iso_datetime(value: Optional[str], *, param: str) -> Optional[datetime]:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid {param} value; expected ISO-8601",
        ) from exc
    return _ensure_utc(dt)


def _make_correlation_id(prefix: str) -> str:
    now = datetime.now(tz=UTC).isoformat()
    return f"{prefix}_{now}_{uuid.uuid4().hex[:8]}"


def _error_response(
    status_code: int,
    error_code: str,
    message: str,
    correlation_id: str,
    *,
    retryable: bool = False,
    details: Optional[Dict[str, Any]] = None,
) -> JSONResponse:
    envelope = ErrorEnvelope(
        error_code=error_code,
        message=message,
        retryable=retryable,
        correlation_id=correlation_id,
        details=details or {},
    )
    return JSONResponse(
        status_code=status_code,
        content=envelope.model_dump(),
        headers={"X-Correlation-ID": correlation_id},
    )


def _truncate_response(response: httpx.Response, limit: int = 200) -> str:
    try:
        text = response.text
    except Exception:
        return "<unavailable>"
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def _extract_text(content: IngestContentModel) -> str:
    mime = content.mime_type.lower()
    if mime in SUPPORTED_TEXT_MIME_TYPES:
        if content.encoding and content.encoding.lower() == "base64":
            try:
                decoded = base64.b64decode(content.data)
            except Exception as exc:
                raise HTTPException(
                    status.HTTP_400_BAD_REQUEST,
                    detail=f"Failed to decode base64 payload: {exc}",
                ) from exc
            try:
                return decoded.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise HTTPException(
                    status.HTTP_400_BAD_REQUEST,
                    detail="Base64 payload is not valid UTF-8",
                ) from exc
        return content.data
    raise HTTPException(
        status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
        detail=f"Unsupported MIME type: {content.mime_type}",
    )


def _prepare_ingest_document_payload(
    payload: IngestRequestModel,
) -> PreparedIngestDocument:
    try:
        raw_text = _extract_text(payload.content)
    except HTTPException as exc:
        raise IngestPreparationError(
            exc.status_code,
            "INGEST.EXTRACTION_FAILED",
            str(exc.detail),
            retryable=False,
        ) from exc

    text_normalized = _normalize_ingest_text(raw_text)
    if not text_normalized:
        raise IngestPreparationError(
            status.HTTP_400_BAD_REQUEST,
            "INGEST.EMPTY_TEXT",
            "Document text empty after extraction",
        )

    text_hash = _compute_sha256(text_normalized)
    idempotency_key = _build_idempotency_key(
        payload.source_type, payload.source_id, text_hash
    )

    content_timestamp = _ensure_utc(payload.content_timestamp) or datetime.now(tz=UTC)
    if payload.content_timestamp_type:
        content_timestamp_type = payload.content_timestamp_type.lower()
    else:
        content_timestamp_type = (
            "sent" if payload.source_type in DEFAULT_SENT_SOURCES else "created"
        )

    if content_timestamp_type not in ALLOWED_TIMESTAMP_TYPES:
        raise IngestPreparationError(
            status.HTTP_400_BAD_REQUEST,
            "INGEST.INVALID_TIMESTAMP_TYPE",
            "Invalid content_timestamp_type",
            details={"value": payload.content_timestamp_type},
        )

    content_created_at = _ensure_utc(payload.content_created_at)
    content_modified_at = _ensure_utc(payload.content_modified_at)
    people_payload = _serialize_people(payload.people)
    thread_payload = _serialize_thread(payload.thread)

    catalog_payload: Dict[str, Any] = {
        "idempotency_key": idempotency_key,
        "source_type": payload.source_type,
        "source_provider": payload.source_provider,
        "source_id": payload.source_id,
        "content_sha256": text_hash,
        "mime_type": payload.content.mime_type,
        "text": text_normalized,
        "title": payload.title,
        "canonical_uri": payload.canonical_uri,
        "metadata": payload.metadata,
        "content_timestamp": content_timestamp.isoformat(),
        "content_timestamp_type": content_timestamp_type,
        "people": people_payload,
    }

    if payload.external_id:
        catalog_payload["external_id"] = payload.external_id

    if payload.content_created_at or content_created_at:
        catalog_payload["content_created_at"] = (
            content_created_at or content_timestamp
        ).isoformat()
    if payload.content_modified_at or content_modified_at:
        catalog_payload["content_modified_at"] = (
            content_modified_at or content_timestamp
        ).isoformat()
    if payload.thread_id:
        catalog_payload["thread_id"] = str(payload.thread_id)
    if thread_payload:
        catalog_payload["thread"] = thread_payload

    return PreparedIngestDocument(payload=catalog_payload, content_sha256=text_hash)


async def _catalog_request(
    method: str,
    path: str,
    correlation_id: str,
    *,
    json_payload: Optional[Dict[str, Any]] = None,
) -> httpx.Response:
    headers: Dict[str, str] = {"X-Correlation-ID": correlation_id}
    if settings.catalog_token:
        headers["Authorization"] = f"Bearer {settings.catalog_token}"
    async with httpx.AsyncClient(
        base_url=settings.catalog_base_url,
        timeout=CATALOG_TIMEOUT_SECONDS,
    ) as client:
        return await client.request(method, path, json=json_payload, headers=headers)


def _get_minio_client() -> Minio:
    global _minio_client
    if _minio_client is None:
        if not settings.minio_endpoint:
            raise RuntimeError("MINIO_ENDPOINT not configured")
        if not settings.minio_access_key or not settings.minio_secret_key:
            raise RuntimeError("MINIO credentials not configured")
        _minio_client = Minio(
            settings.minio_endpoint,
            access_key=settings.minio_access_key,
            secret_key=settings.minio_secret_key,
            secure=settings.minio_secure,
        )
    return _minio_client


def _ensure_minio_bucket(client: Minio) -> None:
    global _minio_bucket_checked
    if _minio_bucket_checked:
        return
    try:
        if not client.bucket_exists(settings.minio_bucket):
            client.make_bucket(settings.minio_bucket)
    except S3Error as exc:
        if exc.code not in {"BucketAlreadyOwnedByYou", "BucketAlreadyExists"}:
            raise
    _minio_bucket_checked = True


def _build_object_key(file_sha: str, suffix: str) -> str:
    suffix_clean = suffix.lower().lstrip(".")
    if suffix_clean:
        return f"{file_sha}/{file_sha}.{suffix_clean}"
    return f"{file_sha}/{file_sha}"


def _resolve_filename(meta: LocalFileMeta, upload_name: Optional[str]) -> str:
    if meta.filename:
        return meta.filename
    if upload_name:
        return upload_name
    if meta.path:
        return Path(meta.path).name or "document"
    return "document"


def _resolve_suffix(filename: str, path_value: str) -> str:
    for candidate in (filename, path_value):
        if not candidate:
            continue
        suffix = Path(candidate).suffix
        if suffix:
            return suffix.lower()
    return ""


def _guess_content_type(filename: str, provided: Optional[str]) -> str:
    if provided:
        return provided
    mime, _ = mimetypes.guess_type(filename)
    if mime:
        return mime
    return "application/octet-stream"


def _format_mtime(value: Optional[Any]) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(float(value), tz=UTC).isoformat()
        except (ValueError, OSError):
            return None
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=UTC)
            return parsed.astimezone(UTC).isoformat()
        except ValueError:
            return value
    return None


def _extract_text_for_localfs(
    file_sha: str,
    suffix: str,
    file_bytes: bytes,
    temp_dir: Path,
    filename: str,
) -> FileExtractionResult:
    normalized_suffix = suffix.lower()
    if normalized_suffix in {".txt", ".md"}:
        try:
            decoded = file_bytes.decode("utf-8")
        except UnicodeDecodeError:
            decoded = file_bytes.decode("utf-8", errors="replace")
        text = decoded.strip()
        if text:
            return FileExtractionResult(
                text=text,
                status="ready",
                metadata={"detected_encoding": "utf-8"},
            )
        return FileExtractionResult(
            text=f"{FILE_PLACEHOLDER_TEXT}\n\nNo extractable text found.",
            status="failed",
            metadata={"reason": "empty_text"},
        )

    if normalized_suffix == ".pdf":
        pdf_path = temp_dir / f"{file_sha}.pdf"
        pdf_path.write_bytes(file_bytes)
        try:
            extracted = pdf_extract_text(str(pdf_path))
        except Exception as exc:  # pragma: no cover - depends on pdfminer internals
            logger.warning(
                "pdf_extract_failed",
                filename=filename,
                error=str(exc),
            )
            return FileExtractionResult(
                text=f"{FILE_PLACEHOLDER_TEXT}\n\nUnable to extract text from PDF.",
                status="failed",
                metadata={"reason": "pdf_extract_failed"},
                error={"type": "pdf_extract_failed", "message": str(exc)},
            )
        pages = extracted.count("\f") + 1 if extracted else 0
        cleaned = extracted.replace("\f", "\n").strip()
        if cleaned:
            metadata = {"pages": pages if pages > 0 else None}
            return FileExtractionResult(
                text=cleaned,
                status="ready",
                metadata=metadata,
            )
        return FileExtractionResult(
            text=f"{FILE_PLACEHOLDER_TEXT}\n\nNo extractable text found in PDF.",
            status="failed",
            metadata={"reason": "pdf_no_text"},
        )

    if normalized_suffix in {".png", ".jpg", ".jpeg", ".heic"}:
        # Images are now enriched by collectors; gateway just passes through placeholder
        return FileExtractionResult(
            text=IMAGE_PLACEHOLDER_TEXT,
            status="ready",
            metadata={"reason": "image_handled_by_collector"},
        )

    return FileExtractionResult(
        text=f"{FILE_PLACEHOLDER_TEXT}\n\nNo automated extraction available for {normalized_suffix or 'binary'} files.",
        status="failed",
        metadata={
            "reason": "unsupported_type",
            "extension": normalized_suffix or "unknown",
        },
    )


def _build_document_text(
    meta: LocalFileMeta, extracted_text: str, filename: str
) -> str:
    lines: List[str] = []
    display_name = filename or "document"
    lines.append(f"Filename: {display_name}")
    if meta.path:
        lines.append(f"Source Path: {meta.path}")
    mtime_iso = _format_mtime(meta.mtime)
    if mtime_iso:
        lines.append(f"Modified: {mtime_iso}")
    if meta.tags:
        lines.append("Tags: " + ", ".join(meta.tags))
    
    # Check if collector provided image enrichment
    image_data = getattr(meta, "image", None) or {}
    if image_data and isinstance(image_data, dict):
        caption = (image_data.get("caption") or "").strip()
        ocr_text = (image_data.get("ocr_text") or "").strip()
        
        if caption or ocr_text:
            lines.append("")
            if caption:
                lines.append(f"Caption: {caption}")
            if ocr_text:
                lines.append(f"OCR:\n{ocr_text}")
            return "\n".join(line for line in lines if line).strip()
    
    lines.append("")
    lines.append(extracted_text.strip() or FILE_PLACEHOLDER_TEXT)
    return "\n".join(line for line in lines if line).strip()


def _build_localfs_metadata(
    meta: LocalFileMeta,
    filename: str,
    file_sha: str,
    object_key: str,
    size_bytes: int,
    content_type: str,
    extraction: FileExtractionResult,
) -> Dict[str, Any]:
    base_meta = meta.model_dump(exclude_none=True)
    localfs_meta = {
        "path": meta.path,
        "filename": filename,
        "tags": meta.tags,
    }
    mtime_iso = _format_mtime(meta.mtime)
    if mtime_iso:
        localfs_meta["mtime"] = mtime_iso

    extras = {
        k: v
        for k, v in base_meta.items()
        if k not in {"source", "path", "filename", "mtime", "tags", "image"}
    }
    if extras:
        localfs_meta["extra"] = extras

    metadata: Dict[str, Any] = {
        "source": meta.source or "localfs",
        "localfs": localfs_meta,
        "file": {
            "sha256": file_sha,
            "object_key": object_key,
            "size_bytes": size_bytes,
            "content_type": content_type,
        },
        "extraction": {
            "status": extraction.status,
            **(extraction.metadata or {}),
        },
        "ingested_at": datetime.now(tz=UTC).isoformat(),
    }
    if extraction.error:
        metadata["extraction"]["error"] = extraction.error
    
    # Include image enrichment from collector if provided
    image_data = getattr(meta, "image", None)
    if image_data and isinstance(image_data, dict):
        metadata["image"] = {
            k: v
            for k, v in image_data.items()
            if v is not None
        }
    
    return metadata


def require_token(request: Request) -> None:
    if not settings.api_token:
        return
    header = request.headers.get("Authorization")
    if not header or not header.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing token"
        )
    token = header.split(" ", 1)[1]
    if token != settings.api_token:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Invalid token"
        )


def require_catalog_token(request: Request) -> None:
    catalog_token = settings.catalog_token
    if not catalog_token:
        return
    header = request.headers.get("Authorization")
    if not header or not header.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing catalog token"
        )
    token = header.split(" ", 1)[1]
    if token != catalog_token:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Invalid catalog token"
        )


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
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Contacts helper not configured",
        )

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
            with httpx.stream(
                "GET", url, params=params, headers=headers, timeout=30.0
            ) as resp:
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
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Failed to proxy contacts export",
        )


@app.post("/catalog/contacts/ingest", response_model=ContactIngestResponse)
def ingest_contacts(
    payload: ContactIngestRequest,
    _: None = Depends(require_catalog_token),
) -> ContactIngestResponse:
    source = payload.source or CONTACT_SOURCE_DEFAULT

    records = [person.to_record() for person in payload.people]
    next_token = _resolve_next_token(payload.since_token, records)

    accepted = 0
    upserts = 0
    deletes = 0
    conflicts = 0
    skipped = 0

    if not records:
        with get_connection(autocommit=False) as conn:
            _update_change_token(conn, source, payload.device_id, next_token)
            conn.commit()
        return ContactIngestResponse(
            accepted=accepted,
            upserts=upserts,
            deletes=deletes,
            conflicts=conflicts,
            skipped=skipped,
            since_token_next=next_token,
        )

    for record in records:
        accepted += 1
        external_id = _contact_external_id(source, record)
        correlation_id = _make_correlation_id("gw_contact")
        if record.deleted:
            doc = get_active_document(external_id)
            if not doc:
                skipped += 1
                continue
            response = _catalog_sync_request(
                "DELETE",
                f"/v1/catalog/documents/{doc.doc_id}",
                correlation_id,
            )
            if response.status_code in (status.HTTP_200_OK, status.HTTP_202_ACCEPTED):
                deletes += 1
            else:
                conflicts += 1
                logger.warning(
                    "contact_delete_failed",
                    doc_id=str(doc.doc_id),
                    status_code=response.status_code,
                    body=_truncate_response(response),
                )
            continue

        payload_dict = _build_contact_document_payload(source, record)
        response = _catalog_sync_request(
            "POST",
            "/v1/catalog/documents",
            correlation_id,
            json_payload=payload_dict,
        )
        if response.status_code not in (status.HTTP_200_OK, status.HTTP_202_ACCEPTED):
            conflicts += 1
            logger.warning(
                "contact_upsert_failed",
                external_id=external_id,
                status_code=response.status_code,
                body=_truncate_response(response),
            )
            continue

        try:
            body = response.json()
        except Exception:
            body = {}
        if body.get("duplicate"):
            skipped += 1
        else:
            upserts += 1

    with get_connection(autocommit=False) as conn:
        try:
            _update_change_token(conn, source, payload.device_id, next_token)
            conn.commit()
        except Exception:
            conn.rollback()
            logger.exception(
                "contacts_token_update_failed",
                source=source,
                device_id=payload.device_id,
            )
            raise

    return ContactIngestResponse(
        accepted=accepted,
        upserts=upserts,
        deletes=deletes,
        conflicts=conflicts,
        skipped=skipped,
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


@app.post(
    "/v1/ingest:batch",
    response_model=BatchIngestResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def ingest_documents_batch(
    payload: BatchIngestRequest,
    response: Response,
    _: None = Depends(require_token),
) -> BatchIngestResponse:
    batch_correlation_id = _make_correlation_id("gw_ingest_batch")
    response.headers["X-Correlation-ID"] = batch_correlation_id

    if not payload.documents:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            detail="Batch documents payload must include at least one document",
        )

    total_documents = len(payload.documents)
    results_map: Dict[int, BatchIngestItemResult] = {}
    prepared_items: List[PreparedBatchItem] = []
    batch_id: Optional[str] = None
    batch_status: Optional[str] = None
    catalog_total: Optional[int] = None
    catalog_success: Optional[int] = None
    catalog_failure: Optional[int] = None

    for index, document in enumerate(payload.documents):
        item_correlation_id = f"{batch_correlation_id}:{index}"
        try:
            prepared = _prepare_ingest_document_payload(document)
        except IngestPreparationError as exc:
            results_map[index] = BatchIngestItemResult(
                index=index,
                status_code=exc.status_code,
                error=ErrorEnvelope(
                    error_code=exc.error_code,
                    message=exc.message,
                    retryable=exc.retryable,
                    correlation_id=item_correlation_id,
                    details=exc.details,
                ),
            )
            continue

        prepared_items.append(
            PreparedBatchItem(
                index=index,
                payload=prepared.payload,
                content_sha256=prepared.content_sha256,
                correlation_id=item_correlation_id,
            )
        )

    if prepared_items:
        request_payload = {"documents": [item.payload for item in prepared_items]}
        idempotency_keys = [
            item.payload.get("idempotency_key")
            for item in prepared_items
            if item.payload.get("idempotency_key")
        ]
        if idempotency_keys:
            request_payload["batch_idempotency_key"] = _derive_batch_idempotency_key(idempotency_keys)
        try:
            catalog_resp = await _catalog_request(
                "POST",
                "/v1/catalog/documents/batch",
                batch_correlation_id,
                json_payload=request_payload,
            )
        except httpx.HTTPError as exc:
            for item in prepared_items:
                results_map[item.index] = BatchIngestItemResult(
                    index=item.index,
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    content_sha256=item.content_sha256,
                    error=ErrorEnvelope(
                        error_code="INGEST.CATALOG_UNAVAILABLE",
                        message="Catalog service unavailable",
                        retryable=True,
                        correlation_id=item.correlation_id,
                        details={"error": str(exc)},
                    ),
                )
        else:
            if catalog_resp.status_code not in (
                status.HTTP_200_OK,
                status.HTTP_202_ACCEPTED,
                status.HTTP_207_MULTI_STATUS,
            ):
                try:
                    body = catalog_resp.json()
                except Exception:
                    body = catalog_resp.text
                for item in prepared_items:
                    results_map[item.index] = BatchIngestItemResult(
                        index=item.index,
                        status_code=catalog_resp.status_code,
                        content_sha256=item.content_sha256,
                        error=ErrorEnvelope(
                            error_code="INGEST.CATALOG_ERROR",
                            message="Catalog rejected ingest request",
                            retryable=catalog_resp.status_code >= 500,
                            correlation_id=item.correlation_id,
                            details={"status_code": catalog_resp.status_code, "body": body},
                        ),
                    )
            else:
                try:
                    payload_json = catalog_resp.json()
                except Exception as exc:  # pragma: no cover - defensive
                    for item in prepared_items:
                        results_map[item.index] = BatchIngestItemResult(
                            index=item.index,
                            status_code=status.HTTP_502_BAD_GATEWAY,
                            content_sha256=item.content_sha256,
                            error=ErrorEnvelope(
                                error_code="INGEST.CATALOG_ERROR",
                                message="Catalog returned invalid response",
                                retryable=True,
                                correlation_id=item.correlation_id,
                                details={"error": str(exc)},
                            ),
                        )
                else:
                    if payload_json.get("batch_id"):
                        batch_id = str(payload_json["batch_id"])
                    if payload_json.get("batch_status"):
                        batch_status = str(payload_json["batch_status"])
                    if "total_count" in payload_json:
                        catalog_total = payload_json["total_count"]
                    if "success_count" in payload_json:
                        catalog_success = payload_json["success_count"]
                    if "failure_count" in payload_json:
                        catalog_failure = payload_json["failure_count"]

                    catalog_results = payload_json.get("results", [])
                    result_lookup: Dict[int, Dict[str, Any]] = {}
                    for entry in catalog_results:
                        if not isinstance(entry, dict):
                            continue
                        idx = entry.get("index")
                        if idx is None:
                            continue
                        try:
                            result_lookup[int(idx)] = entry or {}
                        except (TypeError, ValueError):
                            continue

                    for item in prepared_items:
                        entry = result_lookup.get(item.index)
                        if entry is None:
                            results_map[item.index] = BatchIngestItemResult(
                                index=item.index,
                                status_code=status.HTTP_502_BAD_GATEWAY,
                                content_sha256=item.content_sha256,
                                error=ErrorEnvelope(
                                    error_code="INGEST.CATALOG_ERROR",
                                    message="Catalog returned mismatched batch result index",
                                    retryable=True,
                                    correlation_id=item.correlation_id,
                                    details={"index": item.index, "catalog_indexes": list(result_lookup.keys())},
                                ),
                            )
                            continue

                        status_code = int(entry.get("status_code", catalog_resp.status_code))
                        document_payload = entry.get("document")
                        if document_payload:
                            submission = _map_catalog_ingest_response(document_payload)
                            results_map[item.index] = BatchIngestItemResult(
                                index=item.index,
                                status_code=status_code,
                                content_sha256=item.content_sha256,
                                submission=submission,
                            )
                            continue

                        error_info = entry.get("error") or {}
                        message = error_info.get("message", "Catalog rejected ingest request")
                        error_code = error_info.get("code", "INGEST.CATALOG_ERROR")
                        details = error_info.get("details") or {}
                        results_map[item.index] = BatchIngestItemResult(
                            index=item.index,
                            status_code=status_code,
                            content_sha256=item.content_sha256,
                            error=ErrorEnvelope(
                                error_code=error_code,
                                message=message,
                                retryable=status_code >= 500,
                                correlation_id=item.correlation_id,
                                details=details,
                            ),
                        )

    results: List[BatchIngestItemResult] = []
    for idx in range(total_documents):
        result = results_map.get(idx)
        if result is None:
            result = BatchIngestItemResult(
                index=idx,
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                error=ErrorEnvelope(
                    error_code="INGEST.UNKNOWN_ERROR",
                    message="No result available for batch document",
                    retryable=True,
                    correlation_id=f"{batch_correlation_id}:{idx}",
                    details={},
                ),
            )
        results.append(result)

    computed_success = sum(1 for item in results if item.submission is not None)
    computed_failure = total_documents - computed_success

    try:
        success_count = int(catalog_success) if catalog_success is not None else computed_success
    except (TypeError, ValueError):
        success_count = computed_success

    try:
        failure_count = int(catalog_failure) if catalog_failure is not None else computed_failure
    except (TypeError, ValueError):
        failure_count = computed_failure

    try:
        total_count = int(catalog_total) if catalog_total is not None else total_documents
    except (TypeError, ValueError):
        total_count = total_documents

    response.status_code = (
        status.HTTP_202_ACCEPTED
        if failure_count == 0
        else status.HTTP_207_MULTI_STATUS
    )

    return BatchIngestResponse(
        batch_id=batch_id,
        batch_status=batch_status,
        total_count=total_count,
        success_count=success_count,
        failure_count=failure_count,
        results=results,
    )


@app.post(
    "/v1/ingest",
    response_model=IngestSubmissionResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def ingest_document(
    payload: IngestRequestModel,
    response: Response,
    _: None = Depends(require_token),
) -> IngestSubmissionResponse | JSONResponse:
    correlation_id = _make_correlation_id("gw_ingest")
    response.headers["X-Correlation-ID"] = correlation_id

    try:
        prepared = _prepare_ingest_document_payload(payload)
    except IngestPreparationError as exc:
        return _error_response(
            exc.status_code,
            exc.error_code,
            exc.message,
            correlation_id,
            retryable=exc.retryable,
            details=exc.details,
        )

    catalog_payload = prepared.payload
    text_hash = prepared.content_sha256

    try:
        catalog_resp = await _catalog_request(
            "POST",
            "/v1/catalog/documents",
            correlation_id,
            json_payload=catalog_payload,
        )
    except httpx.HTTPError as exc:
        logger.error(
            "catalog_request_failed",
            correlation_id=correlation_id,
            error=str(exc),
        )
        return _error_response(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "INGEST.CATALOG_UNAVAILABLE",
            "Catalog service unavailable",
            correlation_id,
            retryable=True,
            details={"error": str(exc)},
        )

    if catalog_resp.status_code not in (status.HTTP_200_OK, status.HTTP_202_ACCEPTED):
        try:
            body = catalog_resp.json()
        except Exception:
            body = catalog_resp.text
        logger.warning(
            "catalog_rejected_ingest",
            correlation_id=correlation_id,
            status_code=catalog_resp.status_code,
            body=body,
        )
        return _error_response(
            catalog_resp.status_code,
            "INGEST.CATALOG_ERROR",
            "Catalog rejected ingest request",
            correlation_id,
            retryable=catalog_resp.status_code >= 500,
            details={"status_code": catalog_resp.status_code, "body": body},
        )

    payload_json = catalog_resp.json()
    response.status_code = catalog_resp.status_code
    response.headers["X-Content-SHA256"] = text_hash
    submission = _map_catalog_ingest_response(payload_json)
    logger.info(
        "ingest_submitted",
        submission_id=submission.submission_id,
        doc_id=submission.doc_id,
        source_type=payload.source_type,
        duplicate=submission.duplicate,
    )
    return submission


@app.post(
    "/v1/ingest/file",
    response_model=FileIngestResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def ingest_file(
    response: Response,
    meta: str = Form(...),
    upload: UploadFile = File(...),
    _: None = Depends(require_token),
) -> FileIngestResponse | JSONResponse:
    correlation_id = _make_correlation_id("gw_file_ingest")
    response.headers["X-Correlation-ID"] = correlation_id

    try:
        meta_payload = LocalFileMeta.model_validate_json(meta)
    except ValidationError as exc:
        logger.warning("localfs_meta_invalid", errors=exc.errors())
        return _error_response(
            status.HTTP_400_BAD_REQUEST,
            "INGEST.INVALID_META",
            "Invalid meta payload",
            correlation_id,
            details={"errors": exc.errors()},
        )

    try:
        file_bytes = await upload.read()
    except Exception as exc:
        logger.error("localfs_file_read_failed", error=str(exc))
        return _error_response(
            status.HTTP_500_INTERNAL_SERVER_ERROR,
            "INGEST.FILE_READ_FAILED",
            "Failed to read uploaded file",
            correlation_id,
        )

    if not file_bytes:
        return _error_response(
            status.HTTP_400_BAD_REQUEST,
            "INGEST.EMPTY_FILE",
            "Uploaded file is empty",
            correlation_id,
        )

    file_sha = hashlib.sha256(file_bytes).hexdigest()
    source_type = "localfs"
    filename = _resolve_filename(meta_payload, upload.filename)
    suffix = _resolve_suffix(filename, meta_payload.path)
    lower_suffix = suffix.lower()
    if lower_suffix and lower_suffix not in SUPPORTED_LOCALFS_EXTENSIONS:
        logger.info(
            "localfs_unsupported_extension",
            suffix=lower_suffix,
            filename=filename,
        )

    content_type = _guess_content_type(filename, upload.content_type)
    object_key = _build_object_key(file_sha, suffix)

    try:
        client = _get_minio_client()
        _ensure_minio_bucket(client)
        object_exists = False
        try:
            client.stat_object(settings.minio_bucket, object_key)
            object_exists = True
        except S3Error as exc:
            if (
                exc.code not in {"NoSuchKey", "NoSuchObject", "NoSuchEntity"}
                and exc.status != 404
            ):
                logger.error(
                    "minio_stat_failed",
                    bucket=settings.minio_bucket,
                    object_key=object_key,
                    error=exc.code or str(exc),
                )
                return _error_response(
                    status.HTTP_503_SERVICE_UNAVAILABLE,
                    "INGEST.OBJECT_STORE_UNAVAILABLE",
                    "Object store unavailable",
                    correlation_id,
                    retryable=True,
                    details={"error": exc.code or str(exc)},
                )

        if not object_exists:
            try:
                stream = io.BytesIO(file_bytes)
                stream.seek(0)
                client.put_object(
                    settings.minio_bucket,
                    object_key,
                    stream,
                    length=len(file_bytes),
                    content_type=content_type,
                )
                logger.info(
                    "gateway_minio_put",
                    object_key=object_key,
                    bucket=settings.minio_bucket,
                    size=len(file_bytes),
                )
            except S3Error as exc:
                logger.error(
                    "minio_put_failed",
                    bucket=settings.minio_bucket,
                    object_key=object_key,
                    error=exc.code or str(exc),
                )
                return _error_response(
                    status.HTTP_503_SERVICE_UNAVAILABLE,
                    "INGEST.OBJECT_STORE_WRITE_FAILED",
                    "Failed to store file",
                    correlation_id,
                    retryable=True,
                    details={"error": exc.code or str(exc)},
                )
    except Exception as exc:
        logger.error("minio_client_error", error=str(exc))
        return _error_response(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "INGEST.OBJECT_STORE_UNAVAILABLE",
            "Object store unavailable",
            correlation_id,
            retryable=True,
            details={"error": str(exc)},
        )

    with tempfile.TemporaryDirectory() as tmpdir:
        extraction = _extract_text_for_localfs(
            file_sha=file_sha,
            suffix=suffix,
            file_bytes=file_bytes,
            temp_dir=Path(tmpdir),
            filename=filename,
        )

    document_text = _build_document_text(meta_payload, extraction.text, filename)
    metadata = _build_localfs_metadata(
        meta=meta_payload,
        filename=filename,
        file_sha=file_sha,
        object_key=object_key,
        size_bytes=len(file_bytes),
        content_type=content_type,
        extraction=extraction,
    )

    content_timestamp = _timestamp_from_epoch(meta_payload.mtime) or datetime.now(tz=UTC)
    content_created_at = _timestamp_from_epoch(meta_payload.ctime)

    file_descriptor: Dict[str, Any] = {
        "content_sha256": file_sha,
        "object_key": object_key,
        "storage_backend": "minio",
        "filename": filename,
        "mime_type": content_type,
        "size_bytes": len(file_bytes),
        "enrichment_status": "pending",
    }
    if extraction.metadata:
        file_descriptor["enrichment"] = extraction.metadata
    if extraction.status == "failed":
        file_descriptor["enrichment_status"] = "failed"

    attachments: List[Dict[str, Any]] = [
        {
            "role": "attachment",
            "attachment_index": 0,
            "filename": filename,
            "file": file_descriptor,
        }
    ]

    catalog_payload: Dict[str, Any] = {
        "idempotency_key": f"localfs:{file_sha}",
        "source_type": source_type,
        "source_provider": "filesystem",
        "source_id": meta_payload.path,
        "external_id": f"localfs:{file_sha}",
        "content_sha256": file_sha,
        "mime_type": content_type,
        "text": document_text,
        "title": filename,
        "metadata": metadata,
        "content_timestamp": content_timestamp.isoformat(),
        "content_timestamp_type": "modified",
        "content_created_at": content_created_at.isoformat() if content_created_at else None,
        "content_modified_at": content_timestamp.isoformat(),
        "people": [],
        "attachments": attachments,
        "facet_overrides": {
            "has_attachments": True,
            "attachment_count": len(attachments),
        },
    }
    if catalog_payload.get("content_created_at") is None:
        catalog_payload.pop("content_created_at")

    try:
        catalog_resp = await _catalog_request(
            "POST",
            "/v1/catalog/documents",
            correlation_id,
            json_payload=catalog_payload,
        )
    except httpx.HTTPError as exc:
        logger.error(
            "catalog_request_failed",
            correlation_id=correlation_id,
            error=str(exc),
        )
        return _error_response(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "INGEST.CATALOG_UNAVAILABLE",
            "Catalog service unavailable",
            correlation_id,
            retryable=True,
            details={"error": str(exc)},
        )

    if catalog_resp.status_code not in (status.HTTP_200_OK, status.HTTP_202_ACCEPTED):
        try:
            body = catalog_resp.json()
        except Exception:
            body = catalog_resp.text
        logger.warning(
            "catalog_rejected_ingest",
            correlation_id=correlation_id,
            status_code=catalog_resp.status_code,
            body=body,
        )
        return _error_response(
            catalog_resp.status_code,
            "INGEST.CATALOG_ERROR",
            "Catalog rejected ingest request",
            correlation_id,
            retryable=catalog_resp.status_code >= 500,
            details={"status_code": catalog_resp.status_code, "body": body},
        )

    payload_json = catalog_resp.json()
    submission = _map_catalog_ingest_response(payload_json)
    response.status_code = catalog_resp.status_code
    response.headers["X-File-SHA256"] = file_sha
    response.headers["X-Content-SHA256"] = file_sha
    response.headers["X-Object-Key"] = object_key

    file_response = FileIngestResponse(
        **submission.model_dump(),
        file_sha256=file_sha,
        object_key=object_key,
        extraction_status=extraction.status,
    )
    logger.info(
        "localfs_ingest_submitted",
        doc_id=file_response.doc_id,
        submission_id=file_response.submission_id,
        duplicate=file_response.duplicate,
        extraction_status=extraction.status,
    )
    return file_response


@app.get("/v1/ingest/{submission_id}", response_model=IngestStatusResponse)
async def get_ingest_status(
    submission_id: str,
    response: Response,
    _: None = Depends(require_token),
) -> IngestStatusResponse | JSONResponse:
    correlation_id = _make_correlation_id("gw_status")
    response.headers["X-Correlation-ID"] = correlation_id

    try:
        catalog_resp = await _catalog_request(
            "GET",
            f"/v1/catalog/submissions/{submission_id}",
            correlation_id,
        )
    except httpx.HTTPError as exc:
        logger.error(
            "catalog_status_failed",
            correlation_id=correlation_id,
            error=str(exc),
        )
        return _error_response(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "INGEST.CATALOG_UNAVAILABLE",
            "Catalog service unavailable",
            correlation_id,
            retryable=True,
            details={"error": str(exc)},
        )

    if catalog_resp.status_code != status.HTTP_200_OK:
        try:
            body = catalog_resp.json()
        except Exception:
            body = catalog_resp.text
        return _error_response(
            catalog_resp.status_code,
            "INGEST.STATUS_ERROR",
            "Catalog could not provide submission status",
            correlation_id,
            retryable=catalog_resp.status_code >= 500,
            details={"status_code": catalog_resp.status_code, "body": body},
        )

    payload_json = catalog_resp.json()
    status_payload = IngestStatusResponse(
        submission_id=str(payload_json.get("submission_id")),
        status=payload_json.get("status", ""),
        document_status=payload_json.get("document_status"),
        doc_id=str(payload_json["doc_id"]) if payload_json.get("doc_id") else None,
        total_chunks=int(payload_json.get("total_chunks") or 0),
        embedded_chunks=int(payload_json.get("embedded_chunks") or 0),
        pending_chunks=int(payload_json.get("pending_chunks") or 0),
        error=payload_json.get("error"),
    )
    return status_payload


class DocumentUpdateRequest(BaseModel):
    metadata: Dict[str, Any]
    text: str
    requeue_for_embedding: bool = True


class DocumentUpdateResponse(BaseModel):
    doc_id: str
    status: str
    chunks_requeued: int = 0


@app.patch("/v1/documents/{doc_id}", response_model=DocumentUpdateResponse)
async def update_document(
    doc_id: str,
    payload: DocumentUpdateRequest,
    response: Response,
    _: None = Depends(require_token),
) -> DocumentUpdateResponse | JSONResponse:
    """Update a document's metadata and text, optionally re-queuing for embedding."""
    correlation_id = _make_correlation_id("gw_update")
    response.headers["X-Correlation-ID"] = correlation_id

    try:
        uuid.UUID(doc_id)
    except ValueError:
        return _error_response(
            status.HTTP_400_BAD_REQUEST,
            "UPDATE.INVALID_DOC_ID",
            "doc_id must be a valid UUID",
            correlation_id,
        )

    catalog_payload = {
        "metadata": payload.metadata,
        "text": payload.text,
        "requeue_for_embedding": payload.requeue_for_embedding,
    }

    try:
        catalog_resp = await _catalog_request(
            "PATCH",
            f"/v1/catalog/documents/{doc_id}",
            correlation_id,
            json_payload=catalog_payload,
        )
    except httpx.HTTPError as exc:
        logger.error(
            "catalog_update_failed",
            correlation_id=correlation_id,
            doc_id=doc_id,
            error=str(exc),
        )
        return _error_response(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "UPDATE.CATALOG_UNAVAILABLE",
            "Catalog service unavailable",
            correlation_id,
            retryable=True,
            details={"error": str(exc)},
        )

    if catalog_resp.status_code != status.HTTP_200_OK:
        try:
            body = catalog_resp.json()
        except Exception:
            body = catalog_resp.text
        return _error_response(
            catalog_resp.status_code,
            "UPDATE.CATALOG_ERROR",
            "Catalog rejected update request",
            correlation_id,
            retryable=catalog_resp.status_code >= 500,
            details={"status_code": catalog_resp.status_code, "body": body},
        )

    payload_json = catalog_resp.json()
    return DocumentUpdateResponse(**payload_json)


class DocumentListItem(BaseModel):
    doc_id: str
    metadata: Dict[str, Any]
    text: str


class DocumentListResponse(BaseModel):
    documents: List[DocumentListItem]
    count: int


@app.get("/v1/documents", response_model=DocumentListResponse)
async def list_documents(
    source_type: Optional[str] = Query(None),
    has_attachments: bool = Query(False),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    _: None = Depends(require_token),
) -> DocumentListResponse:
    """List documents with optional filtering."""
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            conditions = []
            params: List[Any] = []

            if source_type:
                # Support both direct source_type field and thread.kind field (for iMessage)
                if source_type == "imessage":
                    conditions.append("metadata->'thread'->>'kind' = %s")
                else:
                    conditions.append("metadata->>'source_type' = %s")
                params.append(source_type)

            if has_attachments:
                conditions.append(
                    """
                    metadata->'message'->'attrs'->'attachment_count' IS NOT NULL
                    AND (metadata->'message'->'attrs'->>'attachment_count')::int > 0
                """
                )

            where_clause = ""
            if conditions:
                where_clause = "WHERE " + " AND ".join(conditions)

            query = f"""
                SELECT doc_id, metadata, text
                FROM documents
                {where_clause}
                ORDER BY doc_id
                LIMIT %s OFFSET %s
            """
            params.extend([limit, offset])

            cur.execute(query, params)
            rows = cur.fetchall()

            documents = [
                DocumentListItem(
                    doc_id=str(row["doc_id"]),
                    metadata=row["metadata"],
                    text=row["text"],
                )
                for row in rows
            ]

    return DocumentListResponse(documents=documents, count=len(documents))


@app.get("/search/people", response_model=PeopleSearchResponse)
def search_people(
    request: Request,
    q: Optional[str] = Query(default=None, min_length=1),
    limit: int = Query(20, ge=1, le=200),
    offset: int = Query(0, ge=0),
    _: None = Depends(require_token),
) -> PeopleSearchResponse:
    facets = _parse_facets(request)
    conditions: List[str] = ["d.source_type = 'contact'", "d.is_active_version = true"]
    params: List[Any] = []

    if q:
        like = f"%{q}%"
        conditions.append(
            """
            (
                d.title ILIKE %s OR
                d.text ILIKE %s OR
                d.metadata->'contact'->>'organization' ILIKE %s
            )
            """
        )
        params.extend([like, like, like])

    labels = [value.lower() for value in facets.get("label", [])]
    if labels:
        conditions.append(
            """
            (
                EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(COALESCE(d.metadata->'contact'->'emails', '[]'::jsonb)) email
                    WHERE email->>'label' = ANY(%s)
                )
                OR EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(COALESCE(d.metadata->'contact'->'phones', '[]'::jsonb)) phone
                    WHERE phone->>'label' = ANY(%s)
                )
            )
            """
        )
        label_tuple = tuple(labels)
        params.extend([label_tuple, label_tuple])

    kinds = [value for value in facets.get("kind", [])]
    if kinds:
        if "email" in kinds:
            conditions.append(
                """
                jsonb_array_length(COALESCE(d.metadata->'contact'->'emails', '[]'::jsonb)) > 0
                """
            )
        if "phone" in kinds:
            conditions.append(
                """
                jsonb_array_length(COALESCE(d.metadata->'contact'->'phones', '[]'::jsonb)) > 0
                """
            )

    cities = facets.get("city", [])
    if cities:
        conditions.append(
            """
            EXISTS (
                SELECT 1
                FROM jsonb_array_elements(COALESCE(d.metadata->'contact'->'addresses', '[]'::jsonb)) addr
                WHERE addr->>'city' = ANY(%s)
            )
            """
        )
        params.append(tuple(cities))

    regions = facets.get("region", [])
    if regions:
        conditions.append(
            """
            EXISTS (
                SELECT 1
                FROM jsonb_array_elements(COALESCE(d.metadata->'contact'->'addresses', '[]'::jsonb)) addr
                WHERE addr->>'region' = ANY(%s)
            )
            """
        )
        params.append(tuple(regions))

    countries = facets.get("country", [])
    if countries:
        conditions.append(
            """
            EXISTS (
                SELECT 1
                FROM jsonb_array_elements(COALESCE(d.metadata->'contact'->'addresses', '[]'::jsonb)) addr
                WHERE addr->>'country' = ANY(%s)
            )
            """
        )
        params.append(tuple(countries))

    orgs = facets.get("organization", [])
    if orgs:
        conditions.append("d.metadata->'contact'->>'organization' = ANY(%s)")
        params.append(tuple(orgs))

    where_clause = " AND ".join(conditions) if conditions else "TRUE"

    sql = f"""
        SELECT
            d.doc_id,
            d.title,
            d.metadata,
            d.people,
            d.text
        FROM documents d
        WHERE {where_clause}
        ORDER BY d.title ASC
        LIMIT %s OFFSET %s
    """
    query_params = params + [limit, offset]

    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(sql, query_params)
            rows = cur.fetchall()

    results: List[PeopleSearchHit] = []
    for row in rows:
        metadata = row.get("metadata") or {}
        contact_meta = metadata.get("contact") or {}
        emails = [
            entry.get("value")
            for entry in contact_meta.get("emails", [])
            if isinstance(entry, dict) and entry.get("value")
        ]
        phones = [
            entry.get("value")
            for entry in contact_meta.get("phones", [])
            if isinstance(entry, dict) and entry.get("value")
        ]
        addresses_meta = contact_meta.get("addresses", [])
        address_entries = []
        for addr in addresses_meta:
            if not isinstance(addr, dict):
                continue
            address_entries.append(
                ContactAddressSummary(
                    label=addr.get("label"),
                    city=addr.get("city"),
                    region=addr.get("region"),
                    country=addr.get("country"),
                )
            )

        results.append(
            PeopleSearchHit(
                person_id=str(row["doc_id"]),
                display_name=contact_meta.get("display_name") or row.get("title"),
                given_name=contact_meta.get("given_name"),
                family_name=contact_meta.get("family_name"),
                organization=contact_meta.get("organization"),
                nicknames=contact_meta.get("nicknames") or [],
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
    has_attachments: Optional[bool] = Query(None),
    source_type: Optional[str] = Query(None),
    person: Optional[str] = Query(None),
    start_date: Optional[str] = Query(None),
    end_date: Optional[str] = Query(None),
    thread_id: Optional[str] = Query(None),
    context_window: int = Query(0, ge=0, le=20),
    _: None = Depends(require_token),
    client: SearchServiceClient = Depends(get_search_client),
) -> SearchResponse:
    filters: List[QueryFilter] = []
    if has_attachments is not None:
        filters.append(
            QueryFilter(
                term="has_attachments",
                value="true" if has_attachments else "false",
            )
        )
    if source_type:
        filters.append(QueryFilter(term="source_type", value=source_type))
    if person:
        filters.append(QueryFilter(term="person", value=person))

    start_dt = _parse_iso_datetime(start_date, param="start_date")
    end_dt = _parse_iso_datetime(end_date, param="end_date")
    if start_dt or end_dt:
        filters.append(
            QueryFilter(
                range=RangeFilter(
                    field="content_timestamp",
                    gte=start_dt,
                    lte=end_dt,
                )
            )
        )

    if thread_id:
        filters.append(QueryFilter(term="thread_id", value=thread_id))
        if context_window:
            filters.append(QueryFilter(term="context_window", value=str(context_window)))

    request = SearchRequest(
        query=q,
        page=PageCursor(size=k),
        filter=filters,
        facets=["source_type", "has_attachments", "person"],
    )
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
            summary_sentences.append(
                f"{doc.sender} mentioned '{doc.text}' on {ts_str} UTC."
            )
        else:
            title = doc.title or doc.metadata.get("title") or doc.document_id
            snippet = (
                (doc.snippet or doc.metadata.get("snippet", ""))
                .strip()
                .replace("\n", " ")
            )
            snippet = snippet[:160] + ("…" if len(snippet) > 160 else "")
            summary_sentences.append(
                f"Document '{title}' scored {doc.score:.2f}: {snippet}"
            )

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

    async with httpx.AsyncClient(
        base_url=settings.catalog_base_url, timeout=10.0
    ) as client:
        response = await client.get(f"/v1/doc/{doc_id}", headers=headers)

    if response.status_code == 404:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Document not found"
        )
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

    async with httpx.AsyncClient(
        base_url=settings.catalog_base_url, timeout=10.0
    ) as client:
        response = await client.get("/v1/context/general", headers=headers)

    if response.status_code >= 400:
        try:
            detail: Any = response.json()
        except ValueError:
            detail = response.text
        raise HTTPException(status_code=response.status_code, detail=detail)

    return response.json()


@app.get("/v1/healthz")
async def health() -> Dict[str, str]:
    return {"status": "ok"}
