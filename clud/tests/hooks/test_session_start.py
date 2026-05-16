"""SessionStart hook contract tests.

Behavior: when Claude starts a session, write the session metadata to
sessions/<id>/meta.json AND record a tty-map.json entry so the plugin
can later resolve the focused iTerm pane's tty back to this session_id.

The hook must always exit 0 — even on garbage input — because Claude
must not break if the HUD is broken.
"""

from __future__ import annotations

import json
from pathlib import Path

from tests.conftest import run_hook


def test_writes_meta_and_tty_map(state_dir: Path) -> None:
    payload = {
        "session_id": "abc-123",
        "source": "startup",
        "transcript_path": "/tmp/transcript.jsonl",
        "cwd": "/Users/me/proj",
    }
    res = run_hook("hud-session-start.sh", payload, state_dir, ppid_tty="ttys003")

    assert res.returncode == 0, res.stderr

    meta = json.loads((state_dir / "sessions/abc-123/meta.json").read_text())
    assert meta["session_id"] == "abc-123"
    assert meta["project"] == "/Users/me/proj"
    assert meta["transcript_path"] == "/tmp/transcript.jsonl"
    assert meta["ended_at"] is None
    assert isinstance(meta["started_at"], int)

    tty_map = json.loads((state_dir / "tty-map.json").read_text())
    assert "/dev/ttys003" in tty_map
    assert tty_map["/dev/ttys003"]["session_id"] == "abc-123"


def test_corrupt_input_does_not_crash(state_dir: Path) -> None:
    res = run_hook("hud-session-start.sh", {}, state_dir, ppid_tty="ttys003")
    assert res.returncode == 0
    # No session_id → no meta.json should be written, and no tty-map entry either.
    assert not (state_dir / "sessions").exists()
    assert not (state_dir / "tty-map.json").exists()


def test_no_tty_skips_tty_map(state_dir: Path) -> None:
    """When the hook runs in a no-tty context (daemon, CI), it must still
    write meta.json but skip the tty-map entry — the map is for resolving
    iTerm panes back to sessions, and a sessionless context can't be focused."""
    payload = {
        "session_id": "abc-123",
        "source": "startup",
        "transcript_path": "/tmp/t.jsonl",
        "cwd": "/proj",
    }
    res = run_hook("hud-session-start.sh", payload, state_dir, ppid_tty="?")
    assert res.returncode == 0
    assert (state_dir / "sessions/abc-123/meta.json").exists()
    assert not (state_dir / "tty-map.json").exists()


def test_path_traversal_session_id_rejected(state_dir: Path) -> None:
    """A session_id containing path separators must NOT cause meta.json to
    be written outside sessions/ — the hook should log and bail."""
    payload = {
        "session_id": "../etc/passwd",
        "cwd": "/proj",
        "transcript_path": "",
    }
    res = run_hook("hud-session-start.sh", payload, state_dir, ppid_tty="ttys003")
    assert res.returncode == 0
    # Nothing under sessions/, no etc/passwd/, no tty-map entry.
    assert not (state_dir / "sessions").exists()
    assert not (state_dir / "etc").exists()
    assert not (state_dir / "tty-map.json").exists()
