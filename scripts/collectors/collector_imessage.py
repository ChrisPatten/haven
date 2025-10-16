from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import plistlib
import shutil
import sqlite3
import sys
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from uuid import NAMESPACE_URL, uuid5

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import requests

from shared.db import get_connection
from shared.image_enrichment import (
    ImageEnrichmentCache,
    build_image_facets,
    enrich_image,
)
from shared.logging import get_logger, setup_logging

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
DEFAULT_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"
STATE_DIR = Path.home() / ".haven"
STATE_FILE = STATE_DIR / "imessage_collector_state.json"
VERSION_STATE_FILE = STATE_DIR / "imessage_versions.json"
CATALOG_ENDPOINT = os.getenv(
    "CATALOG_ENDPOINT", "http://localhost:8085/v1/ingest"
)
COLLECTOR_AUTH_TOKEN = os.getenv("AUTH_TOKEN") or os.getenv("CATALOG_TOKEN")
POLL_INTERVAL_SECONDS = float(os.getenv("COLLECTOR_POLL_INTERVAL", "5"))
BATCH_SIZE = int(os.getenv("COLLECTOR_BATCH_SIZE", "200"))

# Configurable placeholder text for image handling
IMAGE_PLACEHOLDER_TEXT = os.getenv("IMAGE_PLACEHOLDER_TEXT", "[image]")
IMAGE_MISSING_PLACEHOLDER_TEXT = os.getenv("IMAGE_MISSING_PLACEHOLDER_TEXT", "[image not available]")

# Image attachment detection
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

# Legacy endpoint (used only for logging)
CATALOG_IMAGE_ENDPOINT = os.getenv(
    "CATALOG_IMAGE_ENDPOINT", "http://localhost:8085/v1/catalog/images"
)

IMAGE_CACHE_FILE = STATE_DIR / "imessage_image_cache.json"

logger = get_logger("collector.imessage")


def _load_version_tracker() -> Dict[str, Dict[str, Any]]:
    if not VERSION_STATE_FILE.exists():
        return {}
    try:
        return json.loads(VERSION_STATE_FILE.read_text())
    except Exception:
        logger.warning("version_state_load_failed", path=str(VERSION_STATE_FILE))
        return {}


def _save_version_tracker(tracker: Dict[str, Dict[str, Any]]) -> None:
    try:
        VERSION_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        VERSION_STATE_FILE.write_text(json.dumps(tracker))
    except Exception:
        logger.warning("version_state_save_failed", path=str(VERSION_STATE_FILE), exc_info=True)


_version_tracker: Dict[str, Dict[str, Any]] = _load_version_tracker()


def deterministic_chunk_id(doc_id: str, chunk_index: int) -> str:
    return str(uuid5(NAMESPACE_URL, f"{doc_id}:{chunk_index}"))


def _truncate_text(value: Optional[str], limit: int = 512) -> str:
    if not value:
        return ""
    if len(value) <= limit:
        return value
    return value[: limit - 1] + "\u2026"


def _infer_identifier_type(identifier: str) -> str:
    cleaned = identifier or ""
    if cleaned.startswith("+") and cleaned[1:].replace(" ", "").isdigit():
        return "phone"
    digits = "".join(ch for ch in cleaned if ch.isdigit())
    if digits and abs(len(digits) - len(cleaned.strip())) <= 2:
        return "phone"
    if "@" in cleaned:
        return "email"
    return "imessage"


def _build_people(sender: Optional[str], participants: List[str], *, is_from_me: bool) -> List[Dict[str, Any]]:
    people: List[Dict[str, Any]] = []
    if sender and sender != "me":
        people.append(
            {
                "identifier": sender,
                "identifier_type": _infer_identifier_type(sender),
                "role": "sender" if not is_from_me else "recipient",
            }
        )
    for participant in participants:
        if participant == sender:
            continue
        role = "recipient" if not is_from_me else "recipient"
        people.append(
            {
                "identifier": participant,
                "identifier_type": _infer_identifier_type(participant),
                "role": role,
            }
        )
    return people


def _build_thread_participants(participants: List[str]) -> List[Dict[str, Any]]:
    payload: List[Dict[str, Any]] = []
    for participant in participants:
        payload.append(
            {
                "identifier": participant,
                "identifier_type": _infer_identifier_type(participant),
                "role": "participant",
            }
        )
    return payload


def _compute_file_sha256(path: Path) -> Optional[str]:
    try:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(8192), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except FileNotFoundError:
        return None
    except Exception:
        logger.debug("attachment_sha_failed", path=str(path), exc_info=True)
        return None


def _build_event_signature(event: "SourceEvent") -> Dict[str, Any]:
    message = event.message or {}
    attrs = message.get("attrs") or {}
    signature = {
        "text_sha": message.get("text_sha256"),
        "attachment_count": attrs.get("attachment_count"),
        "attachment_shas": [
            att.get("file", {}).get("content_sha256")
            for att in event.attachments
            if isinstance(att, dict)
        ],
        "ts": message.get("ts"),
    }
    return signature


