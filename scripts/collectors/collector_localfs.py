from __future__ import annotations

import argparse
import hashlib
import io
import json
import mimetypes
import os
import shutil
import sys
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import requests

from shared.image_enrichment import (
    ImageEnrichmentCache,
    build_image_facets,
    enrich_image,
)
from shared.logging import get_logger, setup_logging

DEFAULT_INCLUDE_PATTERNS = [
    "*.txt",
    "*.md",
    "*.pdf",
    "*.png",
    "*.jpg",
    "*.jpeg",
    "*.heic",
]
DEFAULT_EXCLUDE_PATTERNS: List[str] = []
DEFAULT_POLL_INTERVAL = float(os.getenv("COLLECTOR_POLL_INTERVAL", "5"))
DEFAULT_MAX_FILE_MB = float(os.getenv("LOCALFS_MAX_FILE_MB", "32"))
DEFAULT_TIMEOUT_SECONDS = float(os.getenv("LOCALFS_REQUEST_TIMEOUT", "15"))

AUTH_TOKEN = os.getenv("AUTH_TOKEN")
GATEWAY_URL = os.getenv("GATEWAY_URL", "http://localhost:8085")
STATE_FILE = Path.home() / ".haven" / "localfs_collector_state.json"

# Image attachment extensions (matching iMessage collector)
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

# Configurable placeholder text for image handling
IMAGE_PLACEHOLDER_TEXT = os.getenv("IMAGE_PLACEHOLDER_TEXT", "[image]")
IMAGE_MISSING_PLACEHOLDER_TEXT = os.getenv("IMAGE_MISSING_PLACEHOLDER_TEXT", "[image not available]")
IMAGE_CACHE_FILE = STATE_FILE.parent / "localfs_image_cache.json"

logger = get_logger("collector.localfs")

_image_cache: Optional[ImageEnrichmentCache] = None


def get_image_cache() -> ImageEnrichmentCache:
    global _image_cache
    if _image_cache is None:
        _image_cache = ImageEnrichmentCache(IMAGE_CACHE_FILE)
    return _image_cache


def _split_patterns(raw: str, defaults: Iterable[str]) -> List[str]:
    value = raw.strip()
    if not value:
        return list(defaults)
    parts = [item.strip() for item in value.split(",")]
    cleaned = [part for part in parts if part]
    return cleaned or list(defaults)


def _now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


def _is_image_file(path: Path) -> bool:
    """Check if a file is an image based on extension."""
    suffix = path.suffix.lower()
    return suffix in IMAGE_ATTACHMENT_EXTENSIONS


@dataclass
class CollectorConfig:
    watch_dir: Path
    include: List[str]
    exclude: List[str]
    poll_interval: float
    move_to: Optional[Path]
    delete_after: bool
    max_file_bytes: int
    gateway_url: str
    auth_token: Optional[str]
    tags: List[str]
    dry_run: bool
    one_shot: bool
    state_file: Path
    request_timeout: float

    @property
    def endpoint(self) -> str:
        return self.gateway_url.rstrip("/") + "/v1/ingest/file"


@dataclass
class CollectorState:
    by_path: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    by_hash: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    path: Path = STATE_FILE

    @classmethod
    def load(cls, path: Path) -> "CollectorState":
        if not path.exists():
            return cls(path=path)
        try:
            raw = json.loads(path.read_text())
            return cls(
                by_path=raw.get("by_path", {}),
                by_hash=raw.get("by_hash", {}),
                path=path,
            )
        except Exception:
            logger.warning("localfs_state_load_failed", path=str(path))
            return cls(path=path)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"by_path": self.by_path, "by_hash": self.by_hash}
        self.path.write_text(json.dumps(payload, indent=2))

    def get_path(self, key: str) -> Optional[Dict[str, Any]]:
        return self.by_path.get(key)

    def update_path(self, key: str, sha: str, mtime: float) -> None:
        self.by_path[key] = {
            "sha": sha,
            "mtime": mtime,
            "updated_at": _now_iso(),
        }

    def remove_path(self, key: str) -> None:
        self.by_path.pop(key, None)

    def has_hash(self, sha: str) -> bool:
        return sha in self.by_hash

    def mark_hash(self, sha: str) -> None:
        record = self.by_hash.setdefault(sha, {})
        record["last_processed"] = _now_iso()


