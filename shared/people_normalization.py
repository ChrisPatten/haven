from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import re
from typing import Optional

import idna

try:  # pragma: no cover - optional dependency in tests
    import phonenumbers
except ImportError:  # pragma: no cover - fallback when phonenumbers absent
    phonenumbers = None  # type: ignore[assignment]


class IdentifierKind(str, Enum):
    PHONE = "phone"
    EMAIL = "email"
    IMESSAGE = "imessage"
    SHORTCODE = "shortcode"
    SOCIAL = "social"


@dataclass(slots=True)
class NormalizedIdentifier:
    kind: IdentifierKind
    value_raw: str
    value_canonical: str
    label: str | None = None
    priority: int = 100
    verified: bool = True


def normalize_phone(value: str, default_region: str | None = None) -> str:
    cleaned = value.strip()
    if phonenumbers is None:  # pragma: no cover - lightweight fallback when phonenumbers missing
        # Clean all characters except + and digits
        digits = re.sub(r"[^\+\d]", "", cleaned)
        if not digits:
            raise ValueError(f"Invalid phone number: {value}")
        # Remove any leading + signs to normalize
        digits = digits.lstrip("+")
        if not digits:
            raise ValueError(f"Invalid phone number: {value}")
        # Prepend + if not already present
        result = "+" + digits
        # If 11 characters long (including +), assume US number and add 1 after +
        if len(result) == 11 and not result.startswith("+1"):
            result = "+1" + digits
        return result

    parsed = phonenumbers.parse(cleaned, default_region or None)
    if not phonenumbers.is_valid_number(parsed):
        raise ValueError(f"Invalid phone number: {value}")
    return phonenumbers.format_number(parsed, phonenumbers.PhoneNumberFormat.E164)


def normalize_email(value: str) -> str:
    cleaned = value.strip()
    if "@" not in cleaned:
        raise ValueError(f"Invalid email address: {value}")
    local, domain = cleaned.split("@", 1)
    ascii_domain = idna.encode(domain.strip()).decode("ascii")
    return f"{local.strip().lower()}@{ascii_domain.lower()}"


def normalize_identifier(
    kind: IdentifierKind,
    value: str,
    *,
    default_region: str | None = None,
    label: str | None = None,
    priority: int = 100,
    verified: bool = True,
    value_raw: str | None = None,
) -> NormalizedIdentifier:
    raw_value = (value_raw if value_raw is not None else value).strip()
    candidate = value.strip()
    if kind == IdentifierKind.PHONE:
        canonical = normalize_phone(candidate, default_region=default_region)
    elif kind in {IdentifierKind.EMAIL, IdentifierKind.IMESSAGE}:
        canonical = normalize_email(candidate)
    else:
        canonical = candidate.lower()
    return NormalizedIdentifier(
        kind=kind,
        value_raw=raw_value,
        value_canonical=canonical,
        label=label,
        priority=priority,
        verified=verified,
    )


def normalize_imessage_handle(value: str, default_region: str | None = None) -> NormalizedIdentifier:
    candidate = value.strip()
    if "@" in candidate:
        return normalize_identifier(
            IdentifierKind.IMESSAGE,
            candidate,
            default_region=default_region,
            label=None,
            value_raw=value,
        )
    return normalize_identifier(
        IdentifierKind.IMESSAGE,
        normalize_phone(candidate, default_region=default_region),
        default_region=default_region,
        value_raw=value,
    )
