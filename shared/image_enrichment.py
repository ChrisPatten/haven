"""Image enrichment utilities for extracting text and metadata from images.

This module provides functions to:
- Run OCR via the imdesc CLI (macOS Vision framework)
- Request image captions from Ollama vision models
- Cache enrichment results to avoid redundant processing
- Build searchable facets from extracted entities

Used by collectors (e.g., iMessage) to enrich image attachments.
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import requests

try:
    from PIL import Image
    # Register HEIC/HEIF support if pillow-heif is available
    try:
        from pillow_heif import register_heif_opener
        register_heif_opener()
    except ImportError:
        pass  # HEIC files will fail to convert, but other formats will still work
except ImportError:
    Image = None  # type: ignore[assignment]

from shared.logging import get_logger

logger = get_logger("shared.image_enrichment")


def _safe_float_env(name: str, default: float) -> float:
    """Parse float from environment variable with fallback."""
    value = os.getenv(name)
    if value is None:
        return default
    try:
        return float(value)
    except ValueError:
        return default


# Configuration from environment
IMDESC_EXECUTABLE = os.getenv("IMDESC_CLI_PATH", "imdesc")
IMDESC_TIMEOUT_SECONDS = _safe_float_env("IMDESC_TIMEOUT_SECONDS", 15.0)

OLLAMA_ENABLED = os.getenv("OLLAMA_ENABLED", "true").lower() in ("1", "true", "yes", "on")
OLLAMA_API_URL = os.getenv("OLLAMA_API_URL", "http://localhost:11434/api/generate")
OLLAMA_VISION_MODEL = os.getenv("OLLAMA_VISION_MODEL", "llava:7b")
OLLAMA_TIMEOUT_SECONDS = _safe_float_env("OLLAMA_TIMEOUT_SECONDS", 60.0)
OLLAMA_CAPTION_PROMPT = os.getenv(
    "OLLAMA_CAPTION_PROMPT",
    "describe the image scene and contents. short response",
)
OLLAMA_MAX_RETRIES = int(os.getenv("OLLAMA_MAX_RETRIES", "2"))

# Global state for logging warnings only once
_IMDESC_MISSING_LOGGED = False
_OLLAMA_CONNECTION_WARNED = False


def _truncate_text(value: Optional[str], limit: int = 512) -> str:
    """Truncate text to limit with ellipsis."""
    if not value:
        return ""
    if len(value) <= limit:
        return value
    return value[: limit - 1] + "\u2026"


def _truncate_caption(value: Optional[str], limit: int = 200) -> str:
    """Truncate caption to limit with ellipsis."""
    if not value:
        return ""
    caption = value.strip()
    if len(caption) <= limit:
        return caption
    return caption[: limit - 1] + "\u2026"


def hash_bytes(data: bytes) -> str:
    """Compute SHA256 hash of bytes for blob identification."""
    return hashlib.sha256(data).hexdigest()


def run_imdesc_ocr(image_path: Path) -> Optional[Dict[str, Any]]:
    """Run imdesc CLI to extract OCR text and entities using macOS Vision framework.
    
    Args:
        image_path: Path to the image file (will be resolved to absolute path)
    
    Returns:
        Dict with keys: text, boxes, entities (dates, phones, urls, addresses)
        None if imdesc is missing or fails
    """
    global _IMDESC_MISSING_LOGGED

    # Resolve to absolute path to avoid working directory issues
    absolute_path = image_path.resolve()

    try:
        completed = subprocess.run(
            [IMDESC_EXECUTABLE, "--format", "json", str(absolute_path)],
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
            "imdesc_cli_timeout", timeout=IMDESC_TIMEOUT_SECONDS, path=str(absolute_path)
        )
        return None
    except subprocess.CalledProcessError as exc:
        logger.warning(
            "imdesc_cli_error",
            returncode=exc.returncode,
            stderr=_truncate_text(exc.stderr),
            path=str(absolute_path),
        )
        return None
    except Exception:
        logger.warning("imdesc_cli_failed", path=str(absolute_path), exc_info=True)
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


def request_ollama_caption(image_path: Path, ocr_text: str = "") -> Optional[str]:
    """Request an image caption from Ollama vision model.
    
    If ocr_text is empty, the prompt will ask the model to extract visible text.
    If ocr_text is provided, the prompt will focus on scene description only.
    
    Args:
        image_path: Path to the image file
        ocr_text: OCR text already extracted (empty string if none)
    
    Returns:
        Caption string or None if OLLAMA_ENABLED=false or if all attempts fail
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

    logger.debug(
        "ollama_image_prepare",
        path=str(image_path),
        size_bytes=len(image_bytes),
        suffix=image_path.suffix.lower()
    )

    # Downscale and convert image to PNG format if PIL is available (Ollama doesn't support HEIC/HEIF)
    # Downscale to max 1024px on longest side to reduce payload size and improve performance
    if Image is not None:
        try:
            original_bytes_size = len(image_bytes)
            img = Image.open(io.BytesIO(image_bytes))
            original_size = img.size
            max_dimension = 1024
            
            # Downscale if image is larger than max_dimension
            if max(img.size) > max_dimension:
                scale = max_dimension / max(img.size)
                new_size = (int(img.size[0] * scale), int(img.size[1] * scale))
                img = img.resize(new_size, Image.Resampling.LANCZOS)
                logger.debug(
                    "ollama_image_downscaled",
                    original_size=original_size,
                    new_size=new_size,
                    scale=f"{scale:.2f}"
                )
            
            # Convert to RGB if needed (e.g., RGBA or CMYK)
            if img.mode not in ('RGB', 'L'):
                img = img.convert('RGB')
            # Re-encode as PNG
            buf = io.BytesIO()
            img.save(buf, format='PNG', optimize=True)
            image_bytes = buf.getvalue()
            final_bytes_size = len(image_bytes)
            compression_ratio = final_bytes_size / original_bytes_size if original_bytes_size > 0 else 0.0
            logger.debug(
                "ollama_image_converted",
                original_format=image_path.suffix,
                original_bytes=original_bytes_size,
                final_bytes=final_bytes_size,
                compression_ratio=f"{compression_ratio:.2f}"
            )
        except Exception as exc:
            logger.warning(
                "ollama_image_conversion_failed",
                path=str(image_path),
                error=str(exc)
            )
            # Fall back to original bytes (will likely fail with 500)

    image_b64 = base64.b64encode(image_bytes).decode("utf-8")
    
    # Build prompt based on whether OCR already found text
    base_prompt = OLLAMA_CAPTION_PROMPT.replace("ignore text.", "").replace("ignore text", "").strip()
    
    if ocr_text:
        # OCR already found text, focus on scene description
        prompt = base_prompt
        logger.debug("ollama_prompt_scene_only", prompt=_truncate_text(prompt, 200))
    else:
        # No OCR text, ask vision model to extract any visible text
        prompt = f"{base_prompt}. If there is any visible text, include what it says."
        logger.debug("ollama_prompt_with_text_extraction", prompt=_truncate_text(prompt, 200))
    
    payload = {
        "model": OLLAMA_VISION_MODEL,
        "prompt": prompt,
        "images": [image_b64],
        "stream": False,
    }

    logger.debug(
        "ollama_request_prepare",
        url=OLLAMA_API_URL,
        model=OLLAMA_VISION_MODEL,
        has_ocr_text=bool(ocr_text)
    )

    attempt = 0
    last_exc: Optional[Exception] = None
    while attempt <= OLLAMA_MAX_RETRIES:
        try:
            attempt += 1
            logger.debug("ollama_request_send", attempt=attempt, url=OLLAMA_API_URL)
            response = requests.post(
                OLLAMA_API_URL, json=payload, timeout=OLLAMA_TIMEOUT_SECONDS
            )
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
            logger.warning("ollama_request_failed", error=str(exc), attempt=attempt)
            # If response exists, capture body for diagnosis
            try:
                resp = getattr(exc, "response", None)
                if resp is not None:
                    logger.debug("ollama_response_text", text=_truncate_text(getattr(resp, "text", None)))
            except Exception:
                pass
            break

        # If we'll retry, sleep with exponential backoff
        if attempt <= OLLAMA_MAX_RETRIES:
            backoff = 0.5 * (2 ** (attempt - 1))
            logger.debug("ollama_retry_backoff", attempt=attempt, backoff=backoff)
            time.sleep(backoff)

    if last_exc is not None:
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