class LocalFsCollector:
    def __init__(
        self,
        config: CollectorConfig,
        state: CollectorState,
        session: Optional[requests.Session] = None,
    ) -> None:
        self.config = config
        self.state = state
        self.session = session or requests.Session()

    def process_once(self) -> int:
        processed = 0
        files = sorted(self._discover_files(), key=lambda item: item.stat().st_mtime)
        for path in files:
            record = self.state.get_path(str(path))
            mtime = path.stat().st_mtime
            if record and abs(record.get("mtime", 0) - mtime) < 1e-6:
                continue
            try:
                file_bytes = self._read_file(path)
            except ValueError as exc:
                logger.warning("localfs_skip_size", path=str(path), error=str(exc))
                continue
            except OSError as exc:
                logger.warning("localfs_read_failed", path=str(path), error=str(exc))
                continue

            sha = hashlib.sha256(file_bytes).hexdigest()
            if self.state.has_hash(sha):
                logger.info("localfs_skip_duplicate", path=str(path), sha=sha)
                self.state.update_path(str(path), sha, mtime)
                continue

            if self.config.dry_run:
                logger.info("localfs_dry_run", path=str(path), sha=sha)
                self.state.update_path(str(path), sha, mtime)
                self.state.mark_hash(sha)
                processed += 1
                continue

            try:
                success = self._submit_file(path, file_bytes, sha, mtime)
            except Exception as exc:
                logger.error("localfs_submit_failed", path=str(path), error=str(exc))
                continue

            if not success:
                continue

            processed += 1
            self.state.update_path(str(path), sha, mtime)
            self.state.mark_hash(sha)
            if self.config.delete_after:
                try:
                    path.unlink()
                    logger.info("localfs_file_deleted", path=str(path))
                except Exception as exc:
                    logger.warning(
                        "localfs_delete_failed", path=str(path), error=str(exc)
                    )
                self.state.remove_path(str(path))
            elif self.config.move_to:
                try:
                    dest = self._move_to_processed(path)
                    logger.info("localfs_file_moved", src=str(path), dest=str(dest))
                    self.state.remove_path(str(path))
                except Exception as exc:
                    logger.warning(
                        "localfs_move_failed", path=str(path), error=str(exc)
                    )

        self.state.save()
        return processed

    def _discover_files(self) -> List[Path]:
        candidates: List[Path] = []
        for item in self.config.watch_dir.rglob("*"):
            if not item.is_file():
                continue
            if not self._matches_include(item):
                continue
            if self._matches_exclude(item):
                continue
            candidates.append(item)
        return candidates

    def _matches_include(self, path: Path) -> bool:
        return any(path.match(pattern) for pattern in self.config.include)

    def _matches_exclude(self, path: Path) -> bool:
        return any(path.match(pattern) for pattern in self.config.exclude)

    def _read_file(self, path: Path) -> bytes:
        size = path.stat().st_size
        if size > self.config.max_file_bytes:
            raise ValueError(
                f"file exceeds max size ({size} > {self.config.max_file_bytes})"
            )
        return path.read_bytes()

    def _enrich_image(self, path: Path) -> Optional[Dict[str, Any]]:
        """Enrich an image file with OCR and captioning.
        
        Returns:
            Dict with enriched data (caption, ocr_text, entities, facets, blob_id) or None if enrichment fails
        """
        if not _is_image_file(path):
            return None
        
        try:
            cache = get_image_cache()
            cache_dict = cache.get_data_dict()
            result = enrich_image(path, use_cache=True, cache_dict=cache_dict)
            cache.save()
            
            logger.info(
                "localfs_image_enriched",
                path=str(path),
                blob_id=result.get("blob_id"),
                has_caption=bool(result.get("caption")),
                has_ocr=bool(result.get("ocr_text")),
            )
            return result
        except Exception as exc:
            logger.warning(
                "localfs_image_enrichment_failed",
                path=str(path),
                error=str(exc),
            )
            return None

    def _submit_file(self, path: Path, content: bytes, sha: str, mtime: float) -> bool:
        meta = self._build_meta(path, mtime)
        
        # Enrich images before submission
        enrichment = None
        if _is_image_file(path):
            enrichment = self._enrich_image(path)
            if enrichment:
                # Add enrichment data to metadata
                meta["image"] = {
                    "blob_id": enrichment.get("blob_id"),
                    "caption": enrichment.get("caption"),
                    "ocr_text": enrichment.get("ocr_text"),
                    "ocr_entities": enrichment.get("ocr_entities"),
                    "facets": enrichment.get("facets"),
                }
        
        headers: Dict[str, str] = {}
        if self.config.auth_token:
            headers["Authorization"] = f"Bearer {self.config.auth_token}"
        content_type = self._guess_content_type(path)
        files = {
            "upload": (
                path.name,
                io.BytesIO(content),
                content_type,
            )
        }
        data = {"meta": json.dumps(meta)}
        response = self.session.post(
            self.config.endpoint,
            files=files,
            data=data,
            headers=headers,
            timeout=self.config.request_timeout,
        )
        if response.status_code not in (200, 202):
            logger.warning(
                "localfs_gateway_rejected",
                path=str(path),
                status=response.status_code,
                body=_truncate_response(response),
            )
            return False

        try:
            payload = response.json()
        except ValueError:
            payload = {}

        logger.info(
            "localfs_ingest_success",
            path=str(path),
            sha=sha,
            submission_id=payload.get("submission_id"),
            doc_id=payload.get("doc_id"),
            duplicate=payload.get("duplicate"),
        )
        return True

    def _build_meta(self, path: Path, mtime: float) -> Dict[str, Any]:
        meta: Dict[str, Any] = {
            "source": "localfs",
            "path": str(path),
            "filename": path.name,
            "mtime": mtime,
        }
        try:
            meta["ctime"] = path.stat().st_ctime
        except OSError:
            pass
        if self.config.tags:
            meta["tags"] = self.config.tags
        return meta

    @staticmethod
    def _guess_content_type(path: Path) -> str:
        mime, _ = mimetypes.guess_type(path.name)
        return mime or "application/octet-stream"

    def _move_to_processed(self, path: Path) -> Path:
        target_dir = self.config.move_to
        if target_dir is None:
            raise ValueError("move_to directory not configured")
        try:
            relative = path.relative_to(self.config.watch_dir)
        except ValueError:
            relative = Path(path.name)
        destination = target_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), str(destination))
        return destination


