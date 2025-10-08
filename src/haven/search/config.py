from __future__ import annotations

import os
from functools import lru_cache

from pydantic import BaseModel, Field


def _default_database_url() -> str:
    return os.getenv("DB_DSN", os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/haven"))


def _default_qdrant_url() -> str:
    return os.getenv("QDRANT_URL", "http://qdrant:6333")


class SearchSettings(BaseModel):
    """Runtime configuration for the Search Service."""

    database_url: str = Field(default_factory=_default_database_url)
    qdrant_url: str = Field(default_factory=_default_qdrant_url)
    qdrant_collection: str = Field(default_factory=lambda: os.getenv("QDRANT_COLLECTION", "haven_chunks"))
    embedding_model: str = Field(default_factory=lambda: os.getenv("EMBEDDING_MODEL", "BAAI/bge-m3"))
    embedding_dim: int = Field(default_factory=lambda: int(os.getenv("EMBEDDING_DIM", "1024")))
    service_name: str = Field(default_factory=lambda: os.getenv("SERVICE_NAME", "search-service"))
    max_batch_size: int = Field(default_factory=lambda: int(os.getenv("SEARCH_INGEST_BATCH", "32")))
    enable_dlq: bool = Field(default_factory=lambda: os.getenv("ENABLE_DLQ", "false").lower() == "true")


@lru_cache(maxsize=1)
def get_settings() -> SearchSettings:
    return SearchSettings()


__all__ = ["SearchSettings", "get_settings"]
