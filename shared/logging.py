from __future__ import annotations

import logging
import sys
from datetime import datetime, timezone
from typing import Any, Dict

try:
    import structlog  # type: ignore
except ImportError:  # pragma: no cover - best effort fallback
    structlog = None  # type: ignore[assignment]


def _coerce_level(level: str | int) -> int:
    if isinstance(level, str):
        return getattr(logging, level.upper(), logging.INFO)
    return level


class _StructlogShim:
    """Minimal structlog-like interface backed by stdlib logging."""

    def __init__(self, logger: logging.Logger, context: Dict[str, Any] | None = None):
        self._logger = logger
        self._context: Dict[str, Any] = context or {}

    def bind(self, **kwargs: Any) -> "_StructlogShim":  # structlog compatibility
        new_context = self._context.copy()
        new_context.update(kwargs)
        return _StructlogShim(self._logger, new_context)

    def _log(self, level: int, event: str, **kwargs: Any) -> None:
        payload: Dict[str, Any] = self._context.copy()
        payload.update(kwargs)
        parts = [event]
        if payload:
            kv = " ".join(f"{key}={value!r}" for key, value in payload.items())
            parts.append(kv)
        message = " | ".join(parts)
        # Prepend ISO timestamp for fallback logging
        timestamp = datetime.now(timezone.utc).isoformat()
        self._logger.log(level, f"{timestamp} {message}")

    def debug(self, event: str, **kwargs: Any) -> None:
        self._log(logging.DEBUG, event, **kwargs)

    def info(self, event: str, **kwargs: Any) -> None:
        self._log(logging.INFO, event, **kwargs)

    def warning(self, event: str, **kwargs: Any) -> None:
        self._log(logging.WARNING, event, **kwargs)

    def error(self, event: str, **kwargs: Any) -> None:
        self._log(logging.ERROR, event, **kwargs)

    def exception(self, event: str, **kwargs: Any) -> None:
        self._log(logging.ERROR, event, **kwargs)


def setup_logging(level: str | int = "INFO") -> None:
    """Configure logging for the Haven services.

    Falls back to the standard library when structlog is unavailable.
    """

    logging_level = _coerce_level(level)
    
    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=logging_level,
    )
    
    # Configure timestamp format for uvicorn access logs (HTTP request logs)
    # These are the "INFO: 172.18.0.8:36656 - "POST /v1/catalog/embeddings HTTP/1.1" 200 OK" logs
    timestamp_format = "%(asctime)s"
    date_format = "%Y-%m-%d %H:%M:%S"
    
    # Create a formatter with timestamp for uvicorn access logs
    access_formatter = logging.Formatter(
        f"{timestamp_format} %(levelname)s: %(message)s",
        datefmt=date_format,
    )
    
    # Configure uvicorn access logger (used for HTTP request logs)
    # This logger is created by Uvicorn for access logs
    access_logger = logging.getLogger("uvicorn.access")
    
    # Update existing handlers with timestamp formatter (Uvicorn sets these up before app startup)
    if access_logger.handlers:
        for handler in access_logger.handlers:
            handler.setFormatter(access_formatter)
            handler.setLevel(logging_level)
    else:
        # If no handlers yet, configure one (shouldn't happen but handle it)
        access_handler = logging.StreamHandler(sys.stdout)
        access_handler.setFormatter(access_formatter)
        access_handler.setLevel(logging_level)
        access_logger.addHandler(access_handler)
    
    access_logger.setLevel(logging_level)

    if structlog is None:
        logging.getLogger().setLevel(logging_level)
        return

    structlog.configure(
        processors=[
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.stdlib.add_log_level,
            structlog.stdlib.PositionalArgumentsFormatter(),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(logging_level),
        context_class=dict,
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str):
    if structlog is None:
        return _StructlogShim(logging.getLogger(name)).bind(
            doc_id=None,
            external_id=None,
            source_type=None,
            version_number=None,
        )
    return structlog.get_logger(name).bind(
        doc_id=None,
        external_id=None,
        source_type=None,
        version_number=None,
    )
