from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from uuid import NAMESPACE_URL, uuid5

import hashlib

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import requests

try:
    from PIL import Image
    # Register HEIC/HEIF support if pillow-heif is available
    try:
        from pillow_heif import register_heif_opener
        register_heif_opener()
    except ImportError as e:
        raise e # HEIC files will fail to convert, but other formats will still work
except ImportError:
    Image = None  # type: ignore[assignment]

from shared.db import get_connection

from shared.logging import get_logger, setup_logging

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
DEFAULT_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"
STATE_DIR = Path.home() / ".haven"
STATE_FILE = STATE_DIR / "imessage_collector_state.json"
CATALOG_ENDPOINT = os.getenv(
    "CATALOG_ENDPOINT", "http://localhost:8085/v1/ingest"
)
COLLECTOR_AUTH_TOKEN = os.getenv("AUTH_TOKEN") or os.getenv("CATALOG_TOKEN")
POLL_INTERVAL_SECONDS = float(os.getenv("COLLECTOR_POLL_INTERVAL", "5"))
BATCH_SIZE = int(os.getenv("COLLECTOR_BATCH_SIZE", "200"))


def _safe_float_env(name: str, default: float) -> float:
    value = os.getenv(name)
    if value is None:
        return default
    try:
        return float(value)
    except ValueError:
        return default


IMDESC_EXECUTABLE = os.getenv("IMDESC_CLI_PATH", "imdesc")
IMDESC_TIMEOUT_SECONDS = _safe_float_env("IMDESC_TIMEOUT_SECONDS", 15.0)

# Ollama configuration for optional image captioning
OLLAMA_ENABLED = os.getenv("OLLAMA_ENABLED", "true").lower() in ("1", "true", "yes", "on")
OLLAMA_API_URL = os.getenv("OLLAMA_API_URL", "http://localhost:11434/api/generate")
OLLAMA_VISION_MODEL = os.getenv("OLLAMA_VISION_MODEL", "qwen2.5vl:3b")
# Vision models are slower than text models; default to 60s (first load can take even longer)
OLLAMA_TIMEOUT_SECONDS = _safe_float_env("OLLAMA_TIMEOUT_SECONDS", 60.0)
OLLAMA_CAPTION_PROMPT = os.getenv(
    "OLLAMA_CAPTION_PROMPT",
    "describe the image scene and contents. ignore text. short response",
)
CATALOG_IMAGE_ENDPOINT = os.getenv(
    "CATALOG_IMAGE_ENDPOINT", "http://localhost:8085/v1/catalog/images"
)
CATALOG_IMAGE_TIMEOUT_SECONDS = _safe_float_env("CATALOG_IMAGE_TIMEOUT_SECONDS", 10.0)
IMAGE_EMBEDDING_MODEL = os.getenv("IMAGE_EMBEDDING_MODEL", os.getenv("EMBEDDING_MODEL", "BAAI/bge-m3"))

# How many times to retry Ollama requests on transient errors (Connection/Timeout)
OLLAMA_MAX_RETRIES = int(os.getenv("OLLAMA_MAX_RETRIES", "2"))
IMAGE_ATTACHMENT_EXTENSIONS = {
    ".bmp",
    ".gif",
    ".heic",
    ".heif",
    ".jpeg",
    ".jpg",
    ".png",
    ".tif",
    ".tiff",
    ".webp",
}
IMAGE_CACHE_FILE = STATE_DIR / "imessage_image_cache.json"

logger = get_logger("collector.imessage")

_IMDESC_MISSING_LOGGED = False
_OLLAMA_CONNECTION_WARNED = False
_CAPTION_EMBEDDING_AVAILABLE_LOGGED = False

# Embedding is handled by the embedding_worker service. The collector should
# not compute or attach embeddings directly. Keep the SentenceTransformer
# symbol only for optional lazy imports elsewhere; do not instantiate here.
SentenceTransformer = None  # type: ignore[assignment]


def deterministic_chunk_id(doc_id: str, chunk_index: int) -> str:
    return str(uuid5(NAMESPACE_URL, f"{doc_id}:{chunk_index}"))


def _truncate_text(value: Optional[str], limit: int = 512) -> str:
    if not value:
        return ""
    if len(value) <= limit:
        return value
    return value[: limit - 1] + "\u2026"


@dataclass
class CollectorState:
    last_seen_rowid: int = 0       # The floor: don't scan below this (when backlog complete)
    max_seen_rowid: int = 0        # The ceiling: current high-water mark
    min_seen_rowid: int = 0        # The lowest ROWID processed so far (for resume)
    initial_backlog_complete: bool = False  # True once we've scanned down to ROWID 0

    @classmethod
    def load(cls) -> "CollectorState":
        if not STATE_FILE.exists():
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            return cls()
        try:
            data = json.loads(STATE_FILE.read_text())
            return cls(
                last_seen_rowid=int(data.get("last_seen_rowid", 0)),
                max_seen_rowid=int(data.get("max_seen_rowid", 0)),
                min_seen_rowid=int(data.get("min_seen_rowid", 0)),
                initial_backlog_complete=bool(data.get("initial_backlog_complete", False)),
            )
        except Exception:
            logger.warning("failed_to_load_state", path=str(STATE_FILE))
            return cls()

    def save(self) -> None:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(
            json.dumps({
                "last_seen_rowid": self.last_seen_rowid,
                "max_seen_rowid": self.max_seen_rowid,
                "min_seen_rowid": self.min_seen_rowid,
                "initial_backlog_complete": self.initial_backlog_complete,
            })
        )


@dataclass
class SourceEvent:
    doc_id: str
    thread: Dict[str, Any]
    message: Dict[str, Any]
    chunks: List[Dict[str, Any]]
    image_events: List[Dict[str, Any]] = field(default_factory=list)

    def to_ingest_payload(self) -> Dict[str, Any]:
        parts: List[str] = []
        message_text = self.message.get("text")
        if isinstance(message_text, str) and message_text.strip():
            parts.append(message_text.strip())
        for chunk in self.chunks:
            chunk_text = chunk.get("text")
            if isinstance(chunk_text, str) and chunk_text.strip():
                text_value = chunk_text.strip()
                if not parts or parts[-1] != text_value:
                    parts.append(text_value)

        text_body = "\n\n".join(parts)
        if not text_body:
            text_body = f"[empty message {self.doc_id}]"
        metadata = {
            "thread": self.thread,
            "message": self.message,
            "chunks": self.chunks,
        }

        return {
            "source_type": "imessage",
            "source_id": self.doc_id,
            "title": self.thread.get("title"),
            "canonical_uri": None,
            "content": {"mime_type": "text/plain", "data": text_body},
            "metadata": metadata,
        }


class ImageEnrichmentCache:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._data: Dict[str, Dict[str, Any]] = {}
        self._dirty = False
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            raw = json.loads(self.path.read_text())
        except Exception:
            logger.warning("image_cache_load_failed", path=str(self.path))
            return
        if isinstance(raw, dict):
            for key, value in raw.items():
                if isinstance(key, str) and isinstance(value, dict):
                    self._data[key] = value

    def get(self, blob_id: str) -> Optional[Dict[str, Any]]:
        return self._data.get(blob_id)

    def set(self, blob_id: str, payload: Dict[str, Any]) -> None:
        self._data[blob_id] = payload
        self._dirty = True

    def save(self) -> None:
        if not self._dirty:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(self._data))
            self._dirty = False
        except Exception:
            logger.warning("image_cache_save_failed", path=str(self.path), exc_info=True)


