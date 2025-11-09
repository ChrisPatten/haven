"""LLM-backed intent classification utilities."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional

import httpx

from ..models import ClassificationResult, IntentCandidate
from .taxonomy import IntentDefinition, IntentTaxonomy


class ClassificationError(RuntimeError):
    """Raised when classification fails."""


@dataclass
class ClassifierSettings:
    """Runtime settings for the classifier."""

    base_url: str = "http://localhost:11434"
    model: str = "llama3.2"
    timeout: float = 15.0
    min_confidence: float = 0.5


def classify_artifact(
    *,
    text: str,
    taxonomy: IntentTaxonomy,
    entities: Optional[Dict[str, Any]] = None,
    settings: Optional[ClassifierSettings] = None,
    client: Optional[httpx.Client] = None,
) -> ClassificationResult:
    """Classify an artifact using the provided taxonomy via Ollama."""
    if settings is None:
        settings = ClassifierSettings()

    prompt = _build_prompt(
        text=text,
        taxonomy=taxonomy,
        entities=entities,
        min_confidence=settings.min_confidence,
    )
    payload = {
        "model": settings.model,
        "prompt": prompt,
        "format": "json",
        "stream": False,
    }

    try:
        raw_response = _invoke_ollama(
            payload=payload, settings=settings, client=client
        )
    except httpx.RequestError as exc:  # pragma: no cover - network errors
        raise ClassificationError(str(exc)) from exc

    structured = _parse_response(raw_response)
    intents = _coerce_intents(structured.get("intents", []), taxonomy)
    notes = _collect_notes(structured)

    result = ClassificationResult(
        taxonomy_version=taxonomy.version,
        intents=intents,
        processing_notes=notes,
        raw_response=structured,
    )
    return result


def _build_prompt(
    *,
    text: str,
    taxonomy: IntentTaxonomy,
    entities: Optional[Dict[str, Any]],
    min_confidence: float,
) -> str:
    taxonomy_summary = _summarize_taxonomy(taxonomy)
    entities_block = json.dumps(entities or {}, ensure_ascii=False, indent=2)
    return (
        "You are an intent classification assistant. "
        "Given the following artifact text and extracted entities, "
        "identify which intents from the provided taxonomy are present. "
        "Return a JSON object with this structure:\n"
        "{"
        '"intents": ['
        '{"name": "<intent_name>", "base_confidence": 0.0-1.0, "reasons": ["..."]}'
        "],"
        '"notes": ["optional explanatory notes"]'
        "}\n"
        "Only include intents whose confidence is at least "
        f"{min_confidence:.2f}. "
        "Confidence values must be floats between 0 and 1. "
        "Use multi-label classification (zero or more intents may apply).\n\n"
        f"Taxonomy version: {taxonomy.version}\n"
        "Available intents:\n"
        f"{taxonomy_summary}\n\n"
        f"Entities (JSON):\n{entities_block}\n\n"
        "Artifact text:\n"
        "-----\n"
        f"{text.strip()}\n"
        "-----"
    )


def _summarize_taxonomy(taxonomy: IntentTaxonomy) -> str:
    lines: List[str] = []
    for name, definition in taxonomy.intents.items():
        lines.append(_summarize_intent(name, definition))
    return "\n".join(lines)


def _summarize_intent(name: str, definition: IntentDefinition) -> str:
    slot_parts = []
    for slot_name, slot_def in definition.slots.items():
        required_flag = "required" if slot_def.required else "optional"
        slot_parts.append(f"{slot_name} ({slot_def.type}, {required_flag})")
    slot_summary = ", ".join(slot_parts) if slot_parts else "no slots"
    description = definition.description or "No description provided."
    return f"- {name}: {description} Slots: {slot_summary}."


def _invoke_ollama(
    *,
    payload: Dict[str, Any],
    settings: ClassifierSettings,
    client: Optional[httpx.Client],
) -> str:
    if client is not None:
        response = client.post("/api/generate", json=payload)
    else:
        with httpx.Client(base_url=settings.base_url, timeout=settings.timeout) as local:
            response = local.post("/api/generate", json=payload)
    response.raise_for_status()
    data = response.json()
    response_text = data.get("response")
    if not isinstance(response_text, str):
        raise ClassificationError("unexpected response payload from Ollama")
    return response_text


def _parse_response(raw: str) -> Dict[str, Any]:
    """Parse JSON payload from the model output."""
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # Attempt to extract JSON substring
        start = raw.find("{")
        end = raw.rfind("}")
        if start == -1 or end == -1 or end <= start:
            raise ClassificationError("classifier response is not valid JSON")
        try:
            return json.loads(raw[start : end + 1])
        except json.JSONDecodeError as exc:
            raise ClassificationError("failed to parse classifier JSON output") from exc


def _coerce_intents(
    intents: Iterable[Any], taxonomy: IntentTaxonomy
) -> List[IntentCandidate]:
    """Convert raw intent payloads into IntentCandidate models."""
    results: List[IntentCandidate] = []
    valid_intents = set(taxonomy.intents.keys())
    for raw in intents:
        if not isinstance(raw, dict):
            continue
        name = raw.get("name") or raw.get("intent") or raw.get("intent_name")
        if not isinstance(name, str) or name not in valid_intents:
            continue
        base_conf = _extract_confidence(raw, key="base_confidence")
        if base_conf is None:
            base_conf = _extract_confidence(raw, key="confidence")
        if base_conf is None:
            continue
        prior_applied = _extract_confidence(raw, key="prior_applied") or 1.0
        final_conf = _extract_confidence(raw, key="confidence") or base_conf
        reasons = raw.get("reasons") or raw.get("rationale") or []
        if isinstance(reasons, str):
            reasons = [reasons]
        candidate = IntentCandidate(
            intent_name=name,
            base_confidence=base_conf,
            confidence=min(max(final_conf, 0.0), 1.0),
            prior_applied=prior_applied,
            reasons=[str(reason) for reason in reasons if reason],
        )
        results.append(candidate)
    return results


def _extract_confidence(
    payload: Dict[str, Any], *, key: str
) -> Optional[float]:
    """Safely extract a confidence value from payload."""
    if key not in payload:
        return None
    try:
        value = float(payload[key])
    except (TypeError, ValueError):
        return None
    if value < 0.0:
        return 0.0
    if value > 1.0:
        return 1.0
    return value


def _collect_notes(structured: Dict[str, Any]) -> List[str]:
    """Collect processing notes from classifier output."""
    raw_notes = structured.get("notes") or structured.get("processing_notes")
    if not raw_notes:
        return []
    if isinstance(raw_notes, str):
        return [raw_notes]
    if isinstance(raw_notes, Iterable):
        return [str(note) for note in raw_notes if note]
    return []

