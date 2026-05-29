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
    # name is None because meta.json's transcript_path is "" (no rename event
    # to scan for). The session-name plumbing has its own dedicated tests.
    # remote_control is None because no remote.json was seeded.
    assert snap["session"] == {
        "id": "abc",
        "name": None,
        "model": "claude-opus-4-7",
        "project": "/p",
        "remote_control": None,
    }
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
    assert snap == {
        "focused_tty": "/dev/ttys000",
        "sessions": [],
        "usage": None,
        "status": None,
        "config": {"usage_poll_interval_s": 300},
    }


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
    assert snap == {
        "focused_tty": "/dev/ttys000",
        "sessions": [],
        "usage": None,
        "status": None,
        "config": {"usage_poll_interval_s": 300},
    }


# ---------------------------------------------------------------------------
# session.name — derived from `custom-title` events in the transcript JSONL.
# Claude Code persists `/rename` (and `claude -n`) as these events; there's no
# hook that fires on rename, so the reader scans the transcript tail lazily.


def _seed_session_with_transcript(tmp_path: Path, transcript_lines: list[str]) -> Path:
    """Set up one tty/session pair whose meta.json points at a transcript file."""
    transcript = tmp_path / "transcripts" / "abc.jsonl"
    transcript.parent.mkdir(parents=True, exist_ok=True)
    transcript.write_text("\n".join(transcript_lines) + ("\n" if transcript_lines else ""))
    _write(
        tmp_path / "tty-map.json",
        {"/dev/ttys003": {"session_id": "abc", "claude_pid": 1, "started_at": 1000}},
    )
    _write(
        tmp_path / "sessions/abc/meta.json",
        {
            "session_id": "abc",
            "model": None,
            "project": "/p",
            "transcript_path": str(transcript),
            "started_at": 1000,
            "last_updated": 1000,
            "ended_at": None,
        },
    )
    return transcript