_image_cache: Optional[ImageEnrichmentCache] = None
# Do not instantiate any embedder here. Embeddings are the responsibility of
# the dedicated embedding_worker; the collector should only attach metadata
# (captions, OCR text, entities) and send those to the gateway/catalog.


def get_image_cache() -> ImageEnrichmentCache:
    global _image_cache
    if _image_cache is None:
        _image_cache = ImageEnrichmentCache(IMAGE_CACHE_FILE)
    return _image_cache


def backup_chat_db(source: Path) -> Path:
    """Create or update a single rotating backup file for chat.db.

    Instead of making a new temp directory per poll (which leaves many
    large files in /private/var/folders), this writes the backup to
    ~/.haven/chat_backup/chat.db and reuses that file on subsequent runs.

    Returns the Path to the backup file.
    """
    if not source.exists():
        raise FileNotFoundError(f"chat.db not found at {source}")

    backup_dir = STATE_DIR / "chat_backup"
    backup_dir.mkdir(parents=True, exist_ok=True)
    dest = backup_dir / "chat.db"

    logger.debug("backing_up_chat_db_rotating", source=str(source), dest=str(dest))

    # Use SQLite backup API to copy safely from the live DB to the backup path.
    # Overwrite the existing backup file in-place by writing to a temporary
    # sibling and renaming, reducing windows of partial files.
    tmp_dest = backup_dir / "chat.db.tmp"
    if tmp_dest.exists():
        try:
            tmp_dest.unlink()
        except Exception:
            # best-effort cleanup; continue
            logger.debug("failed_unlink_tmp_backup", path=str(tmp_dest))

    with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as src_conn:
        # create or replace temporary destination
        with sqlite3.connect(tmp_dest) as dst_conn:
            src_conn.backup(dst_conn)

    try:
        tmp_dest.replace(dest)
    except Exception:
        # fallback to rename via os.replace
        os.replace(str(tmp_dest), str(dest))

    return dest


def apple_time_to_utc(raw_value: Optional[int]) -> Optional[str]:
    if raw_value is None:
        return None

    value = int(raw_value)
    if value == 0:
        return None

    # Heuristic to support second / microsecond / nanosecond precision values
    if value > 10_000_000_000_000:
        delta = timedelta(microseconds=value / 1_000)
    elif value > 10_000_000:
        delta = timedelta(seconds=value / 1_000_000)
    else:
        delta = timedelta(seconds=value)

    ts = APPLE_EPOCH + delta
    return ts.astimezone(timezone.utc).isoformat()


def get_participants(conn: sqlite3.Connection, chat_rowid: int) -> List[str]:
    participants = []
    cursor = conn.execute(
        """
        SELECT h.id
        FROM chat_handle_join chj
        JOIN handle h ON h.ROWID = chj.handle_id
        WHERE chj.chat_id = ?
        ORDER BY h.id
        """,
        (chat_rowid,),
    )
    for row in cursor.fetchall():
        participant = row[0]
        if participant:
            participants.append(participant)
    return participants


def decode_attributed_body(blob: Optional[bytes]) -> str:
    """Extract the visible string from an NSKeyedArchive attributed body."""

    if not blob:
        return ""

    try:
        data = bytes(blob)
    except Exception:  # pragma: no cover - defensive
        return ""

    try:
        archive = plistlib.loads(data)
    except Exception:  # pragma: no cover - best effort decoding
        logger.debug("attributed_body_decode_failed", exc_info=True)
        return ""

    if not isinstance(archive, dict):
        return ""

    objects = archive.get("$objects")
    top = archive.get("$top")
    if not isinstance(objects, list) or not isinstance(top, dict):
        return ""

    def resolve(value: Any, seen: frozenset[int]) -> tuple[Any, frozenset[int]]:
        current = value
        local_seen = seen
        while isinstance(current, dict) and "UID" in current:
            uid = current.get("UID")
            if not isinstance(uid, int) or uid in local_seen:
                return None, local_seen
            if not 0 <= uid < len(objects):
                return None, local_seen
            current = objects[uid]
            local_seen = local_seen | {uid}
        return current, local_seen

    def extract(value: Any, seen: frozenset[int] | None = None) -> str:
        if seen is None:
            seen = frozenset()

        node, seen = resolve(value, seen)
        if node is None:
            return ""

        if isinstance(node, str):
            return node.strip("\x00")

        if isinstance(node, bytes):
            try:
                return node.decode("utf-8", errors="ignore").strip("\x00")
            except Exception:  # pragma: no cover - defensive
                return ""

        if isinstance(node, dict):
            if isinstance(node.get("NSString"), str):
                return node["NSString"].strip("\x00")

            if "NS.string" in node:
                candidate = extract(node["NS.string"], seen)
                if candidate:
                    return candidate

            if isinstance(node.get("NS.objects"), list):
                for item in node["NS.objects"]:
                    candidate = extract(item, seen)
                    if candidate:
                        return candidate

            if isinstance(node.get("NS.values"), list):
                for item in node["NS.values"]:
                    candidate = extract(item, seen)
                    if candidate:
                        return candidate

        if isinstance(node, list):
            for item in node:
                candidate = extract(item, seen)
                if candidate:
                    return candidate

        return ""

    if "root" in top:
        decoded = extract(top["root"])
        if decoded:
            return decoded

    for entry in objects:
        decoded = extract(entry)
        if decoded:
            return decoded

    return ""


def _is_image_attachment(metadata: Dict[str, Any]) -> bool:
    mime_type = str(metadata.get("mime_type") or "").lower()
    if mime_type.startswith("image/"):
        return True

    uti = str(metadata.get("uti") or "").lower()
    if uti.startswith("public.image") or uti.startswith("public.heic") or uti.startswith("public.heif"):
        return True

    name = metadata.get("transfer_name") or metadata.get("filename")
    if name:
        suffix = Path(str(name)).suffix.lower()
        if suffix in IMAGE_ATTACHMENT_EXTENSIONS:
            return True

    return False


def _resolve_attachment_path(raw: Optional[str]) -> Optional[Path]:
    if not raw:
        return None

    try:
        candidate = Path(str(raw)).expanduser()
    except TypeError:
        return None

    if candidate.is_absolute():
        return candidate

    base = Path.home() / "Library" / "Messages" / "Attachments"
    return (base / candidate).expanduser()


def _hash_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _truncate_caption(value: Optional[str], limit: int = 200) -> str:
    if not value:
        return ""
    caption = value.strip()
    if len(caption) <= limit:
        return caption
    return caption[: limit - 1] + "\u2026"


