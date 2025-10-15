#!/usr/bin/env python3
"""Backfill image enrichment for already-ingested iMessage messages.

This script:
1. Queries the gateway API for messages with attachments
2. For messages without attachment metadata, optionally queries chat.db backup
3. For each message, checks if image attachments still exist on disk
4. Enriches images using the shared image_enrichment module
5. Updates the document via the gateway API with enriched image data
6. Triggers re-embedding automatically via the gateway/catalog
7. Outputs statistics at the end

Usage:
    python scripts/backfill_image_enrichment.py [--dry-run] [--limit N] [--batch-size N] [--use-chat-db]

Environment variables:
    GATEWAY_URL: URL of the gateway service (default: http://localhost:8085)
    AUTH_TOKEN: Authentication token for the gateway API
"""

from __future__ import annotations

import argparse
import os
import shutil
import sqlite3
import sys
import tempfile
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from shared.image_enrichment import (
    ImageEnrichmentCache,
    build_image_facets,
    enrich_image,
)
from shared.logging import get_logger, setup_logging

# Configuration
GATEWAY_URL = os.getenv("GATEWAY_URL", "http://localhost:8085")
AUTH_TOKEN = os.getenv("AUTH_TOKEN", "")
DEFAULT_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"

# Path constants from collector
STATE_DIR = Path.home() / ".haven"
IMAGE_CACHE_FILE = STATE_DIR / "imessage_image_cache.json"
CHAT_DB_BACKUP_DIR = STATE_DIR / "chat_backup"
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

logger = get_logger("backfill.image_enrichment")


@dataclass
class BackfillStats:
    """Track statistics for the backfill operation."""

    documents_scanned: int = 0
    documents_with_images: int = 0
    images_found_on_disk: int = 0
    images_missing_on_disk: int = 0
    images_already_enriched: int = 0
    images_enriched: int = 0
    images_failed: int = 0
    documents_updated: int = 0
    chunks_requeued: int = 0
    errors: List[str] = field(default_factory=list)

    def log_summary(self) -> None:
        """Log a summary of backfill statistics."""
        logger.info(
            "backfill_complete",
            documents_scanned=self.documents_scanned,
            documents_with_images=self.documents_with_images,
            images_found_on_disk=self.images_found_on_disk,
            images_missing_on_disk=self.images_missing_on_disk,
            images_already_enriched=self.images_already_enriched,
            images_enriched=self.images_enriched,
            images_failed=self.images_failed,
            documents_updated=self.documents_updated,
            chunks_requeued=self.chunks_requeued,
            error_count=len(self.errors),
        )
        if self.errors:
            logger.warning("backfill_errors", errors=self.errors[:10])


def _is_image_attachment(metadata: Dict[str, Any]) -> bool:
    """Check if an attachment is an image based on mime type, UTI, or extension."""
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
    """Resolve attachment path from the filename stored in metadata."""
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


def backup_chat_db(source: Path) -> Path:
    """Create or update a rotating backup file for chat.db.
    
    Uses the same backup mechanism as the collector to avoid blocking.
    """
    if not source.exists():
        raise FileNotFoundError(f"chat.db not found at {source}")

    backup_dir = CHAT_DB_BACKUP_DIR
    backup_dir.mkdir(parents=True, exist_ok=True)
    dest = backup_dir / "chat.db"

    logger.debug("backing_up_chat_db", source=str(source), dest=str(dest))

    # Use SQLite backup API to copy safely
    tmp_dest = backup_dir / "chat.db.tmp"
    if tmp_dest.exists():
        try:
            tmp_dest.unlink()
        except Exception:
            logger.debug("failed_unlink_tmp_backup", path=str(tmp_dest))

    with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as src_conn:
        with sqlite3.connect(tmp_dest) as dst_conn:
            src_conn.backup(dst_conn)

    try:
        tmp_dest.replace(dest)
    except Exception:
        os.replace(str(tmp_dest), str(dest))

    return dest


