from __future__ import annotations

import argparse
import json
import os
import plistlib
import sqlite3
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional
from uuid import NAMESPACE_URL, uuid5

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import requests

from shared.logging import get_logger, setup_logging

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
DEFAULT_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"
STATE_DIR = Path.home() / ".haven"
STATE_FILE = STATE_DIR / "imessage_collector_state.json"
CATALOG_ENDPOINT = os.getenv(
    "CATALOG_ENDPOINT", "http://localhost:8080/v1/catalog/events"
)
COLLECTOR_AUTH_TOKEN = os.getenv("CATALOG_TOKEN")
POLL_INTERVAL_SECONDS = float(os.getenv("COLLECTOR_POLL_INTERVAL", "5"))
BATCH_SIZE = int(os.getenv("COLLECTOR_BATCH_SIZE", "200"))

logger = get_logger("collector.imessage")


def deterministic_chunk_id(doc_id: str, chunk_index: int) -> str:
    return str(uuid5(NAMESPACE_URL, f"{doc_id}:{chunk_index}"))


@dataclass
class CollectorState:
    last_seen_rowid: int = 0

    @classmethod
    def load(cls) -> "CollectorState":
        if not STATE_FILE.exists():
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            return cls()
        try:
            data = json.loads(STATE_FILE.read_text())
            return cls(last_seen_rowid=int(data.get("last_seen_rowid", 0)))
        except Exception:
            logger.warning("failed_to_load_state", path=str(STATE_FILE))
            return cls()

    def save(self) -> None:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps({"last_seen_rowid": self.last_seen_rowid}))


@dataclass
class SourceEvent:
    doc_id: str
    thread: Dict[str, Any]
    message: Dict[str, Any]
    chunks: List[Dict[str, Any]]

    def to_payload(self) -> Dict[str, Any]:
        return {
            "items": [
                {
                    "source": "imessage",
                    "doc_id": self.doc_id,
                    "thread": self.thread,
                    "message": self.message,
                    "chunks": self.chunks,
                }
            ]
        }


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


def normalize_row(row: sqlite3.Row, participants: List[str]) -> SourceEvent:
    text = (row["text"] or "").strip()
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
        "sender": row["handle_id"] or "me",
        "sender_service": row["service"],
        "is_from_me": bool(row["is_from_me"]),
        "text": text,
        "attrs": {
            "attachment_count": row["attachment_count"],
        },
    }

    chunk = {
        "id": deterministic_chunk_id(doc_id, 0),
        "chunk_index": 0,
        "text": text,
        "meta": {
            "doc_id": doc_id,
            "ts": ts_iso,
            "thread_id": row["chat_guid"],
        },
    }

    return SourceEvent(doc_id=doc_id, thread=thread, message=message, chunks=[chunk])


def fetch_new_messages(
    conn: sqlite3.Connection, last_seen: int, batch_size: int
) -> Iterable[SourceEvent]:
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
        ORDER BY m.ROWID ASC
        LIMIT ?
        """,
        (last_seen, batch_size),
    )

    for row in cursor.fetchall():
        participants = get_participants(conn, row["chat_rowid"])
        yield normalize_row(row, participants)


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


def post_events(events: List[SourceEvent]) -> None:
    if not events:
        return

    payload = {"items": []}
    for event in events:
        payload["items"].extend(event.to_payload()["items"])

    headers = {"Content-Type": "application/json"}
    if COLLECTOR_AUTH_TOKEN:
        headers["Authorization"] = f"Bearer {COLLECTOR_AUTH_TOKEN}"

    try:
        response = requests.post(
            CATALOG_ENDPOINT, json=payload, headers=headers, timeout=10
        )
        response.raise_for_status()
    except requests.RequestException as exc:
        logger.error(
            "catalog_post_failed",
            endpoint=CATALOG_ENDPOINT,
            error=str(exc),
        )


def run_poll_loop(args: argparse.Namespace) -> None:
    state = CollectorState.load()
    logger.info(
        "starting_collector",
        last_seen_rowid=state.last_seen_rowid,
        endpoint=CATALOG_ENDPOINT,
        batch_size=BATCH_SIZE,
    )

    while True:
        try:
            backup_path = backup_chat_db(args.chat_db)
            with sqlite3.connect(backup_path) as conn:
                events = list(fetch_new_messages(conn, state.last_seen_rowid, BATCH_SIZE))
                if not events:
                    logger.debug("no_new_messages")
                else:
                    batch_max_ts = compute_batch_max_timestamp(events)
                    post_events(events)
                    state.last_seen_rowid = max(
                        state.last_seen_rowid,
                        max(event.message["row_id"] for event in events),
                    )
                    state.save()
                    logger.info(
                        "dispatched_events",
                        count=len(events),
                        last_seen_rowid=state.last_seen_rowid,
                        batch_max_ts=batch_max_ts,
                    )
        except Exception as exc:  # pragma: no cover - defensive logging
            logger.error("collector_error", error=str(exc))

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
    post_events([event])
    logger.info("simulated_message_sent", text=text)


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
    return parser.parse_args()


def main() -> None:
    setup_logging()
    args = parse_args()

    if args.simulate:
        simulate_message(args.simulate)
        return

    if args.once:
        state = CollectorState.load()
        backup_path = backup_chat_db(args.chat_db)
        with sqlite3.connect(backup_path) as conn:
            events = list(fetch_new_messages(conn, state.last_seen_rowid, BATCH_SIZE))
        if events:
            post_events(events)
            state.last_seen_rowid = max(
                state.last_seen_rowid,
                max(event.message["row_id"] for event in events),
            )
            state.save()
            logger.info("dispatched_events_once", count=len(events))
        else:
            logger.info("no_new_messages_once")
        return

    run_poll_loop(args)


if __name__ == "__main__":
    main()