def _should_emit_event(event: "SourceEvent") -> bool:
    current = _build_event_signature(event)
    previous = _version_tracker.get(event.doc_id)
    if previous == current:
        return False
    return True


def _register_event_version(event: "SourceEvent") -> None:
    _version_tracker[event.doc_id] = _build_event_signature(event)


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
    attachments: List[Dict[str, Any]] = field(default_factory=list)
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

        text_body = "\n\n".join(parts).strip()
        if not text_body:
            text_body = f"[empty message {self.doc_id}]"

        text_sha = hashlib.sha256(text_body.encode("utf-8")).hexdigest()

        ts_iso = self.message.get("ts")
        if ts_iso:
            try:
                content_ts = datetime.fromisoformat(ts_iso)
            except ValueError:
                content_ts = datetime.now(timezone.utc)
                ts_iso = content_ts.isoformat()
        else:
            content_ts = datetime.now(timezone.utc)
            ts_iso = content_ts.isoformat()

        is_from_me = bool(self.message.get("is_from_me"))
        sender = self.message.get("sender")
        participants = self.thread.get("participants", [])
        people = _build_people(sender, participants, is_from_me=is_from_me)
        for person in people:
            if "display_name" not in person and person.get("identifier") == "me":
                person["display_name"] = "Me"

        thread_external_id = f"imessage:{self.thread.get('id')}"
        thread_participants = _build_thread_participants(participants)
        is_group = len(participants) > 1
        thread_payload = {
            "external_id": thread_external_id,
            "source_type": "imessage",
            "source_provider": "apple_messages",
            "title": self.thread.get("title"),
            "participants": thread_participants,
            "thread_type": "group" if is_group else "direct",
            "is_group": is_group,
            "participant_count": len(thread_participants),
            "metadata": {
                "chat_guid": self.thread.get("id"),
            },
            "last_message_at": ts_iso,
        }

        attachments_payload = self.attachments or []
        has_attachments = bool(attachments_payload)
        attachment_count = len(attachments_payload)

        metadata = {
            "source": "imessage",
            "ingested_at": datetime.now(timezone.utc).isoformat(),
            "thread": self.thread,
            "message": self.message,
            "chunks": self.chunks,
            "attachments": attachments_payload,
            "text_sha256": text_sha,
        }

        payload: Dict[str, Any] = {
            "idempotency_key": f"{self.doc_id}:{text_sha}",
            "source_type": "imessage",
            "source_provider": "apple_messages",
            "source_id": self.doc_id,
            "external_id": self.doc_id,
            "title": self.thread.get("title"),
            "canonical_uri": None,
            "content": {"mime_type": "text/plain", "data": text_body},
            "metadata": metadata,
            "content_timestamp": ts_iso,
            "content_timestamp_type": "sent" if is_from_me else "received",
            "people": people,
            "thread": thread_payload,
            "facet_overrides": {
                "has_attachments": has_attachments,
                "attachment_count": attachment_count,
            },
        }

        if attachments_payload:
            payload["attachments"] = attachments_payload

        return payload


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


def datetime_to_apple_epoch(dt: datetime) -> int:
    """Convert a datetime to Apple epoch timestamp (nanoseconds since 2001-01-01).
    
    Args:
        dt: datetime object (will be converted to UTC if needed)
        
    Returns:
        Integer timestamp in nanoseconds since Apple epoch (2001-01-01 00:00:00 UTC)
    """
    # Ensure datetime is timezone-aware
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.astimezone(timezone.utc)
    
    # Calculate delta from Apple epoch
    delta = dt - APPLE_EPOCH
    
    # Convert to nanoseconds (chat.db stores as nanoseconds)
    nanoseconds = int(delta.total_seconds() * 1_000_000_000)
    
    return nanoseconds


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

    # Try standard plistlib first (XML/binary plist formats)
    try:
        archive = plistlib.loads(data)
    except Exception:
        # Try biplist for additional binary plist variants
        try:
            import biplist
            archive = biplist.readPlistFromString(data)
        except ImportError:
            logger.debug("attributed_body_decode_failed", reason="biplist not installed, install with: pip install biplist")
            return ""
        except biplist.InvalidPlistException:
            # This is likely NSKeyedArchiver streamtyped format
            # Try to extract text directly from the binary data as a fallback
            try:
                # Look for UTF-8 text strings in the binary data
                # NSAttributedString often embeds the plain text directly
                decoded_str = data.decode('utf-8', errors='ignore')
                # Remove null bytes and control characters
                cleaned = ''.join(char for char in decoded_str if char.isprintable() or char in '\n\r\t')
                # Extract the longest contiguous text segment (likely the actual message)
                segments = [s.strip() for s in cleaned.split('\x00') if len(s.strip()) > 10]
                if segments:
                    result = max(segments, key=len)
                    logger.debug("attributed_body_decoded_via_heuristic", length=len(result))
                    return result.strip('\x00')
            except Exception:
                pass
            logger.debug("attributed_body_decode_failed", reason="unsupported NSKeyedArchiver format")
            return ""
        except Exception as e:
            logger.debug("attributed_body_decode_failed", reason=str(e))
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


