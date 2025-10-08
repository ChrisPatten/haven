from services.collector.collector_contacts import (
    ContactNormalizer,
    HelperContact,
    chunked,
)


def test_contact_normalizer_canonicalizes_values():
    normalizer = ContactNormalizer(default_region="US")
    raw_contact = {
        "external_id": "CN_123",
        "given_name": "Alice",
        "family_name": "Smith",
        "phones": [{"value": "(508) 555-1234", "label": "Mobile"}],
        "emails": [{"value": "Alice@Example.com", "label": "Work"}],
        "nicknames": ["Al"],
    }
    record = normalizer.normalize(raw_contact, change_token="token-1")
    assert record.change_token == "token-1"
    assert record.display_name == "Alice Smith"
    assert record.phones[0].value == "+15085551234"
    assert record.phones[0].value_raw == "(508) 555-1234"
    assert record.phones[0].label == "Mobile"
    assert record.emails[0].value == "alice@example.com"
    assert record.emails[0].value_raw == "Alice@Example.com"


def test_chunked_breaks_iterable():
    contacts = [HelperContact(payload={"external_id": str(i)}) for i in range(5)]
    batches = list(chunked(contacts, 2))
    assert [len(batch) for batch in batches] == [2, 2, 1]