def sanitize_ocr_result(
    result: Optional[Dict[str, Any]]
) -> Tuple[str, List[Dict[str, Any]], Dict[str, List[str]]]:
    """Extract and validate OCR text, boxes, and entities from imdesc output.
    
    Args:
        result: Raw dict from run_imdesc_ocr()
    
    Returns:
        Tuple of (ocr_text, boxes, entities)
        - ocr_text: Extracted text string (empty if none)
        - boxes: List of bounding box dicts with x, y, w, h keys
        - entities: Dict mapping entity type (dates, phones, urls, addresses) to list of strings
    """
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


def build_image_facets(entities: Dict[str, List[str]]) -> Dict[str, Any]:
    """Build searchable facets from OCR entities.
    
    Args:
        entities: Dict mapping entity type to list of values
    
    Returns:
        Dict with keys for each entity type (dates, phones, urls, addresses)
        plus a 'has_text' boolean indicating if any entities were found
    """
    facets: Dict[str, Any] = {}
    for key in ("dates", "phones", "urls", "addresses"):
        values = entities.get(key)
        if values:
            facets[key] = values
    facets["has_text"] = bool(
        entities.get("dates")
        or entities.get("phones")
        or entities.get("urls")
        or entities.get("addresses")
    )
    return facets


def enrich_image(
    image_path: Path,
    *,
    use_cache: bool = True,
    cache_dict: Optional[Dict[str, Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    """Extract text, entities, and caption from an image file.
    
    This is the main entry point for image enrichment. It:
    1. Computes a hash of the image bytes for caching
    2. Checks cache for existing enrichment data
    3. Runs OCR via imdesc (macOS Vision framework)
    4. Requests caption from Ollama vision model (conditional on OCR results)
    5. Builds searchable facets from extracted entities
    6. Updates cache with results
    
    Args:
        image_path: Path to the image file
        use_cache: Whether to check/update cache (default True)
        cache_dict: Optional dict to use as cache (for external cache management)
    
    Returns:
        Dict with keys:
        - blob_id: SHA256 hash of image bytes
        - ocr_text: Extracted text from Vision OCR
        - ocr_boxes: List of text bounding boxes
        - ocr_entities: Dict of extracted entities (dates, phones, urls, addresses)
        - caption: Ollama vision model caption
        - facets: Searchable facets built from entities
    
    Raises:
        FileNotFoundError: If image_path doesn't exist
        OSError: If image_path can't be read
    """
    # Read image bytes and compute hash
    image_bytes = image_path.read_bytes()
    blob_id = hash_bytes(image_bytes)
    
    # Check cache
    caption = None
    ocr_text = ""
    ocr_boxes: List[Dict[str, Any]] = []
    ocr_entities: Dict[str, List[str]] = {}
    
    if use_cache and cache_dict is not None:
        cached = cache_dict.get(blob_id) or {}
        if isinstance(cached, dict):
            caption = cached.get("caption")
            ocr_text = cached.get("ocr_text", "")
            ocr_boxes = cached.get("ocr_boxes", [])
            ocr_entities = cached.get("ocr_entities", {})
    
    # If not cached, run enrichment
    if not caption and not ocr_text:
        # Run OCR
        ocr_raw = run_imdesc_ocr(image_path)
        ocr_text, ocr_boxes, ocr_entities = sanitize_ocr_result(ocr_raw)
        
        # Request caption (conditional on OCR results)
        caption = request_ollama_caption(image_path, ocr_text=ocr_text)
        caption = _truncate_caption(caption)
        
        # Update cache
        if use_cache and cache_dict is not None:
            cache_dict[blob_id] = {
                "caption": caption,
                "ocr_text": ocr_text,
                "ocr_boxes": ocr_boxes,
                "ocr_entities": ocr_entities,
            }
    else:
        # Using cached data, ensure types are correct
        caption = _truncate_caption(caption)
        if not isinstance(ocr_boxes, list):
            ocr_boxes = []
        if not isinstance(ocr_entities, dict):
            ocr_entities = {}
    
    facets = build_image_facets(ocr_entities)
    
    return {
        "blob_id": blob_id,
        "ocr_text": ocr_text,
        "ocr_boxes": ocr_boxes,
        "ocr_entities": ocr_entities,
        "caption": caption,
        "facets": facets,
    }


class ImageEnrichmentCache:
    """Simple JSON-based cache for image enrichment results.
    
    Stores enrichment data keyed by blob_id (SHA256 hash of image bytes).
    Automatically persists changes to disk when save() is called.
    """
    
    def __init__(self, path: Path) -> None:
        """Initialize cache from disk.
        
        Args:
            path: Path to JSON cache file (will be created if it doesn't exist)
        """
        self.path = path
        self._data: Dict[str, Dict[str, Any]] = {}
        self._dirty = False
        self._load()

    def _load(self) -> None:
        """Load cache from disk."""
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
        """Get cached enrichment data for a blob_id.
        
        Args:
            blob_id: SHA256 hash of image bytes
        
        Returns:
            Dict with enrichment data or None if not cached
        """
        return self._data.get(blob_id)

    def set(self, blob_id: str, payload: Dict[str, Any]) -> None:
        """Store enrichment data for a blob_id.
        
        Args:
            blob_id: SHA256 hash of image bytes
            payload: Dict with enrichment data (caption, ocr_text, ocr_boxes, ocr_entities)
        """
        self._data[blob_id] = payload
        self._dirty = True

    def save(self) -> None:
        """Persist cache to disk if dirty."""
        if not self._dirty:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(self._data))
            self._dirty = False
        except Exception:
            logger.warning("image_cache_save_failed", path=str(self.path), exc_info=True)
    
    def get_data_dict(self) -> Dict[str, Dict[str, Any]]:
        """Get the internal cache dictionary for direct access.
        
        Returns:
            Reference to internal cache dict (mutations will mark cache as dirty)
        """
        return self._data
