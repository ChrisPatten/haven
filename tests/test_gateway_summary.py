from datetime import datetime, timezone

from services.gateway_api.app import MessageDoc, build_summary_text


def test_build_summary_text_uses_top_three():
    docs = [
        MessageDoc(doc_id=str(i), thread_id="t", ts=datetime(2024, 1, i + 1, tzinfo=timezone.utc), sender=f"sender-{i}", text=f"message {i}")
        for i in range(5)
    ]
    summary = build_summary_text("test", docs)
    assert "sender-0" in summary and "sender-3" not in summary
    assert "Summary for query 'test':" in summary


def test_build_summary_text_handles_empty():
    assert build_summary_text("empty", []) == "No relevant messages found."

