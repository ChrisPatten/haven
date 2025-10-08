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

from shared.db import get_connection

from shared.logging import get_logger, setup_logging

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
DEFAULT_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"
STATE_DIR = Path.home() / ".haven"
STATE_FILE = STATE_DIR / "imessage_collector_state.json"
CATALOG_ENDPOINT = os.getenv(
    "CATALOG_ENDPOINT", "http://localhost:8085/v1/catalog/events"
)
COLLECTOR_AUTH_TOKEN = os.getenv("CATALOG_TOKEN")
POLL_INTERVAL_SECONDS = float(os.getenv("COLLECTOR_POLL_INTERVAL", "5"))
BATCH_SIZE = int(os.getenv("COLLECTOR_BATCH_SIZE", "200"))

logger = get_logger("collector.imessage")


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
        yield normalize_row(row, participants)


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
    except requests.HTTPError as exc:
        resp = exc.response
        logger.error(
            "catalog_post_failed",
            endpoint=CATALOG_ENDPOINT,
            status_code=getattr(resp, "status_code", None),
            response_text=_truncate_text(getattr(resp, "text", None)),
            error=str(exc),
        )
        return False
    except requests.RequestException as exc:
        logger.error(
            "catalog_post_failed",
            endpoint=CATALOG_ENDPOINT,
            error=str(exc),
        )
        return False

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
                            batch_events.append(normalize_row(row, participants))
                        
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
                                batch_events.append(normalize_row(row, participants))
                            
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
