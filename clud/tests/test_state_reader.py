"""StateReader: assemble a full snapshot from the on-disk state files.

The reader is the only piece that knows the on-disk layout. Everything
upstream consumes the dict it returns. Behavior under partial / missing /
corrupt files is part of the contract — the HUD must show *something*
even if half the state files don't exist yet.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from plugin.state_reader import StateReader


@pytest.fixture
def reader(tmp_path: Path) -> StateReader:
    (tmp_path / "sessions").mkdir()
    return StateReader(tmp_path)


def _write(p: Path, data: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data))


def test_returns_none_when_tty_unknown(reader: StateReader) -> None:
    assert reader.snapshot_for_tty("/dev/ttys999") is None


def test_returns_none_when_tty_is_none(reader: StateReader) -> None:
    assert reader.snapshot_for_tty(None) is None


def test_full_snapshot(reader: StateReader, tmp_path: Path) -> None:
    _write(
        tmp_path / "tty-map.json",
        {
            "/dev/ttys003": {"session_id": "abc", "claude_pid": 1, "started_at": 1000},
        },
    )
    _write(
        tmp_path / "sessions/abc/meta.json",
        {
            "session_id": "abc",
            "model": "claude-opus-4-7",
            "project": "/p",
            "transcript_path": "",
            "started_at": 1000,
            "last_updated": 1000,
            "ended_at": None,
        },
    )
    _write(
        tmp_path / "sessions/abc/todos.json",
        {
            "updated_at": 1100,
            "todos": [
                {"content": "A", "status": "completed", "activeForm": ""},
                {"content": "B", "status": "in_progress", "activeForm": ""},
            ],
        },
    )
    _write(
        tmp_path / "sessions/abc/current.json",
        {"tool_name": "Bash", "input_summary": "git status", "started_at": 1200},
    )

    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["tty"] == "/dev/ttys003"
    assert snap["session"] == {"id": "abc", "model": "claude-opus-4-7", "project": "/p"}
    assert snap["current"]["tool_name"] == "Bash"
    assert snap["current"]["input_summary"] == "git status"
    assert "running_for_ms" in snap["current"]
    assert len(snap["todos"]) == 2


def test_missing_optional_files(reader: StateReader, tmp_path: Path) -> None:
    _write(
        tmp_path / "tty-map.json",
        {
            "/dev/ttys003": {"session_id": "abc", "claude_pid": 1, "started_at": 1000},
        },
    )
    _write(
        tmp_path / "sessions/abc/meta.json",
        {
            "session_id": "abc",
            "model": None,
            "project": "/p",
            "transcript_path": "",
            "started_at": 1000,
            "last_updated": 1000,
            "ended_at": None,
        },
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["current"] is None
    assert snap["todos"] == []


def test_corrupt_json_does_not_raise(reader: StateReader, tmp_path: Path) -> None:
    (tmp_path / "tty-map.json").write_text("{not json")
    assert reader.snapshot_for_tty("/dev/ttys003") is None
