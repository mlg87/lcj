"""PreToolUse hook contract tests.

Behavior: every tool invocation gets a 'currently running' marker written
to sessions/<id>/current.json. The plugin uses this to render a live
"▶ Bash · 2.3s" indicator. The matching PostToolUse hook clears it.

input_summary is computed in the hook (not the plugin) to keep the
plugin tool-agnostic — adding support for a new tool means only editing
the hook's case statement.
"""

from __future__ import annotations

import json
from pathlib import Path

from tests.conftest import run_hook


def _seed_session(state_dir: Path, session_id: str = "abc-123") -> None:
    (state_dir / "sessions" / session_id).mkdir(parents=True)


def test_writes_current_for_bash(state_dir: Path) -> None:
    _seed_session(state_dir)
    payload = {
        "session_id": "abc-123",
        "tool_name": "Bash",
        "tool_input": {"command": "git rev-parse HEAD"},
    }
    res = run_hook("hud-pre-tool.sh", payload, state_dir)
    assert res.returncode == 0, res.stderr

    current = json.loads((state_dir / "sessions/abc-123/current.json").read_text())
    assert current["tool_name"] == "Bash"
    assert current["input_summary"] == "git rev-parse HEAD"
    assert isinstance(current["started_at"], int)


def test_writes_current_for_read(state_dir: Path) -> None:
    _seed_session(state_dir)
    payload = {
        "session_id": "abc-123",
        "tool_name": "Read",
        "tool_input": {"file_path": "/etc/hosts"},
    }
    run_hook("hud-pre-tool.sh", payload, state_dir)
    current = json.loads((state_dir / "sessions/abc-123/current.json").read_text())
    assert current["tool_name"] == "Read"
    assert current["input_summary"] == "/etc/hosts"


def test_truncates_long_bash_command(state_dir: Path) -> None:
    _seed_session(state_dir)
    long_cmd = "echo " + ("x" * 200)
    payload = {
        "session_id": "abc-123",
        "tool_name": "Bash",
        "tool_input": {"command": long_cmd},
    }
    run_hook("hud-pre-tool.sh", payload, state_dir)
    current = json.loads((state_dir / "sessions/abc-123/current.json").read_text())
    assert len(current["input_summary"]) <= 80


def test_unknown_tool_uses_empty_summary(state_dir: Path) -> None:
    _seed_session(state_dir)
    payload = {
        "session_id": "abc-123",
        "tool_name": "WeirdTool",
        "tool_input": {"foo": "bar"},
    }
    run_hook("hud-pre-tool.sh", payload, state_dir)
    current = json.loads((state_dir / "sessions/abc-123/current.json").read_text())
    assert current["tool_name"] == "WeirdTool"
    assert current["input_summary"] == ""


def test_path_traversal_session_id_rejected(state_dir: Path) -> None:
    """Defense in depth: same path-traversal guard as SessionStart."""
    payload = {
        "session_id": "../etc/passwd",
        "tool_name": "Bash",
        "tool_input": {"command": "id"},
    }
    res = run_hook("hud-pre-tool.sh", payload, state_dir)
    assert res.returncode == 0
    assert not (state_dir / "sessions").exists()
    assert not (state_dir / "etc").exists()
