"""Shared models for Haven intent processing."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field, validator


class IntentCandidate(BaseModel):
    """Single intent candidate returned by the classifier."""

    intent_name: str = Field(..., alias="name")
    confidence: float = Field(..., ge=0.0, le=1.0)
    base_confidence: float = Field(..., ge=0.0, le=1.0)
    prior_applied: float = Field(1.0, ge=0.0)
    reasons: List[str] = Field(default_factory=list)

    model_config = {"populate_by_name": True}

    @validator("intent_name")
    def normalize_intent_name(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("intent_name must be a non-empty string")
        return normalized

    @validator("confidence", "base_confidence", pre=True)
    def coerce_confidence(cls, value: Any) -> float:
        try:
            return float(value)
        except (TypeError, ValueError) as exc:
            raise ValueError("confidence values must be numeric") from exc


class ClassificationResult(BaseModel):
    """Classifier output for an artifact."""

    taxonomy_version: str
    intents: List[IntentCandidate] = Field(default_factory=list)
    processing_notes: List[str] = Field(default_factory=list)
    raw_response: Optional[Dict[str, Any]] = None

    @validator("taxonomy_version")
    def normalize_version(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("taxonomy_version must be a non-empty string")
        return normalized

    def above_confidence(self, threshold: float) -> List[IntentCandidate]:
        """Return intents whose confidence meets or exceeds the given threshold."""
        return [intent for intent in self.intents if intent.confidence >= threshold]

