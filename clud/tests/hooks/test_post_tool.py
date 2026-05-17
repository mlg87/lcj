"""PostToolUse hook contract tests.

Behavior:
  Always: clear current.json (the matching PreToolUse just set it).

  Persisted by tool name:
    TodoWrite  → overwrite sessions/<id>/todos.json with the full array
                 (legacy snapshot semantics).
    TaskCreate → append the new task to todos.json with the id Claude
                 returned in tool_response.task.id.
    TaskUpdate → mutate the matching task in place; status="deleted" removes
                 the row entirely.
    Agent      → for foreground agents, delete the subagents/<tool_use_id>.json
                 marker that PreToolUse wrote. Background agents (run_in_background)
                 keep the marker so the HUD still shows them.
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
        {"content": "A", "status": "completed", "activeForm": "Doing A"},
        {"content": "B", "status": "in_progress", "activeForm": "Doing B"},
        {"content": "C", "status": "pending", "activeForm": "Doing C"},
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
        '{"updated_at":1,"todos":[{"content":"X","status":"pending","activeForm":""}]}'
    )
    payload = {
        "session_id": "abc-123",
        "tool_name": "Bash",
        "tool_input": {"command": "true"},
        "tool_response": {},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    saved = json.loads((sd / "todos.json").read_text())
    assert saved["todos"][0]["content"] == "X"


def test_taskcreate_appends_to_empty_todos(state_dir: Path) -> None:
    """First TaskCreate seeds an empty todos.json with one pending row."""
    _seed_session(state_dir)
    payload = {
        "session_id": "abc-123",
        "tool_name": "TaskCreate",
        "tool_input": {
            "subject": "Wire the auth flow",
            "description": "Replace JWT with session cookies",
            "activeForm": "Wiring the auth flow",
        },
        "tool_response": {"task": {"id": "1", "subject": "Wire the auth flow"}},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    saved = json.loads((state_dir / "sessions/abc-123/todos.json").read_text())
    assert saved["todos"] == [
        {
            "id": "1",
            "content": "Wire the auth flow",
            "status": "pending",
            "activeForm": "Wiring the auth flow",
            "description": "Replace JWT with session cookies",
        }
    ]


def test_taskcreate_appends_to_existing_todos(state_dir: Path) -> None:
    sd = _seed_session(state_dir)
    (sd / "todos.json").write_text(
        json.dumps(
            {
                "updated_at": 1,
                "todos": [{"id": "1", "content": "A", "status": "completed", "activeForm": ""}],
            }
        )
    )
    payload = {
        "session_id": "abc-123",
        "tool_name": "TaskCreate",
        "tool_input": {"subject": "B"},
        "tool_response": {"task": {"id": "2", "subject": "B"}},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    saved = json.loads((sd / "todos.json").read_text())
    assert [t["id"] for t in saved["todos"]] == ["1", "2"]
    assert saved["todos"][1]["content"] == "B"
    assert saved["todos"][1]["status"] == "pending"


def test_taskcreate_without_id_is_skipped(state_dir: Path) -> None:
    """No id ⇒ no way to track across TaskUpdate; skip silently rather
    than write an unmergeable row."""
    sd = _seed_session(state_dir)
    payload = {
        "session_id": "abc-123",
        "tool_name": "TaskCreate",
        "tool_input": {"subject": "X"},
        "tool_response": {},
    }
    res = run_hook("hud-post-tool.sh", payload, state_dir)
    assert res.returncode == 0
    assert not (sd / "todos.json").exists()


def test_taskupdate_status_in_place(state_dir: Path) -> None:
    sd = _seed_session(state_dir)
    (sd / "todos.json").write_text(
        json.dumps(
            {
                "updated_at": 1,
                "todos": [
                    {"id": "1", "content": "A", "status": "pending", "activeForm": "Doing A"},
                    {"id": "2", "content": "B", "status": "pending", "activeForm": ""},
                ],
            }
        )
    )
    payload = {
        "session_id": "abc-123",
        "tool_name": "TaskUpdate",
        "tool_input": {"taskId": "1", "status": "in_progress"},
        "tool_response": {},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    saved = json.loads((sd / "todos.json").read_text())
    statuses = {t["id"]: t["status"] for t in saved["todos"]}
    assert statuses == {"1": "in_progress", "2": "pending"}


def test_taskupdate_deleted_removes_row(state_dir: Path) -> None:
    sd = _seed_session(state_dir)
    (sd / "todos.json").write_text(
        json.dumps(
            {
                "updated_at": 1,
                "todos": [
                    {"id": "1", "content": "A", "status": "pending", "activeForm": ""},
                    {"id": "2", "content": "B", "status": "pending", "activeForm": ""},
                ],
            }
        )
    )
    payload = {
        "session_id": "abc-123",
        "tool_name": "TaskUpdate",
        "tool_input": {"taskId": "1", "status": "deleted"},
        "tool_response": {},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    saved = json.loads((sd / "todos.json").read_text())
    assert [t["id"] for t in saved["todos"]] == ["2"]


def test_taskupdate_unknown_id_appends(state_dir: Path) -> None:
    """If we missed the originating TaskCreate (e.g. HUD started mid-session),
    a TaskUpdate still surfaces in the HUD instead of being silently dropped."""
    sd = _seed_session(state_dir)
    payload = {
        "session_id": "abc-123",
        "tool_name": "TaskUpdate",
        "tool_input": {"taskId": "99", "status": "in_progress", "subject": "ghost"},
        "tool_response": {},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    saved = json.loads((sd / "todos.json").read_text())
    assert len(saved["todos"]) == 1
    assert saved["todos"][0]["id"] == "99"
    assert saved["todos"][0]["status"] == "in_progress"
    assert saved["todos"][0]["content"] == "ghost"


def test_taskupdate_partial_does_not_overwrite_fields(state_dir: Path) -> None:
    """Only fields present in tool_input get patched — missing fields stay."""
    sd = _seed_session(state_dir)
    (sd / "todos.json").write_text(
        json.dumps(
            {
                "updated_at": 1,
                "todos": [
                    {
                        "id": "1",
                        "content": "Original",
                        "status": "pending",
                        "activeForm": "Originating",
                        "description": "keep me",
                    }
                ],
            }
        )
    )
    payload = {
        "session_id": "abc-123",
        "tool_name": "TaskUpdate",
        "tool_input": {"taskId": "1", "status": "completed"},
        "tool_response": {},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    saved = json.loads((sd / "todos.json").read_text())
    t = saved["todos"][0]
    assert t["status"] == "completed"
    assert t["content"] == "Original"
    assert t["activeForm"] == "Originating"
    assert t["description"] == "keep me"


def test_agent_foreground_clears_subagent_marker(state_dir: Path) -> None:
    sd = _seed_session(state_dir)
    (sd / "subagents").mkdir()
    (sd / "subagents/toolu_abc.json").write_text('{"tool_use_id":"toolu_abc"}')
    payload = {
        "session_id": "abc-123",
        "tool_use_id": "toolu_abc",
        "tool_name": "Agent",
        "tool_input": {"description": "Implement X"},
        "tool_response": {},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    assert not (sd / "subagents/toolu_abc.json").exists()
    # Empty subagents dir should be GC'd so state_reader doesn't list it.
    assert not (sd / "subagents").exists()


def test_agent_background_keeps_subagent_marker(state_dir: Path) -> None:
    """A backgrounded Agent() returns immediately from the parent's POV but
    the sub-agent keeps running. We must NOT remove the marker yet."""
    sd = _seed_session(state_dir)
    (sd / "subagents").mkdir()
    marker = sd / "subagents/toolu_xyz.json"
    marker.write_text('{"tool_use_id":"toolu_xyz","run_in_background":true}')
    payload = {
        "session_id": "abc-123",
        "tool_use_id": "toolu_xyz",
        "tool_name": "Agent",
        "tool_input": {"description": "Long task", "run_in_background": True},
        "tool_response": {},
    }
    run_hook("hud-post-tool.sh", payload, state_dir)
    assert marker.exists()


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
