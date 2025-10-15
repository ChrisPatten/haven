from __future__ import annotations

import json
from pathlib import Path

from scripts.collectors.collector_localfs import (
    CollectorConfig,
    CollectorState,
    LocalFsCollector,
)


class FakeResponse:
    status_code = 202

    def json(self) -> dict[str, str]:
        return {
            "submission_id": "sub-1",
            "doc_id": "doc-1",
            "status": "embedding_pending",
            "duplicate": False,
            "total_chunks": 2,
        }

    @property
    def text(self) -> str:  # pragma: no cover - used for logging on failure
        return "ok"


class FakeSession:
    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

    def post(self, url, files, data, headers, timeout):  # type: ignore[override]
        payload = {
            "url": url,
            "headers": headers,
            "data": data,
            "content": files["upload"][1].getvalue(),  # type: ignore[index]
            "filename": files["upload"][0],  # type: ignore[index]
            "content_type": files["upload"][2],  # type: ignore[index]
            "timeout": timeout,
        }
        self.calls.append(payload)
        return FakeResponse()


def build_config(tmp_path: Path, watch_dir: Path, **overrides) -> CollectorConfig:
    defaults = {
        "watch_dir": watch_dir,
        "include": ["*.txt"],
        "exclude": [],
        "poll_interval": 1.0,
        "move_to": None,
        "delete_after": False,
        "max_file_bytes": 1024 * 1024,
        "gateway_url": "http://gateway.test",
        "auth_token": "secret",
        "tags": ["docs"],
        "dry_run": False,
        "one_shot": True,
        "state_file": tmp_path / "state.json",
        "request_timeout": 5.0,
    }
    defaults.update(overrides)
    return CollectorConfig(**defaults)


def test_localfs_collector_processes_file(monkeypatch, tmp_path: Path) -> None:
    watch_dir = tmp_path / "watch"
    watch_dir.mkdir()
    processed_dir = tmp_path / "processed"
    processed_dir.mkdir()
    file_path = watch_dir / "sample.txt"
    file_path.write_text("Hello localfs", encoding="utf-8")

    session = FakeSession()
    config = build_config(
        tmp_path,
        watch_dir,
        move_to=processed_dir,
    )
    state = CollectorState.load(config.state_file)
    collector = LocalFsCollector(config=config, state=state, session=session)

    processed = collector.process_once()

    assert processed == 1
    assert len(session.calls) == 1
    call = session.calls[0]
    assert call["url"] == "http://gateway.test/v1/ingest/file"
    assert call["headers"]["Authorization"] == "Bearer secret"
    assert call["filename"] == "sample.txt"
    assert call["content"] == b"Hello localfs"
    meta = json.loads(call["data"]["meta"])  # type: ignore[index]
    assert meta["filename"] == "sample.txt"
    assert meta["tags"] == ["docs"]
    assert meta["path"].endswith("sample.txt")
    assert not file_path.exists()
    moved_path = processed_dir / "sample.txt"
    assert moved_path.exists()
    state_payload = json.loads(config.state_file.read_text())
    assert len(state_payload["by_hash"]) == 1


def test_localfs_collector_skips_known_hash(tmp_path: Path) -> None:
    watch_dir = tmp_path / "watch"
    watch_dir.mkdir()
    file_path = watch_dir / "sample.txt"
    file_path.write_text("Hello localfs", encoding="utf-8")

    session = FakeSession()
    config = build_config(tmp_path, watch_dir)
    state = CollectorState.load(config.state_file)
    collector = LocalFsCollector(config=config, state=state, session=session)

    first = collector.process_once()
    assert first == 1
    # Drop a second file with the same contents; should be skipped
    file_path = watch_dir / "another.txt"
    file_path.write_text("Hello localfs", encoding="utf-8")

    second = collector.process_once()
    assert second == 0
    # Only the first upload should have been attempted
    assert len(session.calls) == 1


def test_localfs_collector_dry_run(tmp_path: Path) -> None:
    watch_dir = tmp_path / "watch"
    watch_dir.mkdir()
    file_path = watch_dir / "sample.txt"
    file_path.write_text("Dry run contents", encoding="utf-8")

    session = FakeSession()
    config = build_config(tmp_path, watch_dir, dry_run=True)
    state = CollectorState.load(config.state_file)
    collector = LocalFsCollector(config=config, state=state, session=session)

    processed = collector.process_once()

    assert processed == 1
    assert not session.calls  # no HTTP calls in dry-run mode
    assert file_path.exists()
    state_payload = json.loads(config.state_file.read_text())
    assert len(state_payload["by_hash"]) == 1