def fetch_message_attachments_from_chatdb(
    conn: sqlite3.Connection,
    message_row_id: int,
) -> List[Dict[str, Any]]:
    """Fetch attachment metadata for a message from chat.db backup.
    
    This is used for messages that were ingested without attachment details.
    """
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
        (message_row_id,),
    )

    attachments: List[Dict[str, Any]] = []
    for row in cursor.fetchall():
        attachments.append({
            "row_id": int(row["ROWID"]) if row["ROWID"] is not None else None,
            "guid": row["guid"],
            "filename": row["filename"],
            "mime_type": row["mime_type"],
            "transfer_name": row["transfer_name"],
            "uti": row["uti"],
            "total_bytes": row["total_bytes"],
        })

    return attachments
    """Resolve attachment path from the filename stored in metadata."""
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
    """Truncate a caption to a maximum length."""
    if not value:
        return ""
    caption = value.strip()
    if len(caption) <= limit:
        return caption
    return caption[: limit - 1] + "\u2026"


def fetch_documents_with_attachments(
    *,
    limit: Optional[int] = None,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """Fetch documents that have image attachments via the gateway API.

    Returns a list of dicts with keys: doc_id, metadata, text
    """
    headers = {}
    if AUTH_TOKEN:
        headers["Authorization"] = f"Bearer {AUTH_TOKEN}"
    
    params = {
        "source_type": "imessage",
        "has_attachments": "true",
        "offset": offset,
    }
    
    if limit is not None:
        params["limit"] = limit
    
    try:
        response = requests.get(
            f"{GATEWAY_URL}/v1/documents",
            params=params,
            headers=headers,
            timeout=30,
        )
        response.raise_for_status()
        data = response.json()
        return data.get("documents", [])
    except requests.RequestException as exc:
        logger.error(
            "fetch_documents_failed",
            offset=offset,
            limit=limit,
            error=str(exc),
        )
        raise


def extract_attachments_from_metadata(
    metadata: Dict[str, Any],
    *,
    chatdb_conn: Optional[sqlite3.Connection] = None,
) -> List[Dict[str, Any]]:
    """Extract attachment metadata from document metadata.

    Returns a list of attachment dicts. If the document doesn't have attachments
    stored but has a message row_id and chatdb_conn is provided, will query
    chat.db for attachment information.
    """
    try:
        message = metadata.get("message", {})
        
        # First try to get attachments from stored metadata
        attachments = message.get("attachments")
        if attachments:
            return attachments
        
        # If no attachments but we have attachment_count and chat.db connection,
        # query chat.db for attachment details
        if chatdb_conn is not None:
            attachment_count = message.get("attrs", {}).get("attachment_count")
            message_row_id = message.get("row_id")
            
            if attachment_count and message_row_id:
                try:
                    attachments = fetch_message_attachments_from_chatdb(
                        chatdb_conn,
                        message_row_id,
                    )
                    if attachments:
                        logger.debug(
                            "fetched_attachments_from_chatdb",
                            message_row_id=message_row_id,
                            count=len(attachments),
                        )
                        return attachments
                except Exception as exc:
                    logger.warning(
                        "chatdb_attachment_fetch_failed",
                        message_row_id=message_row_id,
                        error=str(exc),
                    )
        
        return []
    except Exception:
        return []


def enrich_attachment(
    attachment_meta: Dict[str, Any],
    *,
    cache: ImageEnrichmentCache,
    tmp_dir: Path,
) -> Optional[Dict[str, Any]]:
    """Enrich a single image attachment.

    Returns enriched attachment dict with image data, or None if enrichment fails.
    """
    # Check if already enriched
    if "image" in attachment_meta and isinstance(attachment_meta.get("image"), dict):
        image_data = attachment_meta["image"]
        if image_data.get("blob_id") and (image_data.get("caption") or image_data.get("ocr_text")):
            return None  # Already enriched

    # Check if it's an image
    if not _is_image_attachment(attachment_meta):
        return None

    # Resolve the attachment path
    source = _resolve_attachment_path(attachment_meta.get("filename"))
    if source is None or not source.exists():
        transfer_name = attachment_meta.get("transfer_name")
        alt_source = _resolve_attachment_path(transfer_name) if transfer_name else None
        if alt_source is not None and alt_source.exists():
            source = alt_source

    if source is None or not source.exists():
        return None

    # Copy to temp directory
    try:
        tmp_dir.mkdir(parents=True, exist_ok=True)
        row_id = attachment_meta.get("row_id", "attachment")
        target_name = f"{row_id}_{source.name}"
        target = tmp_dir / target_name
        import shutil
        shutil.copy2(source, target)
    except Exception as exc:
        logger.debug(
            "attachment_copy_failed",
            row_id=attachment_meta.get("row_id"),
            path=str(source),
            error=str(exc),
        )
        return None

    # Enrich the image
    cache_dict = cache.get_data_dict()
    try:
        result = enrich_image(target, cache_dict=cache_dict)
        cache.save()
    except Exception as exc:
        logger.warning(
            "image_enrichment_failed",
            row_id=attachment_meta.get("row_id"),
            path=str(target),
            error=str(exc),
        )
        return None

    if result is None:
        return None

    # Build enriched attachment metadata
    blob_id = result["blob_id"]
    caption = _truncate_caption(result.get("caption"))
    ocr_text = result.get("ocr_text", "")
    ocr_boxes = result.get("ocr_boxes", [])
    ocr_entities = result.get("ocr_entities", {})

    enriched = dict(attachment_meta)
    enriched["image"] = {
        "ocr_text": ocr_text,
        "ocr_boxes": ocr_boxes,
        "ocr_entities": ocr_entities,
        "caption": caption,
        "blob_id": blob_id,
    }

    return enriched


def update_document_with_enriched_images(
    *,
    doc_id: str,
    enriched_attachments: List[Dict[str, Any]],
    metadata: Dict[str, Any],
    original_text: str,
    dry_run: bool = False,
) -> int:
    """Update a document with enriched image data via the gateway API.

    Returns the number of chunks requeued.
    """
    # Update metadata with enriched attachments
    if "message" not in metadata:
        metadata["message"] = {}
    if "attrs" not in metadata["message"]:
        metadata["message"]["attrs"] = {}

    # Store enriched attachments
    metadata["message"]["attachments"] = enriched_attachments

    # Build enriched attributes for attrs field
    captions = []
    ocr_texts = []
    ocr_entities_list = []
    blob_ids = []

    for attachment in enriched_attachments:
        image_data = attachment.get("image", {})
        if image_data.get("caption"):
            captions.append(image_data["caption"])
        if image_data.get("ocr_text"):
            ocr_texts.append(image_data["ocr_text"])
        if image_data.get("ocr_entities"):
            ocr_entities_list.append(image_data["ocr_entities"])
        if image_data.get("blob_id"):
            blob_ids.append(image_data["blob_id"])

    if captions:
        metadata["message"]["attrs"]["image_captions"] = captions
    if ocr_texts:
        metadata["message"]["attrs"]["image_ocr_text"] = ocr_texts
    if ocr_entities_list:
        metadata["message"]["attrs"]["image_ocr_entities"] = ocr_entities_list
    if blob_ids:
        metadata["message"]["attrs"]["image_blob_ids"] = blob_ids
    if captions:
        metadata["message"]["attrs"]["image_primary_caption"] = captions[0]

    # Build enriched text by appending captions and OCR text
    enriched_parts = []
    for caption in captions:
        if caption.strip():
            enriched_parts.append(f"[Image: {caption.strip()}]")
    for ocr in ocr_texts:
        if ocr.strip():
            enriched_parts.append(f"[OCR: {ocr.strip()}]")

    # Determine new text value
    new_text = original_text
    if enriched_parts:
        enriched_text = " ".join(enriched_parts)
        # Check if original text ends with attachment placeholder
        if original_text.endswith("attachment(s) omitted]"):
            # Replace placeholder with enriched content
            new_text = enriched_text
        elif original_text.strip():
            # Append to existing text
            new_text = f"{original_text} {enriched_text}"
        else:
            # No original text, use enriched content
            new_text = enriched_text

    # Update message text in metadata
    metadata["message"]["text"] = new_text

    if dry_run:
        logger.info(
            "dry_run_would_update",
            doc_id=doc_id,
            attachments_enriched=len(enriched_attachments),
            new_text_length=len(new_text),
        )
        return 0

    # Update the document via the gateway API
    headers = {}
    if AUTH_TOKEN:
        headers["Authorization"] = f"Bearer {AUTH_TOKEN}"
    
    payload = {
        "metadata": metadata,
        "text": new_text,
        "requeue_for_embedding": True,
    }
    
    try:
        response = requests.patch(
            f"{GATEWAY_URL}/v1/documents/{doc_id}",
            json=payload,
            headers=headers,
            timeout=30,
        )
        response.raise_for_status()
        data = response.json()
        return data.get("chunks_requeued", 0)
    except requests.RequestException as exc:
        logger.error(
            "update_document_failed",
            doc_id=doc_id,
            error=str(exc),
        )
        raise


def backfill_images(
    *,
    limit: Optional[int] = None,
    batch_size: int = 50,
    dry_run: bool = False,
    use_chat_db: bool = False,
    chat_db_path: Path = DEFAULT_CHAT_DB,
) -> BackfillStats:
    """Run the image enrichment backfill process.

    Args:
        limit: Maximum number of documents to process (None = all)
        batch_size: Number of documents to process per batch
        dry_run: If True, don't actually update the documents
        use_chat_db: If True, query chat.db for attachment details
        chat_db_path: Path to the original chat.db file

    Returns:
        BackfillStats object with statistics
    """
    stats = BackfillStats()
    cache = ImageEnrichmentCache(IMAGE_CACHE_FILE)

    # Backup chat.db if we're using it
    chatdb_conn: Optional[sqlite3.Connection] = None
    if use_chat_db:
        backup_path = CHAT_DB_BACKUP_DIR / "chat.db"
        
        # Check if backup already exists
        if backup_path.exists():
            try:
                chatdb_conn = sqlite3.connect(backup_path)
                logger.info("using_existing_chatdb_backup", path=str(backup_path))
            except Exception as exc:
                logger.error("chatdb_backup_open_failed", error=str(exc), path=str(backup_path))
        else:
            # Try to create a new backup
            try:
                backup_path = backup_chat_db(chat_db_path)
                chatdb_conn = sqlite3.connect(backup_path)
                logger.info("created_chatdb_backup", path=str(backup_path))
            except Exception as exc:
                logger.error(
                    "chatdb_backup_failed",
                    error=str(exc),
                    path=str(chat_db_path),
                )
                logger.warning(
                    "continuing_without_chatdb",
                    hint="Run the iMessage collector first or ensure Terminal has Full Disk Access",
                )

    try:
        offset = 0
        processed = 0

        while True:
            # Determine how many to fetch in this batch
            if limit is not None:
                remaining = limit - processed
                if remaining <= 0:
                    break
                fetch_size = min(batch_size, remaining)
            else:
                fetch_size = batch_size

            try:
                docs = fetch_documents_with_attachments(limit=fetch_size, offset=offset)
            except Exception as exc:
                stats.errors.append(f"Failed to fetch documents at offset {offset}: {exc}")
                break

            if not docs:
                break

            logger.info(
                "processing_batch",
                offset=offset,
                count=len(docs),
                dry_run=dry_run,
            )

            with tempfile.TemporaryDirectory() as tmp_dir_str:
                tmp_dir = Path(tmp_dir_str)

                for doc in docs:
                    stats.documents_scanned += 1
                    processed += 1

                    doc_id = doc["doc_id"]
                    metadata = doc["metadata"]
                    original_text = doc["text"]

                    # Extract attachments from metadata (or chat.db if enabled)
                    attachments = extract_attachments_from_metadata(
                        metadata,
                        chatdb_conn=chatdb_conn,
                    )
                    if not attachments:
                        continue

                    stats.documents_with_images += 1

                    # Enrich each attachment
                    enriched = []
                    for attachment_meta in attachments:
                        try:
                            result = enrich_attachment(
                                attachment_meta,
                                cache=cache,
                                tmp_dir=tmp_dir,
                            )
                            if result is None:
                                # Check why it was None
                                if "image" in attachment_meta:
                                    stats.images_already_enriched += 1
                                elif _is_image_attachment(attachment_meta):
                                    source = _resolve_attachment_path(attachment_meta.get("filename"))
                                    if source is None or not source.exists():
                                        stats.images_missing_on_disk += 1
                                    else:
                                        stats.images_failed += 1
                                continue

                            enriched.append(result)
                            stats.images_found_on_disk += 1
                            stats.images_enriched += 1
                        except Exception as exc:
                            error_msg = f"doc_id={doc_id} attachment_row_id={attachment_meta.get('row_id')}: {exc}"
                            stats.errors.append(error_msg)
                            stats.images_failed += 1
                            logger.error(
                                "attachment_enrichment_error",
                                doc_id=doc_id,
                                row_id=attachment_meta.get("row_id"),
                                error=str(exc),
                            )

                    if not enriched:
                        continue

                    # Update the document with enriched data
                    try:
                        chunks_requeued = update_document_with_enriched_images(
                            doc_id=doc_id,
                            enriched_attachments=enriched,
                            metadata=metadata,
                            original_text=original_text,
                            dry_run=dry_run,
                        )
                        if not dry_run:
                            stats.documents_updated += 1
                            stats.chunks_requeued += chunks_requeued
                    except Exception as exc:
                        error_msg = f"doc_id={doc_id}: {exc}"
                        stats.errors.append(error_msg)
                        logger.error(
                            "document_update_error",
                            doc_id=doc_id,
                            error=str(exc),
                        )

            offset += len(docs)

            # Break if we've hit the limit
            if limit is not None and processed >= limit:
                break

    finally:
        # Clean up chat.db connection
        if chatdb_conn is not None:
            try:
                chatdb_conn.close()
            except Exception:
                pass

    cache.save()
    return stats


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Backfill image enrichment for already-ingested iMessage messages"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Don't actually update the database, just show what would be done",
    )
    parser.add_argument(
        "--limit",
        type=int,
        help="Maximum number of documents to process (default: all)",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=50,
        help="Number of documents to process per batch (default: 50)",
    )
    parser.add_argument(
        "--use-chat-db",
        action="store_true",
        help="Query chat.db backup for attachment details (for messages collected without enrichment)",
    )
    parser.add_argument(
        "--chat-db",
        type=Path,
        default=DEFAULT_CHAT_DB,
        help="Path to macOS chat.db database (default: ~/Library/Messages/chat.db)",
    )
    return parser.parse_args()


