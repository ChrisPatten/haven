from __future__ import annotations

import logging
import sys
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

    def __init__(self, logger: logging.Logger):
        self._logger = logger

    def bind(self, **_: Any) -> "_StructlogShim":  # structlog compatibility
        return self

    def _log(self, level: int, event: str, **kwargs: Any) -> None:
        parts = [event]
        if kwargs:
            kv = " ".join(f"{key}={value!r}" for key, value in kwargs.items())
            parts.append(kv)
        self._logger.log(level, " | ".join(parts))

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
        return _StructlogShim(logging.getLogger(name))
    return structlog.get_logger(name)
