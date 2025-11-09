"""Channel-aware prior adjustments for intent classification."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Dict, Iterable, List

from ..models import IntentCandidate
from .taxonomy import IntentDefinition, IntentTaxonomy

DEFAULT_PRIORS: Dict[str, Dict[str, float]] = {
    "email": {
        "schedule.create": 1.2,
        "task.create": 0.9,
    },
    "imessage": {
        "reminder.create": 1.2,  # Matches taxonomy channel_priors
    },
    "note": {
        "task.create": 1.15,
        "reminder.create": 1.05,
    },
}

ENV_PRIOR_OVERRIDE_KEY = "INTENT_PRIOR_OVERRIDES"


@dataclass
class PriorConfig:
    """Configuration for applying priors."""

    default_multiplier: float = 1.0
    min_multiplier: float = 0.1
    max_multiplier: float = 2.0
    clamp_output: bool = True
    env_var: str = ENV_PRIOR_OVERRIDE_KEY
    default_priors: Dict[str, Dict[str, float]] = field(
        default_factory=lambda: DEFAULT_PRIORS.copy()
    )


def apply_channel_priors(
    *,
    channel: str,
    candidates: Iterable[IntentCandidate],
    taxonomy: IntentTaxonomy,
    config: PriorConfig | None = None,
) -> List[IntentCandidate]:
    """Apply channel-aware priors to intent candidates."""
    if config is None:
        config = PriorConfig()
    channel_key = channel.lower().strip()
    env_overrides = _load_env_overrides(config.env_var)

    adjusted: List[IntentCandidate] = []
    for candidate in candidates:
        intent_name = candidate.intent_name
        definition = taxonomy.intents.get(intent_name)
        multiplier = _resolve_multiplier(
            channel=channel_key,
            intent=intent_name,
            definition=definition,
            env_overrides=env_overrides,
            default_priors=config.default_priors,
            fallback=config.default_multiplier,
        )
        multiplier = _clamp(multiplier, config.min_multiplier, config.max_multiplier)
        confidence = candidate.base_confidence * multiplier
        if config.clamp_output:
            confidence = _clamp(confidence, 0.0, 1.0)
        adjusted.append(
            candidate.copy(
                update={
                    "confidence": confidence,
                    "prior_applied": multiplier,
                }
            )
        )
    return adjusted


_ENV_CACHE: Dict[str, Dict[str, Dict[str, float]]] = {}


def _load_env_overrides(env_var: str) -> Dict[str, Dict[str, float]]:
    """Load channel priors from environment variable, caching per key."""
    if env_var in _ENV_CACHE:
        return _ENV_CACHE[env_var]
    raw = os.getenv(env_var)
    if not raw:
        _ENV_CACHE[env_var] = {}
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        _ENV_CACHE[env_var] = {}
        return {}
    overrides: Dict[str, Dict[str, float]] = {}
    if isinstance(parsed, dict):
        for channel, mapping in parsed.items():
            if not isinstance(mapping, dict):
                continue
            channel_key = str(channel).lower()
            channel_map: Dict[str, float] = {}
            for intent_name, multiplier in mapping.items():
                try:
                    channel_map[str(intent_name)] = float(multiplier)
                except (TypeError, ValueError):
                    continue
            if channel_map:
                overrides[channel_key] = channel_map
    _ENV_CACHE[env_var] = overrides
    return overrides


def _resolve_multiplier(
    *,
    channel: str,
    intent: str,
    definition: IntentDefinition | None,
    env_overrides: Dict[str, Dict[str, float]],
    default_priors: Dict[str, Dict[str, float]],
    fallback: float,
) -> float:
    """Determine the most appropriate multiplier for the intent and channel."""
    if channel and channel in env_overrides and intent in env_overrides[channel]:
        return env_overrides[channel][intent]

    if definition and definition.channel_priors:
        scoped_multiplier = definition.channel_priors.get(channel)
        if scoped_multiplier is not None:
            return scoped_multiplier

    if channel in default_priors and intent in default_priors[channel]:
        return default_priors[channel][intent]

    return fallback


def _clamp(value: float, min_value: float, max_value: float) -> float:
    """Clamp value to the provided range."""
    return max(min_value, min(value, max_value))

