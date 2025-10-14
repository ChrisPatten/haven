from __future__ import annotations

import argparse
import hashlib
import os
import platform
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Iterator
from uuid import uuid4

import backoff
import httpx
import orjson

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from shared.logging import get_logger, setup_logging  # noqa: E402
from shared.people_repository import PersonIngestRecord  # noqa: E402
from shared.people_normalization import normalize_identifier, IdentifierKind
from shared.people_repository import ContactValue


# Minimal helpers used by tests
class HelperContact:
    def __init__(self, payload: dict[str, Any]):
        self.payload = payload


def chunked(iterable: Sequence[Any], size: int) -> Iterator[List[Any]]:
    for i in range(0, len(iterable), size):
        yield list(iterable[i : i + size])


class ContactNormalizer:
    def __init__(self, default_region: str | None = None):
        self.default_region = default_region

    def normalize(self, raw: dict[str, Any], change_token: str | None = None) -> PersonIngestRecord:
        # Build a minimal PersonIngestRecord using normalization helpers
        display = raw.get("display_name")
        if not display:
            given = raw.get("given_name") or ""
            family = raw.get("family_name") or ""
            display = (given + " " + family).strip() or raw.get("external_id")

        phones = []
        for p in raw.get("phones", []) or []:
            value = p.get("value")
            label = p.get("label")
            try:
                ident = normalize_identifier(IdentifierKind.PHONE, value, default_region=self.default_region)
                phones.append(ContactValue(value=ident.value_canonical, value_raw=value, label=label))
            except Exception:
                phones.append(ContactValue(value=value or "", value_raw=value, label=label))

        emails = []
        for e in raw.get("emails", []) or []:
            value = e.get("value")
            label = e.get("label")
            try:
                ident = normalize_identifier(IdentifierKind.EMAIL, value)
                emails.append(ContactValue(value=ident.value_canonical, value_raw=value, label=label))
            except Exception:
                emails.append(ContactValue(value=value or "", value_raw=value, label=label))

        return PersonIngestRecord(
            external_id=str(raw.get("external_id") or ""),
            display_name=display or "",
            given_name=raw.get("given_name"),
            family_name=raw.get("family_name"),
            organization=raw.get("organization"),
            nicknames=tuple(raw.get("nicknames", [])),
            notes=raw.get("notes"),
            photo_hash=raw.get("photo_hash"),
            emails=tuple(emails),
            phones=tuple(phones),
            addresses=tuple(raw.get("addresses", [])),
            urls=tuple(raw.get("urls", [])),
            change_token=change_token,
            version=raw.get("version", 1),
            deleted=raw.get("deleted", False),
        )

logger = get_logger("collector.contacts")

# Try to import pyobjc Contacts bindings; provide a helpful error if unavailable.
CONTACTS_AVAILABLE = True
try:  # pragma: no cover - platform-specific
    from Contacts import (
        CNContactStore,
        CNContactFetchRequest,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactOrganizationNameKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactPostalAddressesKey,
        CNContactUrlAddressesKey,
        CNContactNicknameKey,
        CNContactImageDataKey,
        CNLabeledValue,
    )
except Exception:  # pragma: no cover - tested on macOS only
    CONTACTS_AVAILABLE = False
    logger.warning("pyobjc_contacts_unavailable", message="CNContact bindings not available; this collector requires macOS + pyobjc")

STATE_DIR = Path.home() / ".haven"
STATE_FILE = STATE_DIR / "contacts_collector_state.json"
DEFAULT_GATEWAY_URL = os.getenv("CONTACTS_GATEWAY_URL", "http://localhost:8085")
GATEWAY_ENDPOINT = os.getenv(
    "CONTACTS_GATEWAY_ENDPOINT",
    f"{DEFAULT_GATEWAY_URL}/catalog/contacts/ingest",
)
GATEWAY_TOKEN = os.getenv("CATALOG_TOKEN", "changeme")
BATCH_SIZE = int(os.getenv("CONTACTS_BATCH_SIZE", "500"))
SOURCE_NAME = "macos_contacts"
DEVICE_ID = os.getenv("CONTACTS_DEVICE_ID", platform.node() or "unknown-device")
HTTP_TIMEOUT = float(os.getenv("CONTACTS_HTTP_TIMEOUT", "30"))