def _build_image_facets(entities: Dict[str, List[str]]) -> Dict[str, Any]:
    facets: Dict[str, Any] = {}
    for key in ("dates", "phones", "urls", "addresses"):
        values = entities.get(key)
        if values:
            facets[key] = values
    facets["has_text"] = bool(entities.get("dates") or entities.get("phones") or entities.get("urls") or entities.get("addresses"))
    return facets


def _copy_attachment_to_temp(source: Path, dest_dir: Path, *, row_id: Any) -> Optional[Path]:
    try:
        dest_dir.mkdir(parents=True, exist_ok=True)
        target_name = f"{row_id}_{source.name}"
        target = dest_dir / target_name
        shutil.copy2(source, target)
        return target
    except FileNotFoundError:
        logger.debug("attachment_source_missing", path=str(source))
    except Exception:
        logger.debug(
            "attachment_copy_failed", src=str(source), dest=str(dest_dir), exc_info=True
        )
    return None


def _run_imdesc(image_path: Path) -> Optional[Dict[str, Any]]:
    global _IMDESC_MISSING_LOGGED

    try:
        completed = subprocess.run(
            [IMDESC_EXECUTABLE, "--format", "json", str(image_path)],
            capture_output=True,
            text=True,
            timeout=IMDESC_TIMEOUT_SECONDS,
            check=True,
        )
    except FileNotFoundError:
        if not _IMDESC_MISSING_LOGGED:
            logger.warning("imdesc_cli_missing", executable=IMDESC_EXECUTABLE)
            _IMDESC_MISSING_LOGGED = True
        return None
    except subprocess.TimeoutExpired:
        logger.warning(
            "imdesc_cli_timeout", timeout=IMDESC_TIMEOUT_SECONDS, path=str(image_path)
        )
        return None
    except subprocess.CalledProcessError as exc:
        logger.warning(
            "imdesc_cli_error",
            returncode=exc.returncode,
            stderr=_truncate_text(exc.stderr),
            path=str(image_path),
        )
        return None
    except Exception:
        logger.warning("imdesc_cli_failed", path=str(image_path), exc_info=True)
        return None

    output = (completed.stdout or "").strip()
    if not output:
        return None

    try:
        data = json.loads(output)
    except json.JSONDecodeError:
        logger.warning("imdesc_cli_invalid_json", output=_truncate_text(output))
        return None

    if not isinstance(data, dict):
        return None

    return data


def _request_ollama_caption(image_path: Path) -> Optional[str]:
    """Request an image caption from Ollama vision model.
    
    Returns None if OLLAMA_ENABLED=false or if all attempts fail.
    """
    if not OLLAMA_ENABLED:
        return None
    
    global _OLLAMA_CONNECTION_WARNED

    try:
        image_bytes = image_path.read_bytes()
    except FileNotFoundError:
        logger.debug("ollama_image_missing", path=str(image_path))
        return None
    except Exception:
        logger.debug("ollama_image_read_failed", path=str(image_path), exc_info=True)
        return None

    # Log file info for debugging
    logger.debug("ollama_image_prepare", path=str(image_path), size_bytes=len(image_bytes), suffix=image_path.suffix.lower())

    # Convert image to PNG format if PIL is available (Ollama doesn't support HEIC/HEIF)
    if Image is not None:
        try:
            import io
            img = Image.open(io.BytesIO(image_bytes))
            # Convert to RGB if needed (e.g., RGBA or CMYK)
            if img.mode not in ('RGB', 'L'):
                img = img.convert('RGB')
            # Re-encode as PNG
            buf = io.BytesIO()
            img.save(buf, format='PNG')
            image_bytes = buf.getvalue()
            logger.debug("ollama_image_converted", original_format=image_path.suffix, size_bytes=len(image_bytes))
        except Exception as exc:
            logger.warning("ollama_image_conversion_failed", path=str(image_path), error=str(exc))
            # Fall back to original bytes (will likely fail with 500)

    image_b64 = base64.b64encode(image_bytes).decode("utf-8")
    payload = {
        "model": OLLAMA_VISION_MODEL,
        "prompt": OLLAMA_CAPTION_PROMPT,
        "images": [image_b64],
        "stream": False,
    }

    # Log the minimal request info for diagnostics (don't log full base64 body)
    logger.debug("ollama_request_prepare", url=OLLAMA_API_URL, model=OLLAMA_VISION_MODEL, prompt=_truncate_text(OLLAMA_CAPTION_PROMPT, 200))

    attempt = 0
    last_exc: Optional[Exception] = None
    while attempt <= OLLAMA_MAX_RETRIES:
        try:
            attempt += 1
            logger.debug("ollama_request_send", attempt=attempt, url=OLLAMA_API_URL)
            response = requests.post(
                OLLAMA_API_URL, json=payload, timeout=OLLAMA_TIMEOUT_SECONDS
            )
            # Record status for debugging
            logger.debug("ollama_response_status", status_code=response.status_code, attempt=attempt)
            response.raise_for_status()
            last_exc = None
            break
        except requests.ConnectionError as exc:
            last_exc = exc
            if not _OLLAMA_CONNECTION_WARNED:
                logger.warning("ollama_unreachable", url=OLLAMA_API_URL, error=str(exc))
                _OLLAMA_CONNECTION_WARNED = True
            logger.debug("ollama_conn_error", attempt=attempt, error=str(exc))
        except requests.Timeout as exc:
            last_exc = exc
            logger.warning("ollama_timeout", timeout=OLLAMA_TIMEOUT_SECONDS, attempt=attempt)
        except requests.RequestException as exc:
            last_exc = exc
            # Non-retryable HTTP error (4xx/5xx) or other request exception
            logger.warning("ollama_request_failed", error=str(exc), attempt=attempt)
            # If response exists, capture body for diagnosis
            try:
                resp = getattr(exc, "response", None)
                if resp is not None:
                    logger.debug("ollama_response_text", text=_truncate_text(getattr(resp, "text", None)))
            except Exception:
                # best-effort logging; don't fail the enrichment flow
                pass
            break

        # If we'll retry, sleep with exponential backoff
        if attempt <= OLLAMA_MAX_RETRIES:
            backoff = 0.5 * (2 ** (attempt - 1))
            logger.debug("ollama_retry_backoff", attempt=attempt, backoff=backoff)
            time.sleep(backoff)

    if last_exc is not None:
        # Nothing succeeded
        logger.debug("ollama_all_attempts_failed", attempts=attempt, last_error=str(last_exc))
        return None

    try:
        data = response.json()
    except ValueError:
        logger.warning("ollama_invalid_json", text=_truncate_text(response.text))
        return None

    caption = data.get("response")
    if isinstance(caption, str) and caption.strip():
        return caption.strip()

    message = data.get("message")
    if isinstance(message, dict):
        content = message.get("content")
        if isinstance(content, str) and content.strip():
            return content.strip()

    return None