def test_session_name_from_transcript_custom_title(reader: StateReader, tmp_path: Path) -> None:
    """The latest `custom-title` line populates session.name."""
    _seed_session_with_transcript(
        tmp_path,
        [
            '{"type":"user","content":"hi"}',
            '{"type":"custom-title","customTitle":"m5-slice_c","sessionId":"abc"}',
        ],
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["name"] == "m5-slice_c"


def test_session_name_picks_latest_custom_title(reader: StateReader, tmp_path: Path) -> None:
    """A session can be renamed multiple times; the most recent value wins."""
    _seed_session_with_transcript(
        tmp_path,
        [
            '{"type":"custom-title","customTitle":"first","sessionId":"abc"}',
            '{"type":"assistant","content":"working..."}',
            '{"type":"custom-title","customTitle":"second","sessionId":"abc"}',
        ],
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["name"] == "second"


def test_session_name_none_when_no_custom_title(reader: StateReader, tmp_path: Path) -> None:
    """Transcript with no rename event surfaces name=None — webview falls back
    to the project basename."""
    _seed_session_with_transcript(
        tmp_path,
        [
            '{"type":"user","content":"hi"}',
            '{"type":"assistant","content":"ok"}',
        ],
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["name"] is None


def test_session_name_none_when_transcript_missing(reader: StateReader, tmp_path: Path) -> None:
    """A meta.json that points at a transcript that doesn't exist yet (Claude
    Code hasn't written one) is treated as no-data, not as an error."""
    _write(
        tmp_path / "tty-map.json",
        {"/dev/ttys003": {"session_id": "abc", "claude_pid": 1, "started_at": 1000}},
    )
    _write(
        tmp_path / "sessions/abc/meta.json",
        {
            "session_id": "abc",
            "model": None,
            "project": "/p",
            "transcript_path": str(tmp_path / "does-not-exist.jsonl"),
            "started_at": 1000,
            "last_updated": 1000,
            "ended_at": None,
        },
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["name"] is None


def test_session_name_handles_corrupt_lines(reader: StateReader, tmp_path: Path) -> None:
    """A malformed line near the tail must not blank out a perfectly good
    custom-title earlier in the transcript."""
    _seed_session_with_transcript(
        tmp_path,
        [
            '{"type":"custom-title","customTitle":"good-name","sessionId":"abc"}',
            "{this is not valid json",
            "random text without a brace",
        ],
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["name"] == "good-name"


def test_session_name_ignores_empty_custom_title(reader: StateReader, tmp_path: Path) -> None:
    """A `customTitle: ""` event shouldn't masquerade as a real rename — the
    earlier non-empty value remains the answer."""
    _seed_session_with_transcript(
        tmp_path,
        [
            '{"type":"custom-title","customTitle":"real","sessionId":"abc"}',
            '{"type":"custom-title","customTitle":"","sessionId":"abc"}',
        ],
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["name"] == "real"


def test_session_name_cached_when_transcript_unchanged(
    reader: StateReader, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The 200ms poll loop calls into the reader 5x/sec per session. We must
    not re-scan an unchanged transcript every poll — verify the transcript
    file is only opened once when mtime+size don't change. We patch the
    builtin `open` and filter on the transcript path so unrelated reads
    (meta.json, etc.) don't pollute the count."""
    transcript = _seed_session_with_transcript(
        tmp_path,
        ['{"type":"custom-title","customTitle":"cached","sessionId":"abc"}'],
    )
    transcript_path = str(transcript)

    import builtins

    real_open = builtins.open
    transcript_opens = {"n": 0}

    def counting_open(file, *args, **kwargs):  # type: ignore[no-untyped-def]
        if str(file) == transcript_path:
            transcript_opens["n"] += 1
        return real_open(file, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", counting_open)

    # Three back-to-back snapshots; the transcript is unchanged between them.
    for _ in range(3):
        snap = reader.snapshot_for_tty("/dev/ttys003")
        assert snap is not None
        assert snap["session"]["name"] == "cached"

    # First snapshot opens once; second and third hit the cache.
    assert transcript_opens["n"] == 1


def test_session_name_cache_invalidated_on_mtime_change(
    reader: StateReader, tmp_path: Path
) -> None:
    """When the user renames the session mid-poll-loop, the cached title must
    be invalidated so the new name appears within one poll cycle."""
    import os

    transcript = _seed_session_with_transcript(
        tmp_path,
        ['{"type":"custom-title","customTitle":"first","sessionId":"abc"}'],
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["name"] == "first"

    # Simulate Claude appending a new rename event. Bump mtime explicitly so
    # the test doesn't race the filesystem's mtime granularity (some FSes
    # round to whole seconds).
    with open(transcript, "a") as f:
        f.write('{"type":"custom-title","customTitle":"renamed","sessionId":"abc"}\n')
    st = transcript.stat()
    os.utime(transcript, (st.st_atime, st.st_mtime + 1))

    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["name"] == "renamed"


# ---------------------------------------------------------------------------
# session.remote_control — derived from remote.json in the session directory.
# Presence-of-file is the contract (issue #6): existing file → indicator on.


def test_remote_control_present(reader: StateReader, tmp_path: Path) -> None:
    """remote.json existing → session.remote_control is populated."""
    _seed_session_with_meta(tmp_path)
    _write(
        tmp_path / "sessions/abc/remote.json",
        {"channel": "schedule", "last_remote_at": 1779200000},
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["remote_control"] == {
        "channel": "schedule",
        "last_remote_at": 1779200000,
    }


def test_remote_control_absent(reader: StateReader, tmp_path: Path) -> None:
    """remote.json missing → session.remote_control is None."""
    _seed_session_with_meta(tmp_path)
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["remote_control"] is None


def test_remote_control_empty_dict_is_truthy(reader: StateReader, tmp_path: Path) -> None:
    """Empty {} → indicator on, both fields None. Presence-of-file is the contract."""
    _seed_session_with_meta(tmp_path)
    _write(tmp_path / "sessions/abc/remote.json", {})
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["remote_control"] == {"channel": None, "last_remote_at": None}


def test_remote_control_corrupt_json_returns_none(reader: StateReader, tmp_path: Path) -> None:
    """Corrupt remote.json → load_json returns None → indicator off (presence
    of *a file* is the contract, but a file we can't parse can't light it)."""
    _seed_session_with_meta(tmp_path)
    (tmp_path / "sessions/abc/remote.json").write_text("{not json")
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["remote_control"] is None


def test_remote_control_channel_too_long_is_dropped(reader: StateReader, tmp_path: Path) -> None:
    """Oversized channel string is dropped; presence still lights indicator."""
    _seed_session_with_meta(tmp_path)
    _write(tmp_path / "sessions/abc/remote.json", {"channel": "x" * 100})
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["remote_control"] == {"channel": None, "last_remote_at": None}


def test_remote_control_bad_field_types_dropped(reader: StateReader, tmp_path: Path) -> None:
    """Non-string channel and non-numeric last_remote_at are dropped individually."""
    _seed_session_with_meta(tmp_path)
    _write(
        tmp_path / "sessions/abc/remote.json",
        {"channel": ["a", "b"], "last_remote_at": "foo"},
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["remote_control"] == {"channel": None, "last_remote_at": None}


def test_remote_control_unknown_keys_filtered(reader: StateReader, tmp_path: Path) -> None:
    """Unknown keys are silently ignored — additive evolution is safe."""
    _seed_session_with_meta(tmp_path)
    _write(
        tmp_path / "sessions/abc/remote.json",
        {"channel": "schedule", "future_field": {"deep": "data"}, "another": 42},
    )
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["remote_control"] == {"channel": "schedule", "last_remote_at": None}


def test_remote_control_negative_timestamp_dropped(reader: StateReader, tmp_path: Path) -> None:
    """Negative last_remote_at is dropped; it can't be a real epoch second."""
    _seed_session_with_meta(tmp_path)
    _write(tmp_path / "sessions/abc/remote.json", {"last_remote_at": -1})
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["remote_control"] == {"channel": None, "last_remote_at": None}


def test_remote_control_boolean_timestamp_rejected(reader: StateReader, tmp_path: Path) -> None:
    """isinstance(True, int) is True in Python — reject explicitly."""
    _seed_session_with_meta(tmp_path)
    _write(tmp_path / "sessions/abc/remote.json", {"last_remote_at": True})
    snap = reader.snapshot_for_tty("/dev/ttys003")
    assert snap is not None
    assert snap["session"]["remote_control"] == {"channel": None, "last_remote_at": None}


# ---------------------------------------------------------------------------
# Global usage / status / config — added to snapshot_all() for the top strip.


def test_snapshot_all_usage_absent_is_none(reader: StateReader) -> None:
    assert reader.snapshot_all(None)["usage"] is None


def test_snapshot_all_usage_normalized(reader: StateReader, tmp_path: Path) -> None:
    _write(
        tmp_path / "usage.json",
        {
            "ok": True,
            "updated_at": 1,
            "five_hour": {"utilization": 152, "resets_at": "2026-05-28T07:50:00Z"},
            "seven_day": {"utilization": 22, "resets_at": None},
        },
    )
    usage = reader.snapshot_all(None)["usage"]
    assert usage["ok"] is True
    assert usage["five_hour"]["utilization"] == 100  # clamped
    assert usage["five_hour"]["resets_at"] == "2026-05-28T07:50:00Z"
    assert usage["seven_day"]["utilization"] == 22


def test_snapshot_all_usage_unavailable(reader: StateReader, tmp_path: Path) -> None:
    _write(tmp_path / "usage.json", {"ok": False, "reason": "expired", "updated_at": 1})
    usage = reader.snapshot_all(None)["usage"]
    assert usage == {"ok": False, "reason": "expired"}


def test_snapshot_all_usage_corrupt_is_none(reader: StateReader, tmp_path: Path) -> None:
    (tmp_path / "usage.json").write_text("{not json")
    assert reader.snapshot_all(None)["usage"] is None


def test_snapshot_all_status_normalized(reader: StateReader, tmp_path: Path) -> None:
    _write(
        tmp_path / "status.json",
        {
            "ok": True,
            "updated_at": 1,
            "indicator": "minor",
            "description": "Minor Service Outage",
            "incident": {
                "name": "X" * 200,  # over the 120 cap
                "status": "investigating",
                "impact": "minor",
                "body": "Y" * 600,  # over the 500 cap
                "updated_at": "2026-05-28T19:04:00Z",
            },
        },
    )
    status = reader.snapshot_all(None)["status"]
    assert status["indicator"] == "minor"
    assert len(status["incident"]["name"]) == 120
    assert len(status["incident"]["body"]) == 500


def test_snapshot_all_status_unknown_indicator_constrained(
    reader: StateReader, tmp_path: Path
) -> None:
    _write(
        tmp_path / "status.json",
        {"ok": True, "indicator": "weird", "description": "?", "incident": None},
    )
    assert reader.snapshot_all(None)["status"]["indicator"] == "unknown"


def test_snapshot_all_config_default_when_absent(reader: StateReader) -> None:
    assert reader.snapshot_all(None)["config"] == {"usage_poll_interval_s": 300}


def test_snapshot_all_config_reads_valid_value(reader: StateReader, tmp_path: Path) -> None:
    _write(tmp_path / "config.json", {"usage_poll_interval_s": 120})
    assert reader.snapshot_all(None)["config"] == {"usage_poll_interval_s": 120}