def _safe_str(value: Any) -> Optional[str]:
    if value is None:
        return None
    s = str(value).strip()
    return s or None


def _label_for(labeled: Any) -> str:
    """Extract and localize a label from a CNLabeledValue."""
    try:
        label = labeled.label()
        try:
            localized = CNLabeledValue.localizedStringForLabel_(label)
            return _safe_str(localized) or "other"
        except Exception:
            return _safe_str(label) or "other"
    except Exception:
        return "other"


def fetch_contacts() -> List[Dict[str, Any]]:
    """Fetch all contacts from the macOS Contacts store and return as dicts."""
    if not CONTACTS_AVAILABLE:
        raise RuntimeError("pyobjc Contacts bindings not available on this system")

    store = CNContactStore.alloc().init()
    keys = [
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactOrganizationNameKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactPostalAddressesKey,
        CNContactUrlAddressesKey,
        CNContactNicknameKey,
        CNContactImageDataKey,
    ]
    request = CNContactFetchRequest.alloc().initWithKeysToFetch_(keys)

    fetched: List[Any] = []

    def _append(contact, stop_ptr):
        fetched.append(contact)

    try:
        store.enumerateContactsWithFetchRequest_error_usingBlock_(request, None, _append)
    except Exception as exc:
        raise RuntimeError(f"Failed to enumerate contacts: {exc}")

    contacts: List[Dict[str, Any]] = []
    for contact in fetched:
        try:
            payload = _contact_to_dict(contact)
            contacts.append(payload)
        except Exception as exc:
            logger.warning("contact_conversion_failed", error=str(exc))
            continue

    return contacts


def _contact_to_dict(contact: Any) -> Dict[str, Any]:
    """Map a CNContact to a dict with fields expected by PersonIngestRecord."""
    given = _safe_str(contact.givenName()) if hasattr(contact, "givenName") else None
    family = _safe_str(contact.familyName()) if hasattr(contact, "familyName") else None
    org = _safe_str(contact.organizationName()) if hasattr(contact, "organizationName") else None

    display = None
    if given or family:
        display = " ".join(p for p in (given or "", family or "") if p).strip()
    if not display:
        display = org or _safe_str(contact.identifier())

    # Phones
    phones: List[Dict[str, Any]] = []
    try:
        for labeled in contact.phoneNumbers() or []:
            label = _label_for(labeled)
            value_obj = labeled.value()
            try:
                number = value_obj.stringValue()
            except Exception:
                number = str(value_obj)
            if not number:
                continue
            phones.append({"value": number, "label": label})
    except Exception:
        phones = []

    # Emails
    emails: List[Dict[str, Any]] = []
    try:
        for labeled in contact.emailAddresses() or []:
            label = _label_for(labeled)
            value = labeled.value()
            if not value:
                continue
            emails.append({"value": _safe_str(value), "label": label})
    except Exception:
        emails = []

    # URLs
    urls: List[Dict[str, Any]] = []
    try:
        for labeled in contact.urlAddresses() or []:
            label = _label_for(labeled)
            value = labeled.value()
            if not value:
                continue
            urls.append({"value": _safe_str(value), "label": label})
    except Exception:
        urls = []

    # Addresses
    addresses: List[Dict[str, Any]] = []
    try:
        for labeled in contact.postalAddresses() or []:
            label = _label_for(labeled)
            addr = labeled.value()
            try:
                street = _safe_str(addr.street())
                city = _safe_str(addr.city())
                region = _safe_str(addr.state())
                postal = _safe_str(addr.postalCode())
                country = _safe_str(addr.country())
            except Exception:
                street = city = region = postal = country = None
            addresses.append(
                {
                    "label": label,
                    "street": street,
                    "city": city,
                    "region": region,
                    "postal_code": postal,
                    "country": country,
                }
            )
    except Exception:
        addresses = []

    # Nickname
    nicknames: List[str] = []
    try:
        nick = _safe_str(contact.nickname()) if hasattr(contact, "nickname") else None
        if nick:
            nicknames.append(nick)
    except Exception:
        pass

    # Photo hash
    photo_hash = None
    try:
        if hasattr(contact, "imageData") and contact.imageData() is not None:
            raw = bytes(contact.imageData())
            photo_hash = hashlib.sha256(raw).hexdigest()
    except Exception:
        photo_hash = None

    return {
        "external_id": _safe_str(contact.identifier()) if hasattr(contact, "identifier") else None,
        "display_name": display,
        "given_name": given,
        "family_name": family,
        "organization": org,
        "nicknames": nicknames,
        "notes": None,
        "photo_hash": photo_hash,
        "emails": emails,
        "phones": phones,
        "addresses": addresses,
        "urls": urls,
        "version": 1,
        "deleted": False,
    }