def _truncate_response(response: requests.Response, limit: int = 200) -> str:
    try:
        text = response.text
    except Exception:
        return "<unavailable>"
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Haven Local Files Collector")
    parser.add_argument(
        "--watch", required=True, help="Directory to watch for new files"
    )
    parser.add_argument(
        "--include",
        default=",".join(DEFAULT_INCLUDE_PATTERNS),
        help="Comma-separated glob patterns to include (default: %(default)s)",
    )
    parser.add_argument(
        "--exclude",
        default=",".join(DEFAULT_EXCLUDE_PATTERNS),
        help="Comma-separated glob patterns to exclude",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=DEFAULT_POLL_INTERVAL,
        help="Seconds between scans",
    )
    parser.add_argument("--move-to", help="Directory to move processed files into")
    parser.add_argument(
        "--delete-after",
        action="store_true",
        help="Delete files after successful ingestion",
    )
    parser.add_argument(
        "--max-file-mb",
        type=float,
        default=DEFAULT_MAX_FILE_MB,
        help="Maximum file size to ingest",
    )
    parser.add_argument(
        "--tag",
        action="append",
        default=[],
        help="Tag to attach to ingested files (can repeat)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Scan and log without sending to gateway"
    )
    parser.add_argument("--one-shot", action="store_true", help="Process once and exit")
    parser.add_argument(
        "--state-file", default=str(STATE_FILE), help="Path to collector state file"
    )
    parser.add_argument(
        "--gateway-url",
        default=GATEWAY_URL,
        help="Gateway base URL (default: %(default)s)",
    )
    parser.add_argument(
        "--request-timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="HTTP request timeout in seconds (default: %(default)s)",
    )
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    setup_logging()

    watch_dir = Path(args.watch).expanduser().resolve()
    if not watch_dir.exists() or not watch_dir.is_dir():
        logger.error("localfs_invalid_watch_dir", path=str(watch_dir))
        return 1

    move_to = Path(args.move_to).expanduser().resolve() if args.move_to else None
    if move_to:
        move_to.mkdir(parents=True, exist_ok=True)

    include_patterns = _split_patterns(args.include, DEFAULT_INCLUDE_PATTERNS)
    exclude_patterns = _split_patterns(args.exclude, DEFAULT_EXCLUDE_PATTERNS)

    config = CollectorConfig(
        watch_dir=watch_dir,
        include=include_patterns,
        exclude=exclude_patterns,
        poll_interval=float(args.poll_interval),
        move_to=move_to,
        delete_after=bool(args.delete_after),
        max_file_bytes=int(args.max_file_mb * 1024 * 1024),
        gateway_url=args.gateway_url,
        auth_token=AUTH_TOKEN,
        tags=args.tag or [],
        dry_run=bool(args.dry_run),
        one_shot=bool(args.one_shot),
        state_file=Path(args.state_file).expanduser().resolve(),
        request_timeout=float(args.request_timeout),
    )

    state = CollectorState.load(config.state_file)
    collector = LocalFsCollector(config=config, state=state)

    logger.info("localfs_started", watch_dir=str(watch_dir), gateway=config.endpoint)
    try:
        while True:
            processed = collector.process_once()
            logger.info("localfs_cycle_complete", processed=processed)
            if config.one_shot:
                break
            time.sleep(config.poll_interval)
    except KeyboardInterrupt:
        logger.info("localfs_shutdown")
        return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
