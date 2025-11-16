"""Taxonomy loading and validation helpers for Haven intents."""

from __future__ import annotations

import json
import threading
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field, validator

try:
    import yaml  # type: ignore
except ModuleNotFoundError as exc:  # pragma: no cover - defensive
    raise RuntimeError(
        "PyYAML is required to load taxonomy definitions. "
        "Install it via `pip install pyyaml`."
    ) from exc


class SlotDefinition(BaseModel):
    """Definition of a single slot within an intent."""

    type: str
    required: bool = False
    constraints: Optional[Dict[str, Any]] = None
    description: Optional[str] = None

    @validator("type")
    def validate_type(cls, value: str) -> str:
        """Ensure slot type is present and normalized."""
        normalized = value.strip().lower()
        if not normalized:
            raise ValueError("slot type must be a non-empty string")
        return normalized


class IntentDefinition(BaseModel):
    """Definition of an intent and its associated slots."""

    description: Optional[str] = None
    slots: Dict[str, SlotDefinition] = Field(default_factory=dict)
    constraints: Optional[List[Dict[str, Any]]] = None
    examples: Optional[List[str]] = None
    channel_priors: Dict[str, float] = Field(default_factory=dict)

    @validator("slots", pre=True)
    def coerce_slots(cls, value: Any) -> Dict[str, Any]:
        """Ensure slots are represented as a dictionary."""
        if value is None:
            return {}
        if isinstance(value, dict):
            return value
        raise ValueError("slots must be defined as an object mapping slot names to definitions")

    @validator("channel_priors", pre=True)
    def normalize_priors(cls, value: Any) -> Dict[str, float]:
        """Normalize channel priors to floats keyed by lowercase channel name."""
        if not value:
            return {}
        priors: Dict[str, float] = {}
        for channel, prior in dict(value).items():
            try:
                priors[str(channel).lower()] = float(prior)
            except (TypeError, ValueError) as exc:
                raise ValueError(f"invalid prior for channel '{channel}'") from exc
        return priors


class IntentTaxonomy(BaseModel):
    """Versioned taxonomy definition for intent classification."""

    version: str
    created_at: Optional[datetime] = None
    description: Optional[str] = None
    intents: Dict[str, IntentDefinition]

    @validator("version")
    def validate_version(cls, value: str) -> str:
        version = value.strip()
        if not version:
            raise ValueError("taxonomy version must be a non-empty string")
        return version

    def intent_names(self) -> List[str]:
        """Return all intent names, preserving taxonomy order."""
        return list(self.intents.keys())


class TaxonomyLoader:
    """Loader with caching semantics for taxonomy definitions."""

    def __init__(self, taxonomy_path: str | Path):
        self._path = Path(taxonomy_path)
        self._lock = threading.Lock()
        self._cache: Optional[tuple[float, IntentTaxonomy]] = None

    @property
    def path(self) -> Path:
        """Return the resolved taxonomy path."""
        return self._path

    def load(self, force: bool = False) -> IntentTaxonomy:
        """Load taxonomy from disk, caching by modification time."""
        path = self._path
        if not path.exists():
            raise FileNotFoundError(f"taxonomy file not found: {path}")

        mtime = path.stat().st_mtime
        if not force and self._cache and self._cache[0] == mtime:
            return self._cache[1]

        with self._lock:
            # Re-check cache inside lock to avoid thundering herd
            if not force and self._cache and self._cache[0] == mtime:
                return self._cache[1]

            payload = _read_taxonomy_payload(path)
            taxonomy = IntentTaxonomy.parse_obj(payload)
            self._cache = (mtime, taxonomy)
            return taxonomy


_GLOBAL_CACHE: Dict[Path, TaxonomyLoader] = {}
_GLOBAL_LOCK = threading.Lock()


def get_loader(taxonomy_path: str | Path) -> TaxonomyLoader:
    """Return a cached loader for the provided taxonomy path."""
    resolved = Path(taxonomy_path).resolve()
    with _GLOBAL_LOCK:
        loader = _GLOBAL_CACHE.get(resolved)
        if loader is None:
            loader = TaxonomyLoader(resolved)
            _GLOBAL_CACHE[resolved] = loader
        return loader


def load_taxonomy(taxonomy_path: str | Path, *, force: bool = False) -> IntentTaxonomy:
    """Convenience helper to load a taxonomy definition."""
    return get_loader(taxonomy_path).load(force=force)


def _read_taxonomy_payload(path: Path) -> Dict[str, Any]:
    """Read taxonomy payload from YAML or JSON file."""
    suffix = path.suffix.lower()
    text = path.read_text(encoding="utf-8")
    if suffix in {".yaml", ".yml"}:
        data = yaml.safe_load(text)
    elif suffix == ".json":
        data = json.loads(text)
    else:
        raise ValueError(
            f"unsupported taxonomy file format '{suffix}'. "
            "Supported formats: .yaml, .yml, .json"
        )

    if not isinstance(data, dict):
        raise ValueError("taxonomy file must contain an object at the root")
    return data

