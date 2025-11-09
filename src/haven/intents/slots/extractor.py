"""LLM-backed slot extraction helpers."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import httpx

from haven.intents.classifier.taxonomy import IntentDefinition


class SlotExtractionError(RuntimeError):
    """Raised when slot extraction fails."""


@dataclass
class SlotExtractorSettings:
    """Runtime configuration for the slot extractor."""

    base_url: str = "http://localhost:11434"
    model: str = "llama3.2"
    timeout: float = 15.0


@dataclass
class SlotExtractionResult:
    """Structured extraction payload returned by the LLM."""

    slots: Dict[str, Any]
    notes: List[str]


class LLMSlotExtractor:
    """Extract missing slot values using an LLM prompt."""

    def __init__(self, settings: Optional[SlotExtractorSettings] = None):
        self.settings = settings or SlotExtractorSettings()

    def extract(
        self,
        *,
        intent_name: str,
        intent_definition: IntentDefinition,
        text: str,
        entities: Dict[str, Any],
        existing_slots: Dict[str, Any],
        missing_slots: List[str],
        classification_notes: Optional[List[str]] = None,
        thread_context: Optional[List[Dict[str, Any]]] = None,
    ) -> SlotExtractionResult:
        if not missing_slots:
            return SlotExtractionResult(slots={}, notes=[])

        prompt = self._build_prompt(
            intent_name=intent_name,
            intent_definition=intent_definition,
            text=text,
            entities=entities,
            existing_slots=existing_slots,
            missing_slots=missing_slots,
            classification_notes=classification_notes or [],
            thread_context=thread_context,
        )
        payload = {
            "model": self.settings.model,
            "prompt": prompt,
            "format": "json",
            "stream": False,
        }

        try:
            response = self._invoke_ollama(payload)
        except httpx.HTTPError as exc:  # pragma: no cover - network
            raise SlotExtractionError(str(exc)) from exc

        structured = self._parse_response(response)
        slots = structured.get("slots")
        if not isinstance(slots, dict):
            slots = {}
        notes = structured.get("notes")
        if isinstance(notes, str):
            notes = [notes]
        elif not isinstance(notes, list):
            notes = []
        return SlotExtractionResult(slots=slots, notes=[str(note) for note in notes if note])

    def _invoke_ollama(self, payload: Dict[str, Any]) -> str:
        with httpx.Client(
            base_url=self.settings.base_url,
            timeout=self.settings.timeout,
        ) as client:
            resp = client.post("/api/generate", json=payload)
            resp.raise_for_status()
            data = resp.json()
        response_text = data.get("response")
        if not isinstance(response_text, str):
            raise SlotExtractionError("unexpected response payload from Ollama")
        return response_text

    def _parse_response(self, raw: str) -> Dict[str, Any]:
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            start = raw.find("{")
            end = raw.rfind("}")
            if start == -1 or end == -1 or end <= start:
                raise SlotExtractionError("slot extractor response is not valid JSON")
            try:
                return json.loads(raw[start : end + 1])
            except json.JSONDecodeError as exc:
                raise SlotExtractionError("failed to parse slot extractor JSON output") from exc

    def _build_prompt(
        self,
        *,
        intent_name: str,
        intent_definition: IntentDefinition,
        text: str,
        entities: Dict[str, Any],
        existing_slots: Dict[str, Any],
        missing_slots: List[str],
        classification_notes: List[str],
        thread_context: Optional[List[Dict[str, Any]]] = None,
    ) -> str:
        slot_instructions = []
        for slot_name in missing_slots:
            slot_def = intent_definition.slots.get(slot_name)
            if not slot_def:
                continue
            optionality = "required" if slot_def.required else "optional"
            constraints = ""
            if slot_def.constraints:
                constraints = f" Constraints: {json.dumps(slot_def.constraints, ensure_ascii=False)}."
            description = slot_def.description or ""
            desc_hint = f" ({description})" if description else ""
            slot_instructions.append(
                f'- "{slot_name}" ({slot_def.type}, {optionality}){desc_hint}.{constraints}'
            )
        slots_block = "\n".join(slot_instructions) or "(no slot definitions found)"
        existing_block = json.dumps(existing_slots, ensure_ascii=False, indent=2)
        entities_block = json.dumps(entities, ensure_ascii=False, indent=2)
        notes_block = json.dumps(classification_notes, ensure_ascii=False)
        
        thread_block = ""
        if thread_context:
            thread_messages = []
            for msg in thread_context[-5:]:  # Last 5 messages for context
                msg_text = msg.get("text", "")
                sender = msg.get("sender") or msg.get("from")
                if msg_text:
                    sender_str = f" ({sender})" if sender else ""
                    thread_messages.append(f"- {msg_text[:200]}{sender_str}")
            if thread_messages:
                thread_block = (
                    "\n\nPrevious messages in this conversation (for context):\n"
                    + "\n".join(thread_messages)
                    + "\n"
                )
        
        channel_context_hint = ""
        if entities.get("channel_context"):
            ctx = entities["channel_context"]
            from_person = ctx.get("from", {}).get("display_name", "")
            to_people = [p.get("display_name", "") for p in ctx.get("to", [])]
            if from_person or to_people:
                channel_context_hint = (
                    "\n\nChannel context: "
                    f"From: {from_person or 'unknown'}, "
                    f"To: {', '.join(to_people) if to_people else 'unknown'}.\n"
                    "Use this to resolve pronouns:\n"
                    "- 'you' / 'your' refers to the recipient(s)\n"
                    "- 'me' / 'my' / 'I' refers to the sender\n"
                    "- 'we' / 'us' refers to the conversation participants\n"
                )

        return (
            "You are an assistant that extracts missing slot values for intents.\n"
            f"Intent: {intent_name}\n"
            f"Intent description: {intent_definition.description or 'No description'}\n\n"
            "Missing slot definitions:\n"
            f"{slots_block}\n\n"
            "Extraction rules:\n"
            "- Return strict JSON with keys: slots (object) and notes (array of strings).\n"
            "- Only include the slots requested. Do not include already known slots unless a better value is available.\n"
            "- Extract values from the artifact text, entities, or conversation context.\n"
            "- For datetime slots, return ISO 8601 strings with timezone offsets (e.g., 2025-11-09T15:04:00-05:00). If timezone unknown, assume UTC and append 'Z'.\n"
            "- For person slots, return objects with at least a 'name' property. Include 'role' (e.g., 'sender', 'recipient', 'assignee') and 'identifier' if available from entities or channel context.\n"
            "- For array[person] slots, return a list of person objects as described above.\n"
            "- For location slots, prefer structured references from entities; otherwise, extract from the artifact text.\n"
            "- For string slots, preserve the full semantic meaning (e.g., 'pick up eggs for me' not just 'eggs').\n"
            "- Do not hallucinate values. If information is unavailable, omit the slot and explain in notes.\n"
            f"{channel_context_hint}"
            f"{thread_block}"
            f"\nExisting slots (already filled):\n{existing_block}\n\n"
            f"Entities (pre-extracted):\n{entities_block}\n\n"
            f"Classifier notes: {notes_block}\n\n"
            "Current artifact text:\n"
            "-----\n"
            f"{text.strip()}\n"
            "-----"
        )

