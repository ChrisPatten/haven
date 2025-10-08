"""Tests for message text validation in context API."""

from shared.context import is_message_text_valid


def test_is_message_text_valid_accepts_normal_text():
    """Valid messages with normal text should pass."""
    assert is_message_text_valid("Hello world")
    assert is_message_text_valid("Testing 123")
    assert is_message_text_valid("Hey! How are you?")
    assert is_message_text_valid("👍")  # emoji should be fine
    assert is_message_text_valid("   Normal text with spaces   ")


def test_is_message_text_valid_rejects_empty_and_whitespace():
    """Empty, None, and whitespace-only messages should be rejected."""
    assert not is_message_text_valid(None)
    assert not is_message_text_valid("")
    assert not is_message_text_valid("   ")
    assert not is_message_text_valid("\t\n  ")


def test_is_message_text_valid_rejects_object_replacement_char():
    """Object replacement character (U+FFFC) should be rejected."""
    assert not is_message_text_valid("\ufffc")
    assert not is_message_text_valid("  \ufffc  ")
    assert not is_message_text_valid("\ufffc\ufffc\ufffc")


def test_is_message_text_valid_rejects_replacement_char():
    """Replacement character (U+FFFD) should be rejected."""
    assert not is_message_text_valid("\ufffd")
    assert not is_message_text_valid("  \ufffd  ")
    assert not is_message_text_valid("\ufffd\ufffd")


def test_is_message_text_valid_rejects_zero_width_chars():
    """Zero-width characters should be rejected when alone."""
    assert not is_message_text_valid("\u200b")  # zero-width space
    assert not is_message_text_valid("\u200c")  # zero-width non-joiner
    assert not is_message_text_valid("\u200d")  # zero-width joiner
    assert not is_message_text_valid("\ufeff")  # zero-width no-break space (BOM)


def test_is_message_text_valid_rejects_mixed_problematic():
    """Messages with only whitespace and problematic characters should be rejected."""
    assert not is_message_text_valid("  \ufffc \ufffd  ")
    assert not is_message_text_valid("\ufffc\u200b\ufffd")
    assert not is_message_text_valid("\t\ufffc\n\ufffd  ")


def test_is_message_text_valid_accepts_text_with_problematic_chars():
    """Text with actual content plus problematic chars should be accepted."""
    assert is_message_text_valid("Hello\ufffc")  # text before replacement char
    assert is_message_text_valid("\ufffcHello")  # text after replacement char
    assert is_message_text_valid("Hello \ufffd world")  # text around replacement char


def test_is_message_text_valid_rejects_only_special_symbols():
    """Messages with only special/invisible characters should be rejected."""
    # These are edge cases - strings that look empty but have invisible chars
    assert not is_message_text_valid("\u200b\u200c\u200d")
    assert not is_message_text_valid("\ufeff\ufeff")