def _sanitize_ocr_result(result: Optional[Dict[str, Any]]) -> tuple[str, List[Dict[str, Any]], Dict[str, List[str]]]:
    if not isinstance(result, dict):
        return "", [], {}

    ocr_text = ""
    text_value = result.get("text")
    if isinstance(text_value, str):
        ocr_text = text_value.strip()

    boxes: List[Dict[str, Any]] = []
    boxes_value = result.get("boxes")
    if isinstance(boxes_value, list):
        boxes = [box for box in boxes_value if isinstance(box, dict)]

    entities: Dict[str, List[str]] = {}
    raw_entities = result.get("entities")
    if isinstance(raw_entities, dict):
        for key, values in raw_entities.items():
            if not isinstance(values, list):
                continue
            cleaned: List[str] = []
            for item in values:
                if isinstance(item, str):
                    candidate = item.strip()
                elif isinstance(item, (int, float)):
                    candidate = str(item)
                else:
                    continue
                if candidate:
                    cleaned.append(candidate)
            if cleaned:
                entities[str(key)] = cleaned

    return ocr_text, boxes, entities


def enrich_image_attachment(
    metadata: Dict[str, Any],
    tmp_dir: Path,
    *,
    thread_id: str,
    message_guid: str,
    cache: ImageEnrichmentCache,
) -> Optional[Tuple[Dict[str, Any], Dict[str, Any]]]:
    if not _is_image_attachment(metadata):
        return None

    source = _resolve_attachment_path(metadata.get("filename"))
    if source is None or not source.exists():
        transfer_name = metadata.get("transfer_name")
        alt_source = _resolve_attachment_path(transfer_name) if transfer_name else None
        if alt_source is not None and alt_source.exists():
            source = alt_source

    if source is None or not source.exists():
        logger.debug(
            "attachment_file_missing",
            row_id=metadata.get("row_id"),
            filename=metadata.get("filename"),
        )
        return None

    try:
        image_bytes = source.read_bytes()
    except Exception:
        logger.debug("attachment_read_failed", path=str(source), exc_info=True)
        return None

    blob_id = _hash_bytes(image_bytes)
    cached = cache.get(blob_id) or {}

    caption = cached.get("caption") if isinstance(cached, dict) else None
    ocr_text = cached.get("ocr_text") if isinstance(cached, dict) else ""
    ocr_boxes = cached.get("ocr_boxes") if isinstance(cached, dict) else []
    ocr_entities = cached.get("ocr_entities") if isinstance(cached, dict) else {}

    if not caption and not ocr_text:
        copied = _copy_attachment_to_temp(
            source, tmp_dir, row_id=metadata.get("row_id", "attachment")
        )
        if copied is None:
            return None

        ocr_raw = _run_imdesc(copied)
        caption = _request_ollama_caption(copied)
        ocr_text, ocr_boxes, ocr_entities = _sanitize_ocr_result(ocr_raw)
        caption = _truncate_caption(caption)

        cache.set(
            blob_id,
            {
                "caption": caption,
                "ocr_text": ocr_text,
                "ocr_boxes": ocr_boxes,
                "ocr_entities": ocr_entities,
            },
        )
    else:
        caption = _truncate_caption(caption)
        if not isinstance(ocr_boxes, list):
            ocr_boxes = []
        if not isinstance(ocr_entities, dict):
            ocr_entities = {}

    image_data = {
        "ocr_text": ocr_text,
        "ocr_boxes": ocr_boxes,
        "ocr_entities": ocr_entities,
        "caption": caption,
        "blob_id": blob_id,
    }

    enriched = {
        "row_id": metadata.get("row_id"),
        "guid": metadata.get("guid"),
        "mime_type": metadata.get("mime_type"),
        "transfer_name": metadata.get("transfer_name"),
        "uti": metadata.get("uti"),
        "total_bytes": metadata.get("total_bytes"),
        "image": image_data,
    }

    facets = _build_image_facets(ocr_entities)
    image_event = {
        "source": "imessage",
        "kind": "image",
        "thread_id": thread_id,
        "message_id": message_guid,
        "blob_id": blob_id,
        "caption": caption,
        "ocr_text": ocr_text,
        "entities": ocr_entities,
        "facets": facets,
    }

    return enriched, image_event


