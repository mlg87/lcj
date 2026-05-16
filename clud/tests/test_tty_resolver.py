# clud/tests/test_tty_resolver.py
"""TtyResolver: tty normalization and stale-session garbage collection.

The two concerns intentionally live in one module because they're both
about reconciling the writer's view of "which sessions exist" (tty-map)
with the reader's view (iTerm focus + process liveness).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from plugin.tty_resolver import TtyResolver


def _write_map(d: Path, entries: dict[str, dict]) -> None:
    (d / "tty-map.json").write_text(json.dumps(entries))


def _read_map(d: Path) -> dict:
    return json.loads((d / "tty-map.json").read_text())


@pytest.fixture
def resolver(tmp_path: Path) -> TtyResolver:
    (tmp_path / "sessions").mkdir()
    return TtyResolver(tmp_path)


def test_normalize_full_path_passthrough(resolver: TtyResolver) -> None:
    assert resolver.normalize("/dev/ttys003") == "/dev/ttys003"


def test_normalize_short_form(resolver: TtyResolver) -> None:
    assert resolver.normalize("ttys003") == "/dev/ttys003"
    assert resolver.normalize("s003") == "/dev/ttys003"


def test_normalize_empty(resolver: TtyResolver) -> None:
    assert resolver.normalize(None) is None
    assert resolver.normalize("") is None
    assert resolver.normalize("?") is None


def test_gc_drops_dead_pids(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _write_map(
        tmp_path,
        {
            "/dev/ttys003": {"session_id": "alive", "claude_pid": 100, "started_at": 1},
            "/dev/ttys004": {"session_id": "dead", "claude_pid": 200, "started_at": 1},
        },
    )

    def fake_kill(pid: int, sig: int) -> None:
        if pid == 200:
            raise ProcessLookupError()

    monkeypatch.setattr("plugin.tty_resolver.os.kill", fake_kill)

    resolver = TtyResolver(tmp_path)
    resolver.gc_dead_sessions()

    m = _read_map(tmp_path)
    assert "/dev/ttys003" in m
    assert "/dev/ttys004" not in m


def test_gc_handles_missing_map(resolver: TtyResolver) -> None:
    resolver.gc_dead_sessions()  # no-op, no raise


def test_gc_handles_corrupt_map(tmp_path: Path) -> None:
    (tmp_path / "tty-map.json").write_text("{not json")
    resolver = TtyResolver(tmp_path)
    resolver.gc_dead_sessions()
