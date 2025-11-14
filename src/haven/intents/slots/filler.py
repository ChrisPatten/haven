"""Slot filling orchestration."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

import httpx

from haven.intents.classifier.taxonomy import IntentDefinition, IntentTaxonomy, SlotDefinition
from haven.intents.models import ClassificationResult, IntentCandidate

from .extractor import LLMSlotExtractor, SlotExtractionError, SlotExtractorSettings
from .validator import SlotValidationError, SlotValidationResult, SlotValidator


@dataclass
class SlotFillerSettings:
    """Configuration for slot filling."""

    ollama_base_url: str = "http://localhost:11434"
    slot_model: str = "llama3.2"
    request_timeout: float = 15.0


@dataclass
class SlotAssignment:
    """Slot assignments for a single intent."""

    intent_name: str
    confidence: float
    slots: Dict[str, Any]
    missing_slots: List[str]
    slot_sources: Dict[str, str] = field(default_factory=dict)
    notes: List[str] = field(default_factory=list)


@dataclass
class SlotFillerResult:
    """Aggregate slot filling output."""

    assignments: List[SlotAssignment]
    notes: List[str]


class SlotFiller:
    """Map entities, invoke extraction, and validate slot values."""

    def __init__(self, settings: Optional[SlotFillerSettings] = None):
        self.settings = settings or SlotFillerSettings()
        self._validator = SlotValidator()
        self._extractor = LLMSlotExtractor(
            SlotExtractorSettings(
                base_url=self.settings.ollama_base_url,
                model=self.settings.slot_model,
                timeout=self.settings.request_timeout,
            )
        )

    def fill_slots(
        self,
        *,
        job_text: str,
        classification: ClassificationResult,
        taxonomy: IntentTaxonomy,
        entity_payload: Optional[Dict[str, Any]],
        artifact_id: str,
        source_type: str,
        thread_context: Optional[List[Dict[str, Any]]] = None,
        content_timestamp: Optional[str] = None,
    ) -> SlotFillerResult:
        assignments: List[SlotAssignment] = []
        notes: List[str] = []

        if not classification.intents:
            return SlotFillerResult(assignments=[], notes=["no intents above confidence threshold"])

        entities = entity_payload or {}
        for candidate in classification.intents:
            intent_def = taxonomy.intents.get(candidate.intent_name)
            if not intent_def:
                notes.append(f"intent '{candidate.intent_name}' missing from taxonomy")
                continue
            assignment = self._fill_for_intent(
                candidate=candidate,
                intent_definition=intent_def,
                text=job_text,
                entities=entities,
                artifact_id=artifact_id,
                source_type=source_type,
                classification_notes=classification.processing_notes,
                thread_context=thread_context,
                content_timestamp=content_timestamp,
            )
            assignments.append(assignment)
            notes.extend(assignment.notes)

        return SlotFillerResult(assignments=assignments, notes=notes)

    def _fill_for_intent(
        self,
        *,
        candidate: IntentCandidate,
        intent_definition: IntentDefinition,
        text: str,
        entities: Dict[str, Any],
        artifact_id: str,
        source_type: str,
        classification_notes: List[str],
        thread_context: Optional[List[Dict[str, Any]]] = None,
        content_timestamp: Optional[str] = None,
    ) -> SlotAssignment:
        slots: Dict[str, Any] = {}
        slot_sources: Dict[str, str] = {}
        notes: List[str] = []
        slot_defs = intent_definition.slots

        # Always provide source_ref when slot is available.
        if "source_ref" in slot_defs:
            self._assign_slot(
                slot_name="source_ref",
                slot_def=slot_defs["source_ref"],
                raw_value=str(artifact_id),
                source="default",
                slots=slots,
                slot_sources=slot_sources,
                notes=notes,
            )

        # Entity-backed slot population.
        entity_slots, entity_sources = self._slots_from_entities(
            slot_defs=slot_defs,
            entities=entities,
            source_type=source_type,
        )
        for slot_name, raw_value in entity_slots.items():
            self._assign_slot(
                slot_name=slot_name,
                slot_def=slot_defs[slot_name],
                raw_value=raw_value,
                source=entity_sources.get(slot_name, "entity"),
                slots=slots,
                slot_sources=slot_sources,
                notes=notes,
            )

        missing_slots = [
            name
            for name, definition in slot_defs.items()
            if definition.required and name not in slots
        ]

        # Use LLM extraction for remaining required slots (and optional gaps when helpful).
        optional_missing = [
            name
            for name, definition in slot_defs.items()
            if not definition.required and name not in slots
        ]
        # For schedule.create, always prioritize title extraction if not present
        if candidate.intent_name == "schedule.create" and "title" not in slots:
            if "title" in optional_missing:
                # Move title to the front if it's already in the list
                optional_missing.remove("title")
                optional_missing.insert(0, "title")
            elif "title" in slot_defs:
                # Add title if it exists in slot definitions but wasn't included
                optional_missing.insert(0, "title")
        extraction_targets = missing_slots + optional_missing

        if extraction_targets:
            try:
                extraction = self._extractor.extract(
                    intent_name=candidate.intent_name,
                    intent_definition=intent_definition,
                    text=text,
                    entities=entities,
                    existing_slots=slots,
                    missing_slots=extraction_targets,
                    classification_notes=classification_notes,
                    thread_context=thread_context,
                    content_timestamp=content_timestamp,
                )
            except SlotExtractionError as exc:
                notes.append(f"slot extraction failed: {exc}")
            else:
                # Log what was requested vs what was returned (for debugging)
                if candidate.intent_name == "schedule.create":
                    requested_slots = set(extraction_targets)
                    returned_slots = set(extraction.slots.keys())
                    missing_from_response = requested_slots - returned_slots
                    if missing_from_response:
                        notes.append(
                            f"LLM was asked to extract {sorted(requested_slots)} but only returned {sorted(returned_slots)}. "
                            f"Missing from response: {sorted(missing_from_response)}"
                        )
                
                for slot_name, raw_value in extraction.slots.items():
                    if slot_name not in slot_defs:
                        notes.append(f"LLM returned unknown slot '{slot_name}'")
                        continue
                    self._assign_slot(
                        slot_name=slot_name,
                        slot_def=slot_defs[slot_name],
                        raw_value=raw_value,
                        source="llm",
                        slots=slots,
                        slot_sources=slot_sources,
                        notes=notes,
                    )
                notes.extend(extraction.notes)

        missing_required_after = [
            name
            for name, definition in slot_defs.items()
            if definition.required and name not in slots
        ]

        return SlotAssignment(
            intent_name=candidate.intent_name,
            confidence=candidate.confidence,
            slots=slots,
            missing_slots=missing_required_after,
            slot_sources=slot_sources,
            notes=notes,
        )

    def _assign_slot(
        self,
        *,
        slot_name: str,
        slot_def: SlotDefinition,
        raw_value: Any,
        source: str,
        slots: Dict[str, Any],
        slot_sources: Dict[str, str],
        notes: List[str],
    ) -> None:
        if raw_value is None or slot_name in slots:
            return
        try:
            validation = self._validator.validate(slot_name, slot_def, raw_value)
        except SlotValidationError as exc:
            notes.append(str(exc))
            return
        slots[slot_name] = validation.value
        slot_sources[slot_name] = source
        notes.extend(validation.warnings)

    def _slots_from_entities(
        self,
        *,
        slot_defs: Dict[str, SlotDefinition],
        entities: Dict[str, Any],
        source_type: str,
    ) -> Tuple[Dict[str, Any], Dict[str, str]]:
        if not entities:
            return {}, {}

        mapped: Dict[str, Any] = {}
        sources: Dict[str, str] = {}

        for slot_name, slot_def in slot_defs.items():
            if slot_name == "source_ref":
                continue
            value = self._match_entity_for_slot(slot_name, slot_def, entities, source_type)
            if value is not None:
                mapped[slot_name] = value
                sources[slot_name] = "entity"
        return mapped, sources

    def _match_entity_for_slot(
        self,
        slot_name: str,
        slot_def: SlotDefinition,
        entities: Dict[str, Any],
        source_type: str,
    ) -> Any:
        slot_type = (slot_def.type or "").lower()
        if slot_type == "datetime":
            return self._first_datetime(slot_name, entities)
        if slot_type == "person":
            return self._first_person(entities)
        if slot_type == "array[person]":
            return self._all_people(entities)
        if slot_type == "location":
            return self._first_location(entities)
        if slot_type == "string" and slot_name.endswith("_ref"):
            # Already handled elsewhere.
            return None
        return None

    def _first_datetime(self, slot_name: str, entities: Dict[str, Any]) -> Optional[Any]:
        dateranges = self._coerce_list(entities.get("dateranges"))
        if dateranges:
            normalized = dateranges[0].get("normalizedValue")
            if isinstance(normalized, dict):
                key = "start" if "start" in normalized else None
                if slot_name.endswith("start") or slot_name.endswith("start_dt"):
                    key = "start"
                elif slot_name.endswith("end") or slot_name.endswith("end_dt"):
                    key = "end"
                if key and normalized.get(key):
                    return normalized[key]
        dates = self._coerce_list(entities.get("dates"))
        if dates:
            value = dates[0].get("normalizedValue") or dates[0].get("value")
            if not value and isinstance(dates[0].get("entity"), dict):
                value = dates[0]["entity"].get("normalizedValue") or dates[0]["entity"].get("text")
            return value
        return None

    def _first_person(self, entities: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        people = self._coerce_list(entities.get("people"))
        if people:
            return self._coerce_person_payload(people[0])
        channel_context = entities.get("channel_context", {})
        if isinstance(channel_context, dict):
            sender = channel_context.get("from")
            if sender:
                return self._coerce_person_payload(sender)
        return None

    def _all_people(self, entities: Dict[str, Any]) -> List[Dict[str, Any]]:
        mapped: List[Dict[str, Any]] = []
        for person in self._coerce_list(entities.get("people")) or []:
            payload = self._coerce_person_payload(person)
            if payload:
                mapped.append(payload)
        if not mapped:
            channel_context = entities.get("channel_context", {})
            if isinstance(channel_context, dict):
                recipients = channel_context.get("to") or []
                for recipient in self._coerce_list(recipients) or []:
                    payload = self._coerce_person_payload(recipient)
                    if payload:
                        mapped.append(payload)
        return mapped

    def _first_location(self, entities: Dict[str, Any]) -> Optional[str]:
        places = self._coerce_list(entities.get("places"))
        if places:
            location = places[0].get("normalizedValue") or places[0].get("value")
            if not location and isinstance(places[0].get("entity"), dict):
                location = places[0]["entity"].get("text")
            return location
        return None

    def _coerce_list(self, value: Any) -> Optional[List[Any]]:
        if isinstance(value, list):
            return value
        if value is None:
            return None
        return [value]

    def _coerce_person_payload(self, value: Any) -> Optional[Dict[str, Any]]:
        person: Dict[str, Any] = {}
        if isinstance(value, dict):
            normalized = (
                value.get("normalizedValue")
                or value.get("name")
                or value.get("display_name")
                or value.get("text")
            )
            if isinstance(normalized, str) and normalized.strip():
                person["name"] = normalized.strip()
            identifier = value.get("identifier")
            if not identifier and isinstance(value.get("entity"), dict):
                identifier = value["entity"].get("normalizedValue")
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
        elif isinstance(value, str) and value.strip():
            person["name"] = value.strip()
        if not person:
            return None
        return person


