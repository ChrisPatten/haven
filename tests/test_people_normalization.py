from shared.people_normalization import (
    IdentifierKind,
    normalize_email,
    normalize_identifier,
    normalize_phone,
)


def test_normalize_phone_to_e164():
    assert normalize_phone("(508) 555-1234", default_region="US") == "+15085551234"


def test_normalize_email_lower_and_idna():
    email = "Üser@bücher.example"
    canonical = normalize_email(email)
    assert canonical == "üser@xn--bcher-kva.example"


def test_normalize_identifier_preserves_raw():
    ident = normalize_identifier(IdentifierKind.PHONE, "508-555-0000", default_region="US")
    assert ident.value_canonical == "+15085550000"
    assert ident.value_raw == "508-555-0000"