class BatchPoster:
    def __init__(self, endpoint: str, token: str | None = None) -> None:
        self.endpoint = endpoint
        self.token = token
        self.client = httpx.Client(timeout=HTTP_TIMEOUT)

    def close(self) -> None:
        self.client.close()

    def _headers(self) -> Dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    @backoff.on_exception(backoff.expo, httpx.HTTPError, max_tries=5)
    def post(self, payload: dict[str, object]) -> dict[str, object]:
        response = self.client.post(
            self.endpoint,
            content=orjson.dumps(payload),
            headers=self._headers(),
        )
        response.raise_for_status()
        if not response.content:
            return {}
        try:
            return response.json()
        except ValueError:  # pragma: no cover - defensive
            logger.warning("contacts_gateway_bad_json", body=response.text[:256])
            return {}


def sync_contacts() -> None:
    """Fetch contacts from macOS and POST them to the gateway ingest endpoint."""
    setup_logging()
    logger.info("contacts_sync_start", source=SOURCE_NAME, device_id=DEVICE_ID)

    try:
        contacts = fetch_contacts()
    except RuntimeError as exc:
        logger.error("contacts_fetch_failed", error=str(exc))
        raise

    if not contacts:
        logger.info("contacts_sync_complete", count=0)
        return

    # Convert contacts to PersonIngestRecord shape for the gateway
    people = []
    for contact in contacts:
        try:
            person = PersonIngestRecord(
                external_id=contact["external_id"],
                display_name=contact["display_name"],
                given_name=contact.get("given_name"),
                family_name=contact.get("family_name"),
                organization=contact.get("organization"),
                nicknames=tuple(contact.get("nicknames", [])),
                notes=contact.get("notes"),
                photo_hash=contact.get("photo_hash"),
                emails=tuple(contact.get("emails", [])),
                phones=tuple(contact.get("phones", [])),
                addresses=tuple(contact.get("addresses", [])),
                urls=tuple(contact.get("urls", [])),
                change_token=None,
                version=contact.get("version", 1),
                deleted=contact.get("deleted", False),
            )
            people.append(person)
        except Exception as exc:
            logger.warning("contact_normalization_failed", error=str(exc), contact=contact)
            continue

    # Post in batches
    poster = BatchPoster(GATEWAY_ENDPOINT, GATEWAY_TOKEN)
    try:
        for i in range(0, len(people), BATCH_SIZE):
            batch = people[i : i + BATCH_SIZE]
            payload = {
                "source": SOURCE_NAME,
                "device_id": DEVICE_ID,
                "since_token": None,
                "batch_id": str(uuid4()),
                "people": [asdict(person) for person in batch],
            }
            logger.info("contacts_batch_post", count=len(batch), endpoint=GATEWAY_ENDPOINT)
            response = poster.post(payload)
            logger.debug("contacts_batch_response", response=response)
    finally:
        poster.close()

    logger.info("contacts_sync_complete", count=len(people))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Haven macOS Contacts Collector")
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run a single sync and exit (default behavior)",
    )
    return parser.parse_args()


def main() -> None:
    parse_args()  # parse for help/validation but we always run once by default
    sync_contacts()


if __name__ == "__main__":
    main()
