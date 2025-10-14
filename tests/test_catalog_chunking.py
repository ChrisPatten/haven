from services.catalog_api.app import _chunk_text


def test_chunk_text_splits_long_input() -> None:
    text = "Lorem ipsum " * 200  # plenty of content
    chunks = _chunk_text(text, max_chars=120, overlap=40)
    assert len(chunks) > 1
    for chunk in chunks:
        assert chunk.text
        assert len(chunk.text) <= 120


def test_chunk_text_handles_small_input() -> None:
    text = "hello world"
    chunks = _chunk_text(text)
    assert len(chunks) == 1
    assert chunks[0].text == text