def extract_attributed_body_attributes(blob: Optional[bytes]) -> Dict[str, Any]:
    """Extract attributes from NSKeyedArchiver attributed body.
    
    Returns a dictionary with:
    - text: The extracted plain text
    - is_emoji_image: Boolean, True if __kIMEmojiImageAttributeName is present
    - is_rich_link: Boolean, True if __kIMLinkIsRichLinkAttributeName is present
    - has_text_effect: Boolean, True if __kIMTextEffectAttributeName is present
    - has_bold: Boolean, True if __kIMTextBoldAttributeName is present
    - has_italic: Boolean, True if __kIMTextItalicAttributeName is present
    - file_transfer_guids: List of attachment GUIDs referenced
    """
    result: Dict[str, Any] = {
        "text": "",
        "is_emoji_image": False,
        "is_rich_link": False,
        "has_text_effect": False,
        "has_bold": False,
        "has_italic": False,
        "file_transfer_guids": [],
    }
    
    if not blob:
        return result
    
    try:
        data = bytes(blob)
    except Exception:
        return result
    
    # Try to decode as UTF-8 for pattern matching
    try:
        decoded_str = data.decode('utf-8', errors='ignore')
    except Exception:
        return result
    
    # Check for attributes
    result["is_emoji_image"] = '__kIMEmojiImageAttributeName' in decoded_str
    result["is_rich_link"] = '__kIMLinkIsRichLinkAttributeName' in decoded_str
    result["has_text_effect"] = '__kIMTextEffectAttributeName' in decoded_str
    result["has_bold"] = '__kIMTextBoldAttributeName' in decoded_str
    result["has_italic"] = '__kIMTextItalicAttributeName' in decoded_str
    
    # Extract text - try streamtyped format first
    if 'streamtyped' in decoded_str and '+' in decoded_str:
        try:
            start = decoded_str.find('+') + 1
            if start > 0:
                end = decoded_str.find('\x02', start)
                if end == -1:
                    end = decoded_str.find('\x00', start)
                if end > start:
                    candidate = decoded_str[start:end]
                    # Skip length prefix if present (single byte)
                    if candidate and ord(candidate[0]) < 32:
                        candidate = candidate[1:]
                    if candidate and not any(x in candidate for x in ['NSObject', 'NSString', 'NSDictionary']):
                        result["text"] = candidate.strip()
                        return result
        except Exception:
            pass
    
    # Fallback to existing decode_attributed_body logic
    if not result["text"]:
        result["text"] = decode_attributed_body(blob)
    
    return result


def is_sticker_message(row_data: Dict[str, Any]) -> bool:
    """Check if a message is a sticker (type 1000)."""
    return row_data.get("associated_message_type") == 1000


def is_reaction_message(row_data: Dict[str, Any]) -> bool:
    """Check if a message is a reaction/tapback (types 2000-2005).
    
    iMessage reaction types:
    - 2000: Love
    - 2001: Like  
    - 2002: Dislike
    - 2003: Laugh
    - 2004: Emphasize
    - 2005: Question
    """
    msg_type = row_data.get("associated_message_type")
    return msg_type is not None and 2000 <= msg_type <= 2005


def is_voice_message(row_data: Dict[str, Any]) -> bool:
    """Check if a message is a voice message."""
    return bool(row_data.get("is_audio_message"))


def is_expired_voice_message(row_data: Dict[str, Any]) -> bool:
    """Check if a voice message has expired (expire_state == 1)."""
    return row_data.get("expire_state") == 1


def is_icloud_link(text: Optional[str]) -> bool:
    """Check if text contains an iCloud link."""
    if not text:
        return False
    return 'icloud.com/iclouddrive' in text.lower()


def get_parent_message_text(conn: sqlite3.Connection, parent_guid: str) -> Optional[str]:
    """Fetch the text of a parent message by GUID."""
    try:
        cursor = conn.execute(
            "SELECT text, attributedBody FROM message WHERE guid = ?",
            (parent_guid,)
        )
        row = cursor.fetchone()
        if row:
            text = (row[0] or "").strip()
            if not text:
                # Extract from attributed body
                attrs = extract_attributed_body_attributes(row[1])
                extracted = attrs.get("text", "")
                
                # Try extracting text from streamtyped format: text is between + and \x02
                if extracted and 'streamtyped' in extracted and '+' in extracted:
                    try:
                        start = extracted.find('+') + 1
                        if start > 0:
                            end = extracted.find('\x02', start)
                            if end == -1:
                                end = extracted.find('\x00', start)
                            if end > start:
                                candidate = extracted[start:end]
                                # Skip length prefix if present
                                if candidate and ord(candidate[0]) < 32:
                                    candidate = candidate[1:]
                                if candidate and not any(x in candidate for x in ['NSObject', 'NSString', 'NSDictionary']):
                                    text = candidate.strip()
                    except Exception:
                        pass
                
                # Fallback to cleaned extraction
                if not text and extracted and not any(x in extracted for x in ['streamtyped', 'NSObject', 'NSDictionary']):
                    text = extracted
            
            return text[:100] if text else None
        return None
    except Exception:
        logger.debug("parent_message_lookup_failed", parent_guid=parent_guid, exc_info=True)
        return None


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