def main() -> None:
    setup_logging()
    args = parse_args()

    logger.info(
        "backfill_starting",
        limit=args.limit,
        batch_size=args.batch_size,
        dry_run=args.dry_run,
        use_chat_db=args.use_chat_db,
    )

    start_time = datetime.now()
    stats = backfill_images(
        limit=args.limit,
        batch_size=args.batch_size,
        dry_run=args.dry_run,
        use_chat_db=args.use_chat_db,
        chat_db_path=args.chat_db,
    )
    elapsed = (datetime.now() - start_time).total_seconds()

    stats.log_summary()

    # Print human-readable summary
    print("\n" + "=" * 60)
    print("IMAGE ENRICHMENT BACKFILL COMPLETE")
    print("=" * 60)
    print(f"Duration: {elapsed:.1f}s")
    print(f"Dry run: {args.dry_run}")
    print(f"Used chat.db: {args.use_chat_db}")
    print()
    print(f"Documents scanned: {stats.documents_scanned}")
    print(f"Documents with images: {stats.documents_with_images}")
    print(f"Images found on disk: {stats.images_found_on_disk}")
    print(f"Images missing on disk: {stats.images_missing_on_disk}")
    print(f"Images already enriched: {stats.images_already_enriched}")
    print(f"Images enriched: {stats.images_enriched}")
    print(f"Images failed: {stats.images_failed}")
    print()
    print(f"Documents updated: {stats.documents_updated}")
    print(f"Chunks re-queued for embedding: {stats.chunks_requeued}")
    print()
    if stats.errors:
        print(f"Errors encountered: {len(stats.errors)}")
        print("First 5 errors:")
        for error in stats.errors[:5]:
            print(f"  - {error}")
    else:
        print("No errors encountered")
    print("=" * 60)


if __name__ == "__main__":
    main()
