"""SessionEnd hook contract tests.

Behavior: when Claude ends, remove this session_id from tty-map.json
and stamp meta.ended_at. Other sessions in the map are untouched.

The plugin also runs a startup GC (see tty_resolver) for crashed sessions
that never fired SessionEnd, so this hook is the happy-path cleanup.
"""
from __future__ import annotations

import json
from pathlib import Path

from tests.conftest import run_hook


def test_removes_tty_map_entry_and_sets_ended_at(state_dir: Path) -> None:
    (state_dir / "sessions/abc-123").mkdir(parents=True)
    (state_dir / "tty-map.json").write_text(json.dumps({
        "/dev/ttys003": {"session_id": "abc-123", "claude_pid": 1, "started_at": 1},
        "/dev/ttys004": {"session_id": "def-456", "claude_pid": 2, "started_at": 2},
    }))
    (state_dir / "sessions/abc-123/meta.json").write_text(json.dumps({
        "session_id": "abc-123", "model": None, "project": "/p",
        "transcript_path": "", "started_at": 1, "last_updated": 1, "ended_at": None,
    }))

    res = run_hook("hud-session-end.sh", {"session_id": "abc-123", "reason": "exit"},
                   state_dir, ppid_tty="ttys003")
    assert res.returncode == 0, res.stderr

    tty_map = json.loads((state_dir / "tty-map.json").read_text())
    assert "/dev/ttys003" not in tty_map
    assert "/dev/ttys004" in tty_map  # other session untouched

    meta = json.loads((state_dir / "sessions/abc-123/meta.json").read_text())
    assert isinstance(meta["ended_at"], int)


def test_missing_meta_is_not_fatal(state_dir: Path) -> None:
    res = run_hook("hud-session-end.sh", {"session_id": "ghost"}, state_dir)
    assert res.returncode == 0


def test_path_traversal_session_id_rejected(state_dir: Path) -> None:
    """Defense-in-depth same as other hooks."""
    (state_dir / "tty-map.json").write_text(json.dumps({
        "/dev/ttys003": {"session_id": "real", "claude_pid": 1, "started_at": 1},
    }))
    res = run_hook("hud-session-end.sh", {"session_id": "../etc/passwd"}, state_dir)
    assert res.returncode == 0
    # tty-map is preserved (no entries removed)
    tty_map = json.loads((state_dir / "tty-map.json").read_text())
    assert "real" == tty_map["/dev/ttys003"]["session_id"]