def _truncate_caption(value: Optional[str], limit: int = 200) -> str:
    """Keep for backwards compatibility - delegates to shared module."""
    if not value:
        return ""
    caption = value.strip()
    if len(caption) <= limit:
        return caption
    return caption[: limit - 1] + "\u2026"


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


def enrich_image_attachment(
    metadata: Dict[str, Any],
    tmp_dir: Path,
    *,
    thread_id: str,
    message_guid: str,
    cache: ImageEnrichmentCache,
) -> Tuple[Optional[Dict[str, Any]], Optional[Dict[str, Any]], str]:
    """Enrich an image attachment with OCR and caption.
    
    Returns:
        Tuple of (enriched_attachment, image_event, placeholder_text)
        - If enrichment succeeds, placeholder_text is empty string and dicts are populated
        - If image is missing, placeholder_text is IMAGE_MISSING_PLACEHOLDER_TEXT and dicts are None
        - If enrichment fails, placeholder_text is IMAGE_PLACEHOLDER_TEXT and dicts are None
        - If not an image, returns (None, None, "")
    """
    if not _is_image_attachment(metadata):
        return None, None, ""

    # Resolve the attachment path
    source = _resolve_attachment_path(metadata.get("filename"))
    if source is None or not source.exists():
        transfer_name = metadata.get("transfer_name")
        alt_source = _resolve_attachment_path(transfer_name) if transfer_name else None
        if alt_source is not None and alt_source.exists():
            source = alt_source

    # Check if image file exists on disk before attempting enrichment
    if source is None or not source.exists():
        logger.debug(
            "attachment_file_missing",
            row_id=metadata.get("row_id"),
            filename=metadata.get("filename"),
        )
        # Return placeholder text instead of None so caller knows to add placeholder
        return None, None, IMAGE_MISSING_PLACEHOLDER_TEXT

    # Copy to temp directory for processing
    copied = _copy_attachment_to_temp(
        source, tmp_dir, row_id=metadata.get("row_id", "attachment")
    )
    if copied is None:
        # File copy failed (shouldn't happen since we checked exists above)
        logger.debug(
            "attachment_copy_failed_after_exists_check",
            row_id=metadata.get("row_id"),
            filename=metadata.get("filename"),
        )
        return None, None, IMAGE_MISSING_PLACEHOLDER_TEXT

    # Use shared enrichment module with persistent cache
    cache_dict = cache.get_data_dict()
    try:
        result = enrich_image(copied, cache_dict=cache_dict)
        cache.save()  # Persist any cache updates
    except Exception:
        logger.warning(
            "image_enrichment_exception",
            row_id=metadata.get("row_id"),
            path=str(copied),
            exc_info=True,
        )
        return None, None, IMAGE_PLACEHOLDER_TEXT

    if result is None:
        # Enrichment returned None (unexpected but handle gracefully)
        logger.debug(
            "image_enrichment_returned_none",
            row_id=metadata.get("row_id"),
            path=str(copied),
        )
        return None, None, IMAGE_PLACEHOLDER_TEXT

    blob_id = result["blob_id"]
    caption = _truncate_caption(result.get("caption"))
    ocr_text = result.get("ocr_text", "")
    ocr_boxes = result.get("ocr_boxes", [])
    ocr_entities = result.get("ocr_entities", {})

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

    facets = build_image_facets(ocr_entities)
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

    return enriched, image_event, ""  # Empty placeholder means enrichment succeeded


