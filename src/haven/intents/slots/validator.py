"""Slot value validation and normalization helpers."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Tuple

from dateutil import parser as dateparser

from haven.intents.classifier.taxonomy import SlotDefinition


class SlotValidationError(ValueError):
    """Raised when slot validation fails."""


@dataclass
class SlotValidationResult:
    """Validated slot payload."""

    value: Any
    warnings: List[str]


class SlotValidator:
    """Normalize and validate slot values against taxonomy definitions."""

    def validate(self, slot_name: str, slot_def: SlotDefinition, value: Any) -> SlotValidationResult:
        if value is None:
            raise SlotValidationError(f"slot '{slot_name}' value is None")

        slot_type = (slot_def.type or "").lower()
        if slot_type.startswith("array["):
            inner_type = slot_type[6:-1]
            normalized_value, warnings = self._validate_array(slot_name, inner_type, value)
            return SlotValidationResult(value=normalized_value, warnings=warnings)

        dispatch = {
            "string": self._validate_string,
            "datetime": self._validate_datetime,
            "person": self._validate_person,
            "location": self._validate_location,
        }
        handler = dispatch.get(slot_type, self._validate_passthrough)
        normalized_value, warnings = handler(slot_name, value)
        return SlotValidationResult(value=normalized_value, warnings=warnings)

    def _validate_passthrough(self, slot_name: str, value: Any) -> Tuple[Any, List[str]]:
        return value, [f"slot '{slot_name}' uses unhandled type; passing value through"]

    def _validate_string(self, slot_name: str, value: Any) -> Tuple[str, List[str]]:
        if isinstance(value, str):
            normalized = value.strip()
            if not normalized:
                raise SlotValidationError(f"slot '{slot_name}' string value is empty")
            return normalized, []
        if isinstance(value, dict):
            text = value.get("text") or value.get("value") or value.get("name")
            if isinstance(text, str) and text.strip():
                return text.strip(), ["slot value coerced from object"]
        raise SlotValidationError(f"slot '{slot_name}' expects string-compatible value")

    def _validate_datetime(self, slot_name: str, value: Any) -> Tuple[str, List[str]]:
        candidate = None
        if isinstance(value, str):
            candidate = value.strip()
        elif isinstance(value, dict):
            candidate = value.get("value") or value.get("normalized") or value.get("iso")
        if not candidate:
            raise SlotValidationError(f"slot '{slot_name}' datetime value missing")
        try:
            parsed = dateparser.isoparse(candidate)
        except (ValueError, TypeError) as exc:
            raise SlotValidationError(f"slot '{slot_name}' invalid datetime: {candidate}") from exc
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
            warning = [f"slot '{slot_name}' assumed UTC timezone"]
        else:
            warning = []
        return parsed.isoformat().replace("+00:00", "Z"), warning

    def _validate_person(self, slot_name: str, value: Any) -> Tuple[Dict[str, Any], List[str]]:
        person = self._coerce_person_dict(value)
        if not person.get("name"):
            raise SlotValidationError(f"slot '{slot_name}' person value missing name")
        return person, []

    def _validate_location(self, slot_name: str, value: Any) -> Tuple[str, List[str]]:
        if isinstance(value, str):
            normalized = value.strip()
            if not normalized:
                raise SlotValidationError(f"slot '{slot_name}' location string empty")
            return normalized, []
        if isinstance(value, dict):
            candidate = value.get("normalized") or value.get("name") or value.get("text")
            if isinstance(candidate, str) and candidate.strip():
                return candidate.strip(), ["slot value coerced from object"]
        raise SlotValidationError(f"slot '{slot_name}' expects location-compatible value")

    def _validate_array(
        self, slot_name: str, inner_type: str, value: Any
    ) -> Tuple[List[Any], List[str]]:
        if not isinstance(value, list):
            raise SlotValidationError(f"slot '{slot_name}' expects list for array[{inner_type}]")
        normalized: List[Any] = []
        warnings: List[str] = []
        for idx, element in enumerate(value):
            handler_map = {
                "person": self._validate_person,
                "string": self._validate_string,
            }
            handler = handler_map.get(inner_type, self._validate_passthrough)
            normalized_value, element_warnings = handler(f"{slot_name}[{idx}]", element)
            normalized.append(normalized_value)
            warnings.extend(element_warnings)
        if inner_type not in {"person", "string"}:
            warnings.append(
                f"slot '{slot_name}' array element type '{inner_type}' not explicitly handled; values passed through"
            )
        return normalized, warnings

    def _coerce_person_dict(self, value: Any) -> Dict[str, Any]:
        if isinstance(value, str):
            normalized = value.strip()
            return {"name": normalized} if normalized else {}
        if not isinstance(value, dict):
            raise SlotValidationError("person slot requires dict or string value")
        name = value.get("name") or value.get("display_name") or value.get("text")
        person: Dict[str, Any] = {}
        if isinstance(name, str) and name.strip():
            person["name"] = name.strip()
        identifier = value.get("identifier")
        if isinstance(identifier, str) and identifier.strip():
            person["identifier"] = identifier.strip()
        identifier_type = value.get("identifier_type")
        if isinstance(identifier_type, str) and identifier_type.strip():
            person["identifier_type"] = identifier_type.strip()
        role = value.get("role")
        if isinstance(role, str) and role.strip():
            person["role"] = role.strip()
        metadata = value.get("metadata")
        if isinstance(metadata, dict) and metadata:
            person["metadata"] = metadata
        return person

