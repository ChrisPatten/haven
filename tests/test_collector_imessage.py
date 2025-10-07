import plistlib

from services.collector.collector_imessage import decode_attributed_body


def _make_archive(text: str) -> bytes:
    return plistlib.dumps(
        {
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": {"root": {"UID": 1}},
            "$objects": [
                "$null",
                {"NS.string": {"UID": 2}},
                text,
            ],
        },
        fmt=plistlib.FMT_BINARY,
    )


def test_decode_attributed_body_returns_string():
    archive = _make_archive("hello world")
    assert decode_attributed_body(archive) == "hello world"


def test_decode_attributed_body_handles_missing():
    assert decode_attributed_body(None) == ""