def enrich_image_attachments(
    attachments: Optional[List[Dict[str, Any]]],
    *,
    thread_id: str,
    message_guid: str,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]], List[str]]:
    """Enrich image attachments and return enriched data plus any placeholder texts.
    
    Returns:
        Tuple of (enriched_attachments, image_events, placeholder_texts)
        - placeholder_texts contains one entry per attachment that failed/missing
    """
    if not attachments:
        return [], [], []

    enriched: List[Dict[str, Any]] = []
    image_events: List[Dict[str, Any]] = []
    placeholders: List[str] = []
    cache = get_image_cache()
    
    with tempfile.TemporaryDirectory() as tmp_dir_str:
        tmp_dir = Path(tmp_dir_str)
        for metadata in attachments:
            try:
                enriched_data, event_data, placeholder = enrich_image_attachment(
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
                # Add generic placeholder on unexpected exception
                placeholders.append(IMAGE_PLACEHOLDER_TEXT)
                continue
            
            if enriched_data is not None and event_data is not None:
                # Enrichment succeeded
                enriched.append(enriched_data)
                image_events.append(event_data)
            elif placeholder:
                # Enrichment failed or image missing - add placeholder
                placeholders.append(placeholder)

    cache.save()

    return enriched, image_events, placeholders


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
    conn: Optional[sqlite3.Connection] = None,
) -> SourceEvent:
    # Extract attributed body attributes early
    attr_body_attrs = extract_attributed_body_attributes(row["attributed_body"])
    
    # Build row_data dict for helper functions (sqlite3.Row doesn't have .get(), use try/except)
    def safe_get(row_obj: sqlite3.Row, key: str) -> Any:
        try:
            return row_obj[key]
        except (KeyError, IndexError):
            return None
    
    row_data = {
        "associated_message_type": safe_get(row, "associated_message_type"),
        "associated_message_guid": safe_get(row, "associated_message_guid"),
        "associated_message_range_location": safe_get(row, "associated_message_range_location"),
        "associated_message_range_length": safe_get(row, "associated_message_range_length"),
        "reply_to_guid": safe_get(row, "reply_to_guid"),
        "thread_originator_guid": safe_get(row, "thread_originator_guid"),
        "expressive_send_style_id": safe_get(row, "expressive_send_style_id"),
        "is_audio_message": safe_get(row, "is_audio_message"),
        "expire_state": safe_get(row, "expire_state"),
    }
    
    text = (row["text"] or "").strip()
    original_text_empty = not text
    
    # Handle special message types
    if is_sticker_message(row_data) and conn:
        # Sticker message - format with parent context
        parent_guid = row_data["associated_message_guid"]
        parent_text = get_parent_message_text(conn, parent_guid) if parent_guid else None
        
        # Determine sticker type from attachment
        sticker_type = "sticker"
        if attachments and len(attachments) > 0:
            mime = attachments[0].get("mime_type", "")
            if "heic" in mime.lower():
                sticker_type = "memoji sticker"
            elif "png" in mime.lower():
                sticker_type = "emoji sticker"
        
        if parent_text:
            text = f"[Applied {sticker_type} to: \"{parent_text}\"]"
        else:
            text = f"[Applied {sticker_type} to message]"
    
    elif is_voice_message(row_data):
        # Voice message - indicate expired status
        if is_expired_voice_message(row_data):
            text = "[Voice message - expired]"
        else:
            text = "[Voice message - saved]"
        # Mark as handled so we don't add image placeholders later
        original_text_empty = False
    
    elif attr_body_attrs.get("is_emoji_image") and attachments and len(attachments) > 0:
        # Standalone emoji/memoji image
        text = "[Sent memoji/emoji]"
        # Mark as handled so we don't add image placeholders later
        original_text_empty = False
    
    elif is_icloud_link(text):
        # iCloud document link
        # Keep the URL but add context
        text = f"[Shared document via iCloud: {text}]"
    
    elif not text:
        # No text in main field, try attributed body
        extracted = attr_body_attrs.get("text", "")
        # Clean up any NSKeyedArchiver artifacts
        if extracted:
            # Try extracting text from streamtyped format: text is between + and \x02
            if 'streamtyped' in extracted and '+' in extracted:
                try:
                    # Find text between + and the next control character
                    start = extracted.find('+') + 1
                    if start > 0:
                        # Look for the text before control characters
                        end = extracted.find('\x02', start)
                        if end == -1:
                            end = extracted.find('\x00', start)
                        if end > start:
                            candidate = extracted[start:end]
                            # Skip length prefix if present (single byte)
                            if candidate and ord(candidate[0]) < 32:
                                candidate = candidate[1:]
                            if candidate and not any(x in candidate for x in ['NSObject', 'NSString', 'NSDictionary']):
                                text = candidate.strip()
                except Exception:
                    pass
            
            # Fallback: try the original heuristic if streamtyped extraction didn't work
            if not text and not any(x in extracted for x in ['streamtyped', 'NSObject', 'NSDictionary']):
                text = extracted
    
    # Handle threaded reply messages (but not reactions or stickers)
    # Note: reply_to_guid is set for sequential messages, but thread_originator_guid
    # is only set when user explicitly taps "Reply" on a specific message
    if (row_data.get("thread_originator_guid") and conn 
        and not is_sticker_message(row_data) 
        and not is_reaction_message(row_data)):
        parent_guid = row_data["thread_originator_guid"]
        parent_text = get_parent_message_text(conn, parent_guid) if parent_guid else None
        if parent_text and text and not text.startswith("["):
            # Only prepend "Replied to" for explicitly threaded messages
            text = f"Replied to \"{parent_text}\" with: {text}"
    
    # Fallback if still no text
    if not text:
        attachment_count = row["attachment_count"]
        if attachment_count:
            # Format attachment count message
            if attachment_count == 1:
                text = f"[1 attachment]"
            else:
                text = f"[{attachment_count} attachments]"
    
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
    
    # Preserve threading metadata
    if row_data.get("reply_to_guid"):
        message["attrs"]["reply_to_guid"] = row_data["reply_to_guid"]
    if row_data.get("thread_originator_guid"):
        message["attrs"]["thread_originator_guid"] = row_data["thread_originator_guid"]
    if row_data.get("associated_message_guid"):
        message["attrs"]["associated_message_guid"] = row_data["associated_message_guid"]
        message["attrs"]["associated_message_type"] = row_data["associated_message_type"]
    if row_data.get("is_audio_message"):
        message["attrs"]["is_audio_message"] = True
        message["attrs"]["expire_state"] = row_data.get("expire_state")
    if row_data.get("expressive_send_style_id"):
        message["attrs"]["expressive_send_style_id"] = row_data["expressive_send_style_id"]
    
    # Preserve attributed body attributes
    if attr_body_attrs.get("is_emoji_image"):
        message["attrs"]["is_emoji_image"] = True
    if attr_body_attrs.get("is_rich_link"):
        message["attrs"]["is_rich_link"] = True
    if attr_body_attrs.get("has_text_effect"):
        message["attrs"]["has_text_effect"] = True
    if attr_body_attrs.get("has_bold"):
        message["attrs"]["has_bold"] = True
    if attr_body_attrs.get("has_italic"):
        message["attrs"]["has_italic"] = True

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
    
    # Enhanced attachment formatting for multiple attachments
    if attachments and len(attachments) > 1 and original_text_empty and not is_sticker_message(row_data):
        # Multiple attachments with no original text - format nicely
        attachment_names = []
        image_count = 0
        doc_count = 0
        
        for att in attachments:
            name = att.get("transfer_name") or att.get("filename", "attachment")
            attachment_names.append(name)
            
            # Count types
            if _is_image_attachment(att):
                image_count += 1
            else:
                doc_count += 1
        
        # Build descriptive text
        parts = []
        if image_count > 0:
            parts.append(f"{image_count} {'photo' if image_count == 1 else 'photos'}")
        if doc_count > 0:
            parts.append(f"{doc_count} {'document' if doc_count == 1 else 'documents'}")
        
        summary = " and ".join(parts)
        text = f"[Sent {summary}]"
        chunks[0]["text"] = text

    image_events: List[Dict[str, Any]] = []
    enriched_attachments: List[Dict[str, Any]] = []
    image_placeholders: List[str] = []

    if not disable_images:
        enriched_attachments, image_events, image_placeholders = enrich_image_attachments(
            attachments,
            thread_id=row["chat_guid"],
            message_guid=row["guid"],
        )
        
        # If we have placeholders (images that failed or were missing), add them to text
        # BUT: Don't override the "Sent N photos" summary text
        if image_placeholders and not (text and text.startswith("[Sent ") and "photo" in text):
            placeholder_text = " ".join(image_placeholders)
            if text and not text.startswith("[") and not text.endswith("attachment(s) omitted]"):
                text = f"{text} {placeholder_text}"
            else:
                # No original text or only placeholder - use placeholders as main text
                text = placeholder_text
            # Update first chunk's text
            chunks[0]["text"] = text
    else:
        # When image handling is disabled, replace any image attachments with
        # a placeholder text. Do not perform enrichment or produce image events.
        if attachments and not is_sticker_message(row_data):
            # Count image attachments
            image_count = 0
            for meta in attachments:
                try:
                    if _is_image_attachment(meta):
                        image_count += 1
                except Exception:
                    continue

            # Don't add placeholders if we already have formatted text for:
            # - Multiple photos: "[Sent N photos]"
            # - Emoji/memoji: "[Sent memoji/emoji]"
            # - Voice messages: "[Voice message - ...]"
            has_formatted_text = text and (
                (text.startswith("[Sent ") and ("photo" in text or "memoji" in text or "emoji" in text)) or
                text.startswith("[Voice message")
            )
            
            if image_count and not has_formatted_text:
                placeholders = " ".join([IMAGE_PLACEHOLDER_TEXT for _ in range(image_count)])
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

    # Ensure message text reflects latest mutations (placeholders, enrichment, etc.)
    message["text"] = text

    text_sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
    message["text_sha256"] = text_sha

    attachments_list = attachments or []
    attachment_payloads: List[Dict[str, Any]] = []
    enriched_by_guid = {
        enriched.get("guid"): enriched for enriched in enriched_attachments if enriched.get("guid")
    }
    for index, attachment_meta in enumerate(attachments_list):
        candidate_path = _resolve_attachment_path(attachment_meta.get("filename"))
        if (candidate_path is None or not candidate_path.exists()) and attachment_meta.get("transfer_name"):
            candidate_path = _resolve_attachment_path(attachment_meta.get("transfer_name"))

        size_bytes: Optional[int] = None
        content_sha = None
        object_key = None
        if candidate_path and candidate_path.exists():
            object_key = str(candidate_path)
            try:
                size_bytes = candidate_path.stat().st_size
            except OSError:
                size_bytes = attachment_meta.get("total_bytes")
            content_sha = _compute_file_sha256(candidate_path)
        else:
            size_bytes = attachment_meta.get("total_bytes")

        enrichment = enriched_by_guid.get(attachment_meta.get("guid"))
        image_data = enrichment.get("image") if enrichment else None
        caption = image_data.get("caption") if isinstance(image_data, dict) else None
        enrichment_status = "enriched" if image_data else ("missing" if object_key is None else "pending")
        enrichment_payload = image_data if isinstance(image_data, dict) else None

        file_payload = {
            "content_sha256": content_sha,
            "object_key": object_key,
            "storage_backend": "local",
            "filename": attachment_meta.get("filename") or attachment_meta.get("transfer_name"),
            "mime_type": attachment_meta.get("mime_type"),
            "size_bytes": size_bytes,
            "enrichment_status": enrichment_status,
            "enrichment": enrichment_payload,
        }
        file_payload = {key: value for key, value in file_payload.items() if value is not None}

        attachment_payloads.append(
            {
                "role": "attachment",
                "attachment_index": index,
                "filename": file_payload.get("filename"),
                "caption": caption,
                "file": file_payload,
            }
        )

    if attachment_payloads:
        message["attrs"]["attachment_content_sha256"] = [
            item.get("file", {}).get("content_sha256") for item in attachment_payloads
        ]

    return SourceEvent(
        doc_id=doc_id,
        thread=thread,
        message=message,
        chunks=chunks,
        attachments=attachment_payloads,
        image_events=image_events,
    )


