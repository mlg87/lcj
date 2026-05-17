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


def _seed_session_with_meta(tmp_path: Path, session_id: str = "abc") -> Path:
    _write(
        tmp_path / "tty-map.json",
        {"/dev/ttys003": {"session_id": session_id, "claude_pid": 1, "started_at": 1000}},
    )
    _write(
        tmp_path / f"sessions/{session_id}/meta.json",
        {
            "session_id": session_id,
            "model": None,
            "project": "/p",
            "transcript_path": "",
            "started_at": 1000,
            "last_updated": 1000,
            "ended_at": None,
        },
    )
    return tmp_path / "sessions" / session_id


def test_subagents_absent_returns_empty_list(reader: StateReader, tmp_path: Path) -> None:
    _seed_session_with_meta(tmp_path)
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["subagents"] == []


def test_subagents_present_returned_with_running_for_ms(
    reader: StateReader, tmp_path: Path
) -> None:
    """The reader scans sessions/<id>/subagents/ and surfaces each marker."""
    sd = _seed_session_with_meta(tmp_path)
    _write(
        sd / "subagents/toolu_a.json",
        {
            "tool_use_id": "toolu_a",
            "description": "Implement X",
            "subagent_type": "general-purpose",
            "model": "sonnet",
            "run_in_background": False,
            "started_at": 1,
        },
    )
    _write(
        sd / "subagents/toolu_b.json",
        {
            "tool_use_id": "toolu_b",
            "description": "Review Y",
            "subagent_type": "feature-dev:code-reviewer",
            "model": "opus",
            "run_in_background": True,
            "started_at": 2,
        },
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert len(snap["subagents"]) == 2
    by_id = {a["tool_use_id"]: a for a in snap["subagents"]}
    a = by_id["toolu_a"]
    assert a["description"] == "Implement X"
    assert a["subagent_type"] == "general-purpose"
    assert a["model"] == "sonnet"
    assert a["run_in_background"] is False
    assert a["running_for_ms"] >= 0
    b = by_id["toolu_b"]
    assert b["run_in_background"] is True


def test_subagents_oldest_first(reader: StateReader, tmp_path: Path) -> None:
    """Stable ordering: longest-running agent appears first so the HUD
    doesn't reshuffle visible rows on every snapshot rescan."""
    sd = _seed_session_with_meta(tmp_path)
    _write(sd / "subagents/newer.json", {"tool_use_id": "newer", "started_at": 100})
    _write(sd / "subagents/older.json", {"tool_use_id": "older", "started_at": 1})
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    ids = [a["tool_use_id"] for a in snap["subagents"]]
    assert ids == ["older", "newer"]


def test_corrupt_subagent_marker_is_skipped(reader: StateReader, tmp_path: Path) -> None:
    """One bad marker file must not blank out the entire subagents list."""
    sd = _seed_session_with_meta(tmp_path)
    (sd / "subagents").mkdir()
    (sd / "subagents/bad.json").write_text("{not json")
    _write(
        sd / "subagents/good.json",
        {"tool_use_id": "good", "description": "ok", "started_at": 1},
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert [a["tool_use_id"] for a in snap["subagents"]] == ["good"]


# ---------------------------------------------------------------------------
# snapshot_all() — multi-session view used by the HUD's render loop.


def _seed_two_sessions(tmp_path: Path) -> None:
    """tty-map with two live sessions, each with a meta.json."""
    _write(
        tmp_path / "tty-map.json",
        {
            "/dev/ttys000": {"session_id": "s0", "claude_pid": 1, "started_at": 1},
            "/dev/ttys001": {"session_id": "s1", "claude_pid": 2, "started_at": 2},
        },
    )
    for sid, proj in [("s0", "/proj-a"), ("s1", "/proj-b")]:
        _write(
            tmp_path / f"sessions/{sid}/meta.json",
            {
                "session_id": sid,
                "model": None,
                "project": proj,
                "transcript_path": "",
                "started_at": 1000,
                "last_updated": 1000,
                "ended_at": None,
            },
        )


def test_snapshot_all_empty_when_no_tty_map(reader: StateReader) -> None:
    """Always returns a dict (never None) so the SSE has a stable shape."""
    snap = reader.snapshot_all("/dev/ttys000")
    assert snap == {"focused_tty": "/dev/ttys000", "sessions": []}


def test_snapshot_all_returns_each_session(reader: StateReader, tmp_path: Path) -> None:
    _seed_two_sessions(tmp_path)
    snap = reader.snapshot_all("/dev/ttys001")
    assert snap["focused_tty"] == "/dev/ttys001"
    ttys = [s["tty"] for s in snap["sessions"]]
    # Insertion order preserved so the HUD doesn't shuffle cards between polls.
    assert ttys == ["/dev/ttys000", "/dev/ttys001"]
    projects = [s["session"]["project"] for s in snap["sessions"]]
    assert projects == ["/proj-a", "/proj-b"]


def test_snapshot_all_includes_per_session_data(reader: StateReader, tmp_path: Path) -> None:
    """Each card carries its own todos / current / subagents — independent."""
    _seed_two_sessions(tmp_path)
    _write(
        tmp_path / "sessions/s0/todos.json",
        {
            "updated_at": 1,
            "todos": [{"id": "1", "content": "A", "status": "pending", "activeForm": ""}],
        },
    )
    _write(
        tmp_path / "sessions/s1/current.json",
        {"tool_name": "Bash", "input_summary": "ls", "started_at": 1},
    )
    snap = reader.snapshot_all("/dev/ttys001")
    by_tty = {s["tty"]: s for s in snap["sessions"]}
    assert by_tty["/dev/ttys000"]["todos"][0]["content"] == "A"
    assert by_tty["/dev/ttys000"]["current"] is None
    assert by_tty["/dev/ttys001"]["todos"] == []
    assert by_tty["/dev/ttys001"]["current"]["tool_name"] == "Bash"


def test_snapshot_all_skips_session_with_no_meta(reader: StateReader, tmp_path: Path) -> None:
    """A tty-map entry pointing at a session whose meta.json never got written
    (e.g. SessionStart hook crashed) is silently dropped, not propagated as
    a half-broken card."""
    _write(
        tmp_path / "tty-map.json",
        {
            "/dev/ttys000": {"session_id": "ghost", "claude_pid": 1, "started_at": 1},
            "/dev/ttys001": {"session_id": "real", "claude_pid": 2, "started_at": 2},
        },
    )
    _write(
        tmp_path / "sessions/real/meta.json",
        {
            "session_id": "real",
            "model": None,
            "project": "/p",
            "transcript_path": "",
            "started_at": 1,
            "last_updated": 1,
            "ended_at": None,
        },
    )
    snap = reader.snapshot_all("/dev/ttys001")
    assert [s["tty"] for s in snap["sessions"]] == ["/dev/ttys001"]


def test_snapshot_all_focused_tty_passthrough_when_no_focus(reader: StateReader) -> None:
    """None focus is preserved verbatim so the webview can show no card as
    highlighted (e.g. focus is on a non-terminal window)."""
    snap = reader.snapshot_all(None)
    assert snap["focused_tty"] is None
    assert snap["sessions"] == []


def test_snapshot_all_handles_corrupt_tty_map(reader: StateReader, tmp_path: Path) -> None:
    (tmp_path / "tty-map.json").write_text("{not json")
    snap = reader.snapshot_all("/dev/ttys000")
    assert snap == {"focused_tty": "/dev/ttys000", "sessions": []}