def enrich_image_attachments(
    attachments: Optional[List[Dict[str, Any]]],
    *,
    thread_id: str,
    message_guid: str,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    if not attachments:
        return [], []

    enriched: List[Dict[str, Any]] = []
    image_events: List[Dict[str, Any]] = []
    cache = get_image_cache()
    with tempfile.TemporaryDirectory() as tmp_dir_str:
        tmp_dir = Path(tmp_dir_str)
        for metadata in attachments:
            try:
                enriched_attachment = enrich_image_attachment(
                    metadata,
                    tmp_dir,
                    thread_id=thread_id,
                    message_guid=message_guid,
                    cache=cache,
                )
            except Exception:  # pragma: no cover - defensive
                logger.error(
                    "attachment_enrichment_failed",
                    row_id=metadata.get("row_id"),
                    exc_info=True,
                )
                continue
            if enriched_attachment:
                enriched.append(enriched_attachment[0])
                image_events.append(enriched_attachment[1])

    cache.save()

    return enriched, image_events


def _build_attachment_chunk_text(attachment: Dict[str, Any]) -> str:
    image_data = attachment.get("image")
    if not isinstance(image_data, dict):
        return ""

    parts: List[str] = []

    caption = image_data.get("caption")
    if isinstance(caption, str) and caption.strip():
        parts.append(f"Image caption: {caption.strip()}")

    ocr_text = image_data.get("ocr_text")
    if isinstance(ocr_text, str) and ocr_text.strip():
        parts.append(f"OCR text: {ocr_text.strip()}")

    entities = image_data.get("ocr_entities")
    if isinstance(entities, dict):
        entity_parts: List[str] = []
        for key, values in entities.items():
            if not isinstance(values, list):
                continue
            cleaned = [str(item).strip() for item in values if str(item).strip()]
            if cleaned:
                entity_parts.append(f"{key}: {', '.join(cleaned)}")
        if entity_parts:
            parts.append("Entities: " + "; ".join(entity_parts))

    return "\n".join(parts)


def fetch_message_attachments(conn: sqlite3.Connection, message_rowid: int) -> List[Dict[str, Any]]:
    conn.row_factory = sqlite3.Row
    cursor = conn.execute(
        """
        SELECT a.ROWID,
               a.guid,
               a.filename,
               a.mime_type,
               a.transfer_name,
               a.uti,
               a.total_bytes
        FROM attachment a
        JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
        WHERE maj.message_id = ?
        ORDER BY a.ROWID
        """,
        (message_rowid,),
    )

    attachments: List[Dict[str, Any]] = []
    for row in cursor.fetchall():
        attachments.append(
            {
                "row_id": int(row["ROWID"]) if row["ROWID"] is not None else None,
                "guid": row["guid"],
                "filename": row["filename"],
                "mime_type": row["mime_type"],
                "transfer_name": row["transfer_name"],
                "uti": row["uti"],
                "total_bytes": row["total_bytes"],
            }
        )

    return attachments


def normalize_row(
    row: sqlite3.Row,
    participants: List[str],
    attachments: Optional[List[Dict[str, Any]]] = None,
    disable_images: bool = False,
) -> SourceEvent:
    text = (row["text"] or "").strip()
    original_text_empty = not text
    if not text:
        text = decode_attributed_body(row["attributed_body"])
    if not text:
        attachment_count = row["attachment_count"]
        if attachment_count:
            text = f"[{attachment_count} attachment(s) omitted]"
    ts_iso = apple_time_to_utc(row["date"])
    doc_id = f"imessage:{row['guid']}"

    thread = {
        "id": row["chat_guid"],
        "kind": "imessage",
        "participants": participants,
        "title": row["chat_display_name"],
    }

    message = {
        "row_id": row["ROWID"],
        "guid": row["guid"],
        "thread_id": row["chat_guid"],
        "ts": ts_iso,
        # If the message is from the local user, mark sender as 'me'.
        # Otherwise use the handle id provided by the DB (may be None).
        "sender": "me" if bool(row["is_from_me"]) else (row["handle_id"] or ""),
        "sender_service": row["service"],
        "is_from_me": bool(row["is_from_me"]),
        "text": text,
        "attrs": {
            "attachment_count": row["attachment_count"],
        },
    }

    chunks: List[Dict[str, Any]] = [
        {
            "id": deterministic_chunk_id(doc_id, 0),
            "chunk_index": 0,
            "text": text,
            "meta": {
                "doc_id": doc_id,
                "ts": ts_iso,
                "thread_id": row["chat_guid"],
            },
        }
    ]

    image_events: List[Dict[str, Any]] = []
    enriched_attachments: List[Dict[str, Any]] = []

    if not disable_images:
        enriched_attachments, image_events = enrich_image_attachments(
            attachments,
            thread_id=row["chat_guid"],
            message_guid=row["guid"],
        )
    else:
        # When image handling is disabled, replace any image attachments with
        # a placeholder text. Do not perform enrichment or produce image events.
        if attachments:
            # Count image attachments and append placeholder(s)
            image_count = 0
            for meta in attachments:
                try:
                    if _is_image_attachment(meta):
                        image_count += 1
                except Exception:
                    continue

            if image_count:
                placeholders = " ".join(["[image]" for _ in range(image_count)])
                if text and not text.startswith("[") and not text.endswith("attachment(s) omitted]"):
                    text = f"{text} {placeholders}"
                else:
                    # No original text or only placeholder - use placeholders as main text
                    text = placeholders
                # Update first chunk's text
                chunks[0]["text"] = text
    if enriched_attachments:
        message["attachments"] = enriched_attachments

        captions = [
            attachment.get("image", {}).get("caption")
            for attachment in enriched_attachments
            if isinstance(attachment.get("image"), dict)
            and isinstance(attachment.get("image", {}).get("caption"), str)
            and attachment.get("image", {}).get("caption").strip()
        ]
        
        ocr_texts = [
            attachment.get("image", {}).get("ocr_text")
            for attachment in enriched_attachments
            if isinstance(attachment.get("image"), dict)
            and isinstance(attachment.get("image", {}).get("ocr_text"), str)
            and attachment.get("image", {}).get("ocr_text").strip()
        ]
        
        # Build enriched text parts to append to the message
        enriched_parts = []
        if captions:
            message["attrs"]["image_captions"] = [caption.strip() for caption in captions]
            enriched_parts.extend([f"[Image: {cap.strip()}]" for cap in captions])
        
        if ocr_texts:
            message["attrs"]["image_ocr_text"] = [ocr.strip() for ocr in ocr_texts]
            enriched_parts.extend([f"[OCR: {ocr.strip()}]" for ocr in ocr_texts])
        
        # Append captions and OCR text to the message text so they're retrievable via /context/general
        if enriched_parts:
            enriched_text = " ".join(enriched_parts)
            if text and not text.startswith("[") and not text.endswith("attachment(s) omitted]"):
                # Message has real text, append enriched content
                text = f"{text} {enriched_text}"
            elif original_text_empty or text.endswith("attachment(s) omitted]"):
                # Message has no text or only placeholder, use enriched content as main text
                text = enriched_text
            message["text"] = text
            # Update the first chunk's text to match
            chunks[0]["text"] = text

        entity_payload = [
            attachment.get("image", {}).get("ocr_entities")
            for attachment in enriched_attachments
            if isinstance(attachment.get("image"), dict)
            and isinstance(attachment.get("image", {}).get("ocr_entities"), dict)
            and attachment.get("image", {}).get("ocr_entities")
        ]
        if entity_payload:
            message["attrs"]["image_ocr_entities"] = entity_payload

        if original_text_empty and captions:
            message["attrs"]["image_primary_caption"] = captions[0].strip()

        blob_ids = [
            attachment.get("image", {}).get("blob_id")
            for attachment in enriched_attachments
            if isinstance(attachment.get("image"), dict)
            and attachment.get("image", {}).get("blob_id")
        ]
        if blob_ids:
            message["attrs"]["image_blob_ids"] = blob_ids

        next_chunk_index = 1
        for attachment_payload in enriched_attachments:
            chunk_text = _build_attachment_chunk_text(attachment_payload)
            if not chunk_text:
                continue

            chunk_meta = {
                "doc_id": doc_id,
                "ts": ts_iso,
                "thread_id": row["chat_guid"],
                "attachment_row_id": attachment_payload.get("row_id"),
            }
            if attachment_payload.get("guid"):
                chunk_meta["attachment_guid"] = attachment_payload["guid"]
            if attachment_payload.get("mime_type"):
                chunk_meta["attachment_mime_type"] = attachment_payload["mime_type"]
            if attachment_payload.get("transfer_name"):
                chunk_meta["attachment_transfer_name"] = attachment_payload["transfer_name"]

            chunks.append(
                {
                    "id": deterministic_chunk_id(doc_id, next_chunk_index),
                    "chunk_index": next_chunk_index,
                    "text": chunk_text,
                    "meta": chunk_meta,
                }
            )
            next_chunk_index += 1

    return SourceEvent(
        doc_id=doc_id,
        thread=thread,
        message=message,
        chunks=chunks,
        image_events=image_events,
    )


def fetch_new_messages(
    conn: sqlite3.Connection, last_seen: int, batch_size: int
) -> Iterable[SourceEvent]:
    """Fetch messages with ROWID > last_seen, in descending order.
    
    This returns the most recent messages first, working backwards.
    """
    conn.row_factory = sqlite3.Row
    cursor = conn.execute(
        """
        SELECT m.ROWID,
               m.guid,
               m.date,
               m.is_from_me,
               m.text,
               m.attributedBody AS attributed_body,
               h.id as handle_id,
               h.service,
               c.guid as chat_guid,
               c.display_name as chat_display_name,
               c.ROWID as chat_rowid,
               (
                   SELECT COUNT(*)
                   FROM message_attachment_join maj
                   WHERE maj.message_id = m.ROWID
               ) as attachment_count
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.ROWID > ?
        ORDER BY m.ROWID DESC
        LIMIT ?
        """,
        (last_seen, batch_size),
    )

    for row in cursor.fetchall():
        participants = get_participants(conn, row["chat_rowid"])
        attachments = fetch_message_attachments(conn, row["ROWID"])
        # Attempt to read disable_images flag from a thread-local-like place: the sqlite3 connection
        # doesn't carry args, so callers should pass the flag via connection.info if present. Fall back to False.
        disable_images = False
        try:
            # If the caller attached 'disable_images' attribute to the connection object, use it.
            disable_images = bool(getattr(conn, "disable_images", False))
        except Exception:
            disable_images = False

        yield normalize_row(row, participants, attachments, disable_images=disable_images)


def get_current_max_rowid(conn: sqlite3.Connection) -> int:
    """Get the current maximum ROWID from the message table."""
    cursor = conn.execute("SELECT MAX(ROWID) FROM message")
    row = cursor.fetchone()
    return int(row[0]) if row and row[0] is not None else 0


def compute_batch_max_timestamp(events: Iterable[SourceEvent]) -> Optional[str]:
    latest: Optional[datetime] = None
    for event in events:
        ts_value = event.message.get("ts")
        if not ts_value:
            continue
        try:
            parsed = datetime.fromisoformat(ts_value.replace("Z", "+00:00"))
        except ValueError:
            logger.debug("invalid_event_timestamp", ts=ts_value)
            continue
        if latest is None or parsed > latest:
            latest = parsed

    if latest is None:
        return None

    return latest.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def compute_sleep_from_inactivity(
    inactivity_seconds: float, *, base: float = POLL_INTERVAL_SECONDS, max_sleep: float = 60.0
) -> float:
    """Compute the polling sleep seconds given an inactivity period.

    - If inactivity < 60s: return base
    - Otherwise linearly ramp from base up to max_sleep over 5 minutes (300s)
      after the first minute of inactivity.
    """
    if inactivity_seconds < 60:
        return base
    ramp_progress = min((inactivity_seconds - 60) / (5 * 60), 1.0)
    return base + ramp_progress * (max_sleep - base)


def compute_cooldown_sleep(
    last_activity: Optional[datetime], *, base: float = POLL_INTERVAL_SECONDS, now: Optional[datetime] = None
) -> float:
    """Wrapper that computes sleep based on last_activity (datetime)."""
    if now is None:
        now = datetime.now(timezone.utc)
    if last_activity is None:
        last_activity = now
    inactivity = (now - last_activity).total_seconds()
    return compute_sleep_from_inactivity(inactivity, base=base)


def post_events(events: List[SourceEvent]) -> bool:
    if not events:
        return True

    headers = {"Content-Type": "application/json"}
    if COLLECTOR_AUTH_TOKEN:
        headers["Authorization"] = f"Bearer {COLLECTOR_AUTH_TOKEN}"

    all_success = True
    for event in events:
        payload = event.to_ingest_payload()
        try:
            response = requests.post(
                CATALOG_ENDPOINT,
                json=payload,
                headers=headers,
                timeout=10,
            )
            response.raise_for_status()
        except requests.HTTPError as exc:
            resp = exc.response
            logger.error(
                "ingest_post_failed",
                endpoint=CATALOG_ENDPOINT,
                status_code=getattr(resp, "status_code", None),
                response_text=_truncate_text(getattr(resp, "text", None)),
                error=str(exc),
                doc_id=event.doc_id,
            )
            all_success = False
        except requests.RequestException as exc:
            logger.error(
                "ingest_post_failed",
                endpoint=CATALOG_ENDPOINT,
                error=str(exc),
                doc_id=event.doc_id,
            )
            all_success = False

    return all_success


def post_image_events(image_events: List[Dict[str, Any]]) -> bool:
    if image_events:
        logger.debug("image_events_included_in_metadata", count=len(image_events))
    return True


def process_events(
    state: CollectorState,
    events: List[SourceEvent],
    *,
    success_event: str = "dispatched_events",
    failure_event: str = "dispatch_failed",
) -> bool:
    if not events:
        return False

    batch_max_ts = compute_batch_max_timestamp(events)

    if not post_events(events):
        logger.warning(
            failure_event,
            count=len(events),
            last_seen_rowid=state.last_seen_rowid,
            max_seen_rowid=state.max_seen_rowid,
            batch_max_ts=batch_max_ts,
        )
        return False

    image_events: List[Dict[str, Any]] = []
    for event in events:
        image_events.extend(event.image_events)

    if image_events:
        if not post_image_events(image_events):
            logger.warning(
                "image_event_dispatch_failed",
                count=len(image_events),
                endpoint=CATALOG_IMAGE_ENDPOINT,
            )

    row_ids: List[int] = []
    for event in events:
        row_id = event.message.get("row_id")
        if isinstance(row_id, int):
            row_ids.append(row_id)
        elif row_id is not None:
            try:
                row_ids.append(int(row_id))
            except (TypeError, ValueError):
                logger.debug("invalid_row_id", value=row_id)

    if row_ids:
        # Update last_seen to the minimum ROWID we processed (since we're scanning backwards)
        min_processed = min(row_ids)
        if state.last_seen_rowid == 0 or min_processed < state.last_seen_rowid:
            # We're still working backwards, update the floor only if we went lower
            pass  # Don't update last_seen_rowid yet; we'll update it when scan completes
        
        # Track the highest ROWID we've ever seen
        max_processed = max(row_ids)
        if max_processed > state.max_seen_rowid:
            state.max_seen_rowid = max_processed
        # Update last_seen_rowid to the highest ROWID we've processed for new messages
        # This helps callers know we've advanced the head when posts succeed.
        if state.last_seen_rowid is None or max_processed > state.last_seen_rowid:
            state.last_seen_rowid = state.max_seen_rowid
    
    state.save()

    logger.info(
        success_event,
        count=len(events),
        last_seen_rowid=state.last_seen_rowid,
        max_seen_rowid=state.max_seen_rowid,
        batch_max_ts=batch_max_ts,
    )
    return True


def run_poll_loop(args: argparse.Namespace) -> None:
    state = CollectorState.load()
    logger.info(
        "starting_collector",
        last_seen_rowid=state.last_seen_rowid,
        max_seen_rowid=state.max_seen_rowid,
        min_seen_rowid=state.min_seen_rowid,
        initial_backlog_complete=state.initial_backlog_complete,
        endpoint=CATALOG_ENDPOINT,
        batch_size=BATCH_SIZE,
    )

    # Initialize sleep_seconds for dynamic cooldown logic
    sleep_seconds = POLL_INTERVAL_SECONDS
    last_activity = None
    while True:
        try:
            backup_path = backup_chat_db(args.chat_db)
            with sqlite3.connect(backup_path) as conn:
                # Propagate disable_images flag to helper functions via the connection
                try:
                    setattr(conn, "disable_images", bool(getattr(args, "disable_images", False)))
                except Exception:
                    pass
                current_max = get_current_max_rowid(conn)
                
                # Determine scan range based on state
                if not state.initial_backlog_complete:
                    # Initial backlog not complete - resume backwards scan
                    if state.max_seen_rowid == 0:
                        # First run ever
                        state.max_seen_rowid = current_max
                        state.min_seen_rowid = current_max
                        scan_ceiling = current_max
                        scan_floor = 0
                        logger.info(
                            "initial_backlog_starting",
                            current_max=current_max,
                        )
                    else:
                        # Resume interrupted backlog scan from where we left off
                        scan_ceiling = state.min_seen_rowid - 1
                        scan_floor = 0
                        logger.info(
                            "resuming_backlog_scan",
                            scan_ceiling=scan_ceiling,
                            min_seen_so_far=state.min_seen_rowid,
                        )
                    
                    # Scan backwards from ceiling to floor
                    scan_cursor = scan_ceiling
                    total_processed = 0
                    
                    while scan_cursor > scan_floor:
                        # Fetch batch: messages with ROWID > scan_floor AND <= scan_cursor
                        conn.row_factory = sqlite3.Row
                        cursor = conn.execute(
                            """
                            SELECT m.ROWID,
                                   m.guid,
                                   m.date,
                                   m.is_from_me,
                                   m.text,
                                   m.attributedBody AS attributed_body,
                                   h.id as handle_id,
                                   h.service,
                                   c.guid as chat_guid,
                                   c.display_name as chat_display_name,
                                   c.ROWID as chat_rowid,
                                   (
                                       SELECT COUNT(*)
                                       FROM message_attachment_join maj
                                       WHERE maj.message_id = m.ROWID
                                   ) as attachment_count
                            FROM message m
                            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                            JOIN chat c ON c.ROWID = cmj.chat_id
                            LEFT JOIN handle h ON h.ROWID = m.handle_id
                            WHERE m.ROWID > ? AND m.ROWID <= ?
                            ORDER BY m.ROWID DESC
                            LIMIT ?
                            """,
                            (scan_floor, scan_cursor, BATCH_SIZE),
                        )
                        
                        batch_events = []
                        for row in cursor.fetchall():
                            participants = get_participants(conn, row["chat_rowid"])
                            attachments = fetch_message_attachments(conn, row["ROWID"])
                            batch_events.append(
                                normalize_row(row, participants, attachments, disable_images=bool(getattr(args, "disable_images", False)))
                            )
                        
                        if not batch_events:
                            # No more messages in this range - backlog complete
                            state.initial_backlog_complete = True
                            state.last_seen_rowid = state.max_seen_rowid
                            state.save()
                            logger.info(
                                "initial_backlog_complete",
                                total_processed=total_processed,
                                max_seen_rowid=state.max_seen_rowid,
                            )
                            break
                        
                        # Process batch
                        if post_events(batch_events):
                            total_processed += len(batch_events)
                            # Update min_seen to lowest ROWID in this batch
                            min_rowid = min(evt.message["row_id"] for evt in batch_events)
                            state.min_seen_rowid = min_rowid
                            scan_cursor = min_rowid - 1
                            state.save()  # Save after each batch so we can resume
                            
                            logger.info(
                                "backlog_batch_dispatched",
                                count=len(batch_events),
                                scan_cursor=scan_cursor,
                                min_seen_rowid=state.min_seen_rowid,
                            )
                        else:
                            # Record activity time for cooldown logic
                            last_activity = datetime.now(timezone.utc)
                            logger.warning("batch_dispatch_failed", count=len(batch_events))
                            break
                    
                    # Check if we completed the backlog
                    if scan_cursor <= scan_floor and batch_events:
                        state.initial_backlog_complete = True
                        state.last_seen_rowid = state.max_seen_rowid
                        state.save()
                        logger.info(
                            "initial_backlog_complete",
                            total_processed=total_processed,
                            max_seen_rowid=state.max_seen_rowid,
                        )
                    
                else:
                    # Initial backlog complete - scan for new messages only
                    if current_max > state.max_seen_rowid:
                        # New messages detected
                        scan_ceiling = current_max
                        scan_floor = state.max_seen_rowid
                        old_max = state.max_seen_rowid
                        state.max_seen_rowid = current_max
                        
                        logger.info(
                            "new_messages_detected",
                            old_max=old_max,
                            new_max=current_max,
                        )
                        
                        # Scan backwards from new max to old max
                        scan_cursor = scan_ceiling
                        total_processed = 0
                        
                        while scan_cursor > scan_floor:
                            conn.row_factory = sqlite3.Row
                            cursor = conn.execute(
                                """
                                SELECT m.ROWID,
                                       m.guid,
                                       m.date,
                                       m.is_from_me,
                                       m.text,
                                       m.attributedBody AS attributed_body,
                                       h.id as handle_id,
                                       h.service,
                                       c.guid as chat_guid,
                                       c.display_name as chat_display_name,
                                       c.ROWID as chat_rowid,
                                       (
                                           SELECT COUNT(*)
                                           FROM message_attachment_join maj
                                           WHERE maj.message_id = m.ROWID
                                       ) as attachment_count
                                FROM message m
                                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                                JOIN chat c ON c.ROWID = cmj.chat_id
                                LEFT JOIN handle h ON h.ROWID = m.handle_id
                                WHERE m.ROWID > ? AND m.ROWID <= ?
                                ORDER BY m.ROWID DESC
                                LIMIT ?
                                """,
                                (scan_floor, scan_cursor, BATCH_SIZE),
                            )
                            
                            batch_events = []
                            for row in cursor.fetchall():
                                participants = get_participants(conn, row["chat_rowid"])
                                attachments = fetch_message_attachments(conn, row["ROWID"])
                                batch_events.append(
                                    normalize_row(row, participants, attachments, disable_images=bool(getattr(args, "disable_images", False)))
                                )
                            
                            if not batch_events:
                                break
                            
                            # Process batch
                            if post_events(batch_events):
                                total_processed += len(batch_events)
                                min_rowid = min(evt.message["row_id"] for evt in batch_events)
                                scan_cursor = min_rowid - 1
                                
                                # Record activity time when we dispatched new messages
                                last_activity = datetime.now(timezone.utc)
                                logger.info(
                                    "new_messages_batch_dispatched",
                                    count=len(batch_events),
                                    scan_cursor=scan_cursor,
                                    scan_floor=scan_floor,
                                )
                            else:
                                logger.warning("batch_dispatch_failed", count=len(batch_events))
                                break
                        
                        # Update last_seen to new max
                        state.last_seen_rowid = state.max_seen_rowid
                        state.save()
                        
                        if total_processed > 0:
                            logger.info(
                                "new_messages_scan_completed",
                                total_processed=total_processed,
                                last_seen_rowid=state.last_seen_rowid,
                            )
                    else:
                        # No new messages
                        logger.debug("no_new_messages", current_max=current_max)
                        # Compute dynamic cooldown sleep when backlog is complete.
                        if state.initial_backlog_complete:
                            sleep_seconds = compute_cooldown_sleep(last_activity, base=POLL_INTERVAL_SECONDS)
                            # If we've fully cooled down, emit a specific log event
                            if abs(sleep_seconds - 60.0) < 1e-6:
                                logger.info("collector_cooled_down", sleep_seconds=sleep_seconds)
                            else:
                                logger.debug(
                                    "poll_cooldown",
                                    sleep_seconds=round(sleep_seconds, 2),
                                )
                        else:
                            sleep_seconds = POLL_INTERVAL_SECONDS
                
        except Exception as exc:  # pragma: no cover - defensive logging
            logger.error("collector_error", error=str(exc))

        # Fall back to default if sleep_seconds wasn't set in the loop body
        try:
            time.sleep(sleep_seconds)
        except NameError:
            time.sleep(POLL_INTERVAL_SECONDS)


def simulate_message(text: str, sender: str = "me") -> None:
    now = datetime.now(timezone.utc).isoformat()
    doc_id = f"imessage:simulated:{int(time.time())}"
    event = SourceEvent(
        doc_id=doc_id,
        thread={
            "id": "simulated-thread",
            "kind": "imessage",
            "participants": [sender, "me"],
            "title": "Simulated",
        },
        message={
            "row_id": 0,
            "guid": doc_id,
            "thread_id": "simulated-thread",
            "ts": now,
            "sender": sender,
            "sender_service": "iMessage",
            "is_from_me": sender == "me",
            "text": text,
            "attrs": {},
        },
        chunks=[
            {
                "id": deterministic_chunk_id(doc_id, 0),
                "chunk_index": 0,
                "text": text,
                "meta": {"doc_id": doc_id, "ts": now, "thread_id": "simulated-thread"},
            }
        ],
    )
    if post_events([event]):
        logger.info("simulated_message_sent", text=text)
    else:
        logger.error("simulated_message_failed", text=text)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Haven iMessage collector")
    parser.add_argument(
        "--chat-db",
        type=Path,
        default=DEFAULT_CHAT_DB,
        help="Path to macOS chat.db database",
    )
    parser.add_argument(
        "--simulate",
        type=str,
        help="Send a simulated message payload instead of reading chat.db",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run a single poll iteration and exit",
    )
    parser.add_argument(
        "--clear-last-seen",
        action="store_true",
        help="Clear the stored last-seen state so the collector will start from zero",
    )
    parser.add_argument(
        "--nuke-db",
        action="store_true",
        help=(
            "Drop and recreate the Postgres catalog schema from schema/catalog_mvp.sql. "
            "This is destructive — use --force to skip confirmation."
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Bypass interactive confirmation prompts (use with --nuke-db).",
    )
    parser.add_argument(
        "--start-at-head",
        action="store_true",
        help=(
            "Initialize the stored last-seen ROWID to the current maximum ROWID in chat.db "
            "so the collector will skip the backlog and start at the head."
        ),
    )
    parser.add_argument(
        "--no-images",
        dest="disable_images",
        action="store_true",
        help="Disable image handling and replace images with the text '[image]'.",
    )
    return parser.parse_args()


def clear_last_seen_state() -> None:
    try:
        if STATE_FILE.exists():
            STATE_FILE.unlink()
            logger.info("cleared_last_seen_state", path=str(STATE_FILE))
        else:
            logger.info("no_last_seen_state_to_clear", path=str(STATE_FILE))
    except Exception as exc:
        logger.error("failed_clearing_last_seen", error=str(exc))


def nuke_database(force: bool = False) -> None:
    sql_path = PROJECT_ROOT / "schema" / "catalog_mvp.sql"
    if not sql_path.exists():
        logger.error("nuke_db_missing_sql", path=str(sql_path))
        raise FileNotFoundError(f"schema file not found: {sql_path}")

    if not force and sys.stdin.isatty():
        confirm = input(
            "This will DROP/RECREATE the catalog database schema. Type 'YES' to continue: "
        )
        if confirm.strip() != "YES":
            logger.info("nuke_db_aborted_by_user")
            return

    sql = sql_path.read_text()
    try:
        with get_connection(autocommit=True) as conn:
            # psycopg should accept executing the multi-statement SQL script
            try:
                conn.execute(sql)
            except Exception:
                # Fallback: attempt to execute statements individually
                with conn.cursor() as cur:
                    for stmt in sql.split(";"):
                        stmt = stmt.strip()
                        if not stmt:
                            continue
                        try:
                            cur.execute(stmt)
                        except Exception:
                            # best-effort: continue on statement errors
                            logger.debug("nuke_db_stmt_failed", stmt=stmt[:120])
        logger.info("nuke_db_completed")
    except Exception as exc:
        logger.error("nuke_db_failed", error=str(exc))
        raise


def start_at_head(chat_db: Path) -> None:
    """Set the stored last-seen ROWID to the current maximum ROWID in chat.db.

    This creates a backup of the live chat.db and inspects the backup to find
    the current highest ROWID in the messages table, then writes that value to
    the collector state so future polls start after that point.
    """
    try:
        backup_path = backup_chat_db(chat_db)
        with sqlite3.connect(backup_path) as conn:
            max_rowid = get_current_max_rowid(conn)

        state = CollectorState.load()
        state.last_seen_rowid = max_rowid
        state.max_seen_rowid = max_rowid
        state.min_seen_rowid = max_rowid
        state.initial_backlog_complete = True  # Skip backlog
        state.save()
        logger.info(
            "start_at_head_set",
            last_seen_rowid=state.last_seen_rowid,
            max_seen_rowid=state.max_seen_rowid,
            initial_backlog_complete=state.initial_backlog_complete,
        )
    except Exception as exc:
        logger.error("start_at_head_failed", error=str(exc))
        raise


def main() -> None:
    setup_logging()
    args = parse_args()

    # Administration flags: clearing state or nuking DB should run and exit
    if getattr(args, "clear_last_seen", False):
        clear_last_seen_state()
        # If user only wanted to clear state, exit now
        if not (getattr(args, "nuke_db", False) or getattr(args, "simulate", False) or getattr(args, "once", False)):
            return

    if getattr(args, "nuke_db", False):
        nuke_database(force=getattr(args, "force", False))
        # If nuke only, exit
        if not (getattr(args, "simulate", False) or getattr(args, "once", False)):
            return

    if getattr(args, "start_at_head", False):
        # initialize last_seen to current head and exit unless user also asked to run
        start_at_head(args.chat_db)
        if not (getattr(args, "nuke_db", False) or getattr(args, "clear_last_seen", False) or getattr(args, "simulate", False) or getattr(args, "once", False)):
            return

    if args.simulate:
        simulate_message(args.simulate)
        return

    if args.once:
        state = CollectorState.load()
        backup_path = backup_chat_db(args.chat_db)
        with sqlite3.connect(backup_path) as conn:
            # Propagate disable_images flag so fetch_new_messages can read it
            try:
                setattr(conn, "disable_images", bool(getattr(args, "disable_images", False)))
            except Exception:
                pass
            current_max = get_current_max_rowid(conn)
            
            # Determine if there are new messages to process
            if state.max_seen_rowid == 0:
                scan_floor = 0
                state.max_seen_rowid = current_max
            elif current_max > state.max_seen_rowid:
                scan_floor = state.max_seen_rowid
                state.max_seen_rowid = current_max
            else:
                logger.info("no_new_messages_once")
                return
            
            # Fetch one batch of messages in the range
            events = list(fetch_new_messages(conn, scan_floor, BATCH_SIZE))
            
        if events:
            process_events(
                state,
                events,
                success_event="dispatched_events_once",
                failure_event="dispatch_failed_once",
            )
            state.last_seen_rowid = state.max_seen_rowid
            state.save()
        else:
            logger.info("no_messages_in_range_once")
        return

    run_poll_loop(args)


if __name__ == "__main__":
    main()