def fetch_new_messages(
    conn: sqlite3.Connection, last_seen: int, batch_size: int, min_timestamp: Optional[int] = None
) -> Iterable[SourceEvent]:
    """Fetch messages with ROWID > last_seen, in descending order.
    
    This returns the most recent messages first, working backwards.
    
    Args:
        conn: SQLite connection to chat.db
        last_seen: Minimum ROWID to fetch (exclusive)
        batch_size: Maximum number of messages to fetch
        min_timestamp: Optional minimum date timestamp (Apple epoch nanoseconds). 
                      If provided, only messages with date >= min_timestamp are fetched.
    """
    conn.row_factory = sqlite3.Row
    
    # Build query with optional date filter
    query = """
        SELECT m.ROWID,
               m.guid,
               m.date,
               m.is_from_me,
               m.text,
               m.attributedBody AS attributed_body,
               m.associated_message_guid,
               m.associated_message_type,
               m.associated_message_range_location,
               m.associated_message_range_length,
               m.reply_to_guid,
               m.thread_originator_guid,
               m.expressive_send_style_id,
               m.is_audio_message,
               m.expire_state,
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
    """
    
    params: List[Any] = [last_seen]
    
    if min_timestamp is not None:
        query += " AND m.date >= ?"
        params.append(min_timestamp)
    
    query += """
        ORDER BY m.ROWID DESC
        LIMIT ?
    """
    params.append(batch_size)
    
    cursor = conn.execute(query, tuple(params))

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

        event = normalize_row(row, participants, attachments, disable_images=disable_images, conn=conn)
        if not _should_emit_event(event):
            logger.debug("skipping_unchanged_version", doc_id=event.doc_id)
            continue
        yield event


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

    for event in events:
        _register_event_version(event)
    _save_version_tracker(_version_tracker)

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
    
    # Parse lookback argument if provided
    min_timestamp: Optional[int] = None
    skip_version_check = False  # Flag to bypass version tracker when using --lookback
    if hasattr(args, 'lookback') and args.lookback:
        try:
            lookback_delta = parse_time_bound(args.lookback)
            cutoff_datetime = datetime.now(timezone.utc) - lookback_delta
            min_timestamp = datetime_to_apple_epoch(cutoff_datetime)
            skip_version_check = True  # Bypass version tracking in lookback mode
            logger.info(
                "lookback_enabled",
                lookback=args.lookback,
                cutoff_datetime=cutoff_datetime.isoformat(),
                min_timestamp=min_timestamp,
                skip_version_check=skip_version_check,
            )
        except ValueError as e:
            logger.error("invalid_lookback_format", error=str(e))
            raise
    
    logger.info(
        "starting_collector",
        last_seen_rowid=state.last_seen_rowid,
        max_seen_rowid=state.max_seen_rowid,
        min_seen_rowid=state.min_seen_rowid,
        initial_backlog_complete=state.initial_backlog_complete,
        endpoint=CATALOG_ENDPOINT,
        batch_size=BATCH_SIZE,
        lookback=getattr(args, 'lookback', None),
        skip_version_check=skip_version_check,
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
                    batch_events = []
                    
                    while scan_cursor > scan_floor:
                        # Fetch batch: messages with ROWID > scan_floor AND <= scan_cursor
                        conn.row_factory = sqlite3.Row
                        
                        # Build query with optional date filter
                        query = """
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
                        """
                        
                        params: List[Any] = [scan_floor, scan_cursor]
                        
                        if min_timestamp is not None:
                            query += " AND m.date >= ?"
                            params.append(min_timestamp)
                        
                        query += """
                            ORDER BY m.ROWID DESC
                            LIMIT ?
                        """
                        params.append(BATCH_SIZE)
                        
                        cursor = conn.execute(query, tuple(params))
                        
                        batch_events = []
                        for row in cursor.fetchall():
                            participants = get_participants(conn, row["chat_rowid"])
                            attachments = fetch_message_attachments(conn, row["ROWID"])
                            event = normalize_row(
                                row,
                                participants,
                                attachments,
                                disable_images=bool(getattr(args, "disable_images", False)),
                            )
                            # Skip version check when using --lookback mode
                            if not skip_version_check and not _should_emit_event(event):
                                logger.debug(
                                    "skipping_unchanged_version",
                                    doc_id=event.doc_id,
                                )
                                continue
                            batch_events.append(event)
                        
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
                        batch_events = []
                        
                        while scan_cursor > scan_floor:
                            conn.row_factory = sqlite3.Row
                            
                            # Build query with optional date filter
                            query = """
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
                            """
                            
                            params: List[Any] = [scan_floor, scan_cursor]
                            
                            if min_timestamp is not None:
                                query += " AND m.date >= ?"
                                params.append(min_timestamp)
                            
                            query += """
                                ORDER BY m.ROWID DESC
                                LIMIT ?
                            """
                            params.append(BATCH_SIZE)
                            
                            cursor = conn.execute(query, tuple(params))
                            
                            batch_events = []
                            for row in cursor.fetchall():
                                participants = get_participants(conn, row["chat_rowid"])
                                attachments = fetch_message_attachments(conn, row["ROWID"])
                                event = normalize_row(
                                    row,
                                    participants,
                                    attachments,
                                    disable_images=bool(getattr(args, "disable_images", False)),
                                )
                                # Skip version check when using --lookback mode
                                if not skip_version_check and not _should_emit_event(event):
                                    logger.debug(
                                        "skipping_unchanged_version",
                                        doc_id=event.doc_id,
                                    )
                                    continue
                                batch_events.append(event)
                            
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


def parse_time_bound(time_str: str) -> timedelta:
    """Parse a time bound string like '12h' or '5d' into a timedelta.
    
    Supported units:
    - h: hours
    - d: days
    - m: minutes
    - s: seconds
    
    Args:
        time_str: String like "12h", "5d", "30m", "3600s"
        
    Returns:
        timedelta object representing the duration
        
    Raises:
        ValueError: If the format is invalid
    """
    time_str = time_str.strip().lower()
    if not time_str:
        raise ValueError("Time bound cannot be empty")
    
    # Extract numeric part and unit
    unit = time_str[-1]
    try:
        value = float(time_str[:-1])
    except ValueError:
        raise ValueError(f"Invalid time bound format: {time_str}. Expected format like '12h' or '5d'")
    
    if value <= 0:
        raise ValueError(f"Time bound must be positive: {time_str}")
    
    # Convert to timedelta
    if unit == 'h':
        return timedelta(hours=value)
    elif unit == 'd':
        return timedelta(days=value)
    elif unit == 'm':
        return timedelta(minutes=value)
    elif unit == 's':
        return timedelta(seconds=value)
    else:
        raise ValueError(f"Invalid time unit '{unit}'. Supported units: h (hours), d (days), m (minutes), s (seconds)")


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
        help="Run a single poll iteration and exit (use with --lookback for single-batch behavior)",
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
    parser.add_argument(
        "--lookback",
        type=str,
        help=(
            "Set a time bound for how far back to collect messages. "
            "Examples: '12h' (12 hours), '5d' (5 days), '30m' (30 minutes), '3600s' (3600 seconds). "
            "Only messages newer than this duration from now will be collected. "
            "Automatically enables --once mode for single-iteration collection."
        ),
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
    
    # Note: --lookback no longer automatically enables --once mode
    # This allows the collector to scan through all batches within the lookback period
    # If you want single-batch behavior, explicitly pass --once along with --lookback

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
        
        # Parse lookback argument if provided
        min_timestamp: Optional[int] = None
        if hasattr(args, 'lookback') and args.lookback:
            try:
                lookback_delta = parse_time_bound(args.lookback)
                cutoff_datetime = datetime.now(timezone.utc) - lookback_delta
                min_timestamp = datetime_to_apple_epoch(cutoff_datetime)
                logger.info(
                    "lookback_enabled_once",
                    lookback=args.lookback,
                    cutoff_datetime=cutoff_datetime.isoformat(),
                    min_timestamp=min_timestamp,
                )
            except ValueError as e:
                logger.error("invalid_lookback_format", error=str(e))
                raise
        
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
            events = list(fetch_new_messages(conn, scan_floor, BATCH_SIZE, min_timestamp))
            
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
