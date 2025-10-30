import pytest

from shared.people_normalization import (
    IdentifierKind,
    normalize_email,
    normalize_identifier,
    normalize_phone,
)

try:
    from phonenumbers.phonenumberutil import NumberParseException
except ImportError:
    NumberParseException = Exception


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


# Regression tests for phone number normalization fix
# These ensure that 10-digit US numbers without country code are properly converted to +1 prefix


def test_normalize_phone_10digit_bare_number():
    """10-digit number without formatting should become +1XXXXXXXXXX"""
    assert normalize_phone("5084109572", default_region="US") == "+15084109572"


def test_normalize_phone_10digit_with_formatting():
    """10-digit number with dashes should become +1XXXXXXXXXX"""
    assert normalize_phone("508-410-9572", default_region="US") == "+15084109572"


def test_normalize_phone_10digit_with_parentheses():
    """10-digit number with parentheses and dashes should become +1XXXXXXXXXX"""
    assert normalize_phone("(508) 410-9572", default_region="US") == "+15084109572"


def test_normalize_phone_11digit_with_country_code():
    """11-digit number starting with 1 should become +1XXXXXXXXXX"""
    assert normalize_phone("15084109572", default_region="US") == "+15084109572"


def test_normalize_phone_11digit_with_plus_and_country_code():
    """11-digit number with + prefix and 1 should stay +1XXXXXXXXXX"""
    assert normalize_phone("+15084109572", default_region="US") == "+15084109572"


def test_normalize_phone_10digit_various_separators():
    """10-digit number with various separators should be normalized correctly"""
    # Dots and spaces
    assert normalize_phone("508.410.9572", default_region="US") == "+15084109572"
    # Only spaces
    assert normalize_phone("508 410 9572", default_region="US") == "+15084109572"
    # Mixed separators
    assert normalize_phone("508-410.9572", default_region="US") == "+15084109572"


def test_normalize_phone_consistent_across_formats():
    """Different formats of the same number should normalize to the same result"""
    formats = [
        "5084109572",
        "508-410-9572",
        "(508) 410-9572",
        "508.410.9572",
        "508 410 9572",
        "+15084109572",
        "15084109572",
    ]
    expected = "+15084109572"
    for fmt in formats:
        assert normalize_phone(fmt, default_region="US") == expected, f"Failed for format: {fmt}"


def test_normalize_phone_invalid_empty_string():
    """Empty string should raise an error"""
    with pytest.raises((ValueError, NumberParseException)):
        normalize_phone("", default_region="US")


def test_normalize_phone_invalid_only_special_chars():
    """String with only special characters should raise an error"""
    with pytest.raises((ValueError, NumberParseException)):
        normalize_phone("()-.", default_region="US")


def test_normalize_phone_preserves_plus_sign():
    """Plus sign in the input should be preserved in output"""
    # Valid 11-digit US number with plus and 1
    result = normalize_phone("+15084109572", default_region="US")
    assert result.startswith("+")
    assert result == "+15084109572"


def test_normalize_phone_identifier_kind():
    """Phone identifiers should maintain correct kind and preserve raw value"""
    ident = normalize_identifier(IdentifierKind.PHONE, "5084109572", default_region="US")
    assert ident.kind == IdentifierKind.PHONE
    assert ident.value_canonical == "+15084109572"
    assert ident.value_raw == "5084109572"


def test_normalize_phone_contact_matching_scenario():
    """Test the specific scenario from the bug report: incomplete phone number in DB"""
    # Simulate a case where contacts are stored without country code
    stored_number = "5084109572"
    incoming_number = "+15084109572"
    
    # Both should normalize to the same canonical form
    assert normalize_phone(stored_number, default_region="US") == normalize_phone(incoming_number, default_region="US")
    assert normalize_phone(stored_number, default_region="US") == "+15084109572"
