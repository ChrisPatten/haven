from datetime import timezone

from scripts.collectors.collector_imessage import APPLE_EPOCH, apple_time_to_utc


def test_apple_time_to_utc_seconds():
    seconds = 60
    ts_iso = apple_time_to_utc(seconds)
    assert ts_iso is not None
    assert ts_iso.startswith("2001-01-01T00:01")


def test_apple_time_to_utc_microseconds():
    microseconds = 120 * 1_000_000
    ts_iso = apple_time_to_utc(microseconds)
    assert ts_iso is not None
    assert ts_iso.startswith("2001-01-01T00:02")


def test_apple_time_to_utc_none():
    assert apple_time_to_utc(None) is None
