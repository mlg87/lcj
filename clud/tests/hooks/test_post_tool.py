"""PostToolUse hook contract tests.

Behavior:
  Always: clear current.json (the matching PreToolUse just set it).
  When tool_name == "TodoWrite": also persist the latest todos array to
    sessions/<id>/todos.json. WHY only TodoWrite: that's the canonical
    write event for Claude's todo state; everything else leaves todos alone.
"""
from __future__ import annotations

import json
from pathlib import Path

from tests.conftest import run_hook


def _seed_session(state_dir: Path, session_id: str = "abc-123") -> Path:
    d = state_dir / "sessions" / session_id
    d.mkdir(parents=True)
    return d


def test_clears_current_after_any_tool(state_dir: Path) -> None:
    sd = _seed_session(state_dir)
    (sd / "current.json").write_text('{"tool_name":"Bash","input_summary":"x","started_at":1}')
    payload = {
        "session_id": "abc-123",
        "tool_name": "Bash",
        "tool_input": {"command": "true"},
        "tool_response": {"output": ""},
    }
    res = run_hook("hud-post-tool.sh", payload, state_dir)
    assert res.returncode == 0, res.stderr
    assert not (sd / "current.json").exists()


def test_todowrite_writes_todos(state_dir: Path) -> None:
    _seed_session(state_dir)
    todos = [
        {"content": "A", "status": "completed",   "activeForm": "Doing A"},
        {"content": "B", "status": "in_progress", "activeForm": "Doing B"},
        {"content": "C", "status": "pending",     "activeForm": "Doing C"},
    ]
    payload = {
        "session_id": "abc-123",
        "tool_name": "TodoWrite",
        "tool_input": {"todos": todos},
        "tool_response": {},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    saved = json.loads((state_dir / "sessions/abc-123/todos.json").read_text())
    assert saved["todos"] == todos
    assert isinstance(saved["updated_at"], int)


def test_non_todowrite_does_not_touch_todos(state_dir: Path) -> None:
    sd = _seed_session(state_dir)
    (sd / "todos.json").write_text(
        '{"updated_at":1,"todos":[{"content":"X","status":"pending","activeForm":""}]}')
    payload = {
        "session_id": "abc-123",
        "tool_name": "Bash",
        "tool_input": {"command": "true"},
        "tool_response": {},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    saved = json.loads((sd / "todos.json").read_text())
    assert saved["todos"][0]["content"] == "X"


def test_path_traversal_session_id_rejected(state_dir: Path) -> None:
    """Defense-in-depth same as SessionStart/PreToolUse."""
    payload = {
        "session_id": "../etc/passwd",
        "tool_name": "Bash",
        "tool_input": {"command": "true"},
        "tool_response": {},
    }
    res = run_hook("hud-post-tool.sh", payload, state_dir)
    assert res.returncode == 0
    assert not (state_dir / "sessions").exists()
    assert not (state_dir / "etc").exists()
