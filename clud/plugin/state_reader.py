"""Read JSON state files written by the Claude Code hooks.

Architecture role:
    The reader is the read-side anchor of the HUD's filesystem contract.
    It is the *only* piece that knows the on-disk layout under
    ~/.claude/state/hud/. Everything downstream (the server, the webview)
    consumes the dicts it returns from `snapshot_for_tty()` /
    `snapshot_all()`.

Snapshot shapes:
    `snapshot_for_tty(tty)`  → one-session dict (used by tests and as the
                               per-session building block).
    `snapshot_all(focused)`  → {focused_tty, sessions: [snapshot, ...]} so
                               the HUD can render every live Claude session
                               at once and highlight the focused one. Sessions
                               appear in tty-map insertion order; corrupt or
                               session-less entries are filtered out.

Robustness contract:
    Hooks may be mid-write, may have crashed, or may not have written
    files yet. The reader treats any of these as "no data" and returns
    None or empty defaults — never raises. Atomic writes on the writer
    side (tmp + rename) make torn reads impossible in practice, but the
    json.loads guard is belt-and-suspenders.
"""

from __future__ import annotations

import json
import math
import time
from pathlib import Path
from typing import Any

from hud_config import read_usage_interval  # type: ignore[import-not-found]

# How many trailing bytes of a session transcript we scan for the latest
# `custom-title` event (issue #5). 256 KiB is enough to comfortably hold the
# tail of a long-running session — a single custom-title line is ~120 bytes,
# and Claude appends it on every /rename. Above this we'd start paying
# linear cost on multi-megabyte transcripts. Tuned with the 200ms poll
# cadence and the single-slot mtime cache below in mind.
_TRANSCRIPT_TAIL_BYTES = 256 * 1024

# Allowed overall-status indicators; anything else (or a failed fetch) renders
# as "unknown" — never as operational/green.
_STATUS_INDICATORS = {"none", "minor", "major", "critical", "unknown"}


def _cap_str(value: object, limit: int) -> str | None:
    """Coerce to a length-capped str, or None. Defense-in-depth so a long
    blob from a status payload (or a hand-edited file) can't bloat the DOM."""
    return value[:limit] if isinstance(value, str) else None


def _epoch_or_none(value: object) -> int | None:
    """Coerce to an int epoch-seconds value, or None. bool is excluded
    explicitly (it subclasses int), and non-finite floats are rejected so a
    hand-edited meta.json can never leak NaN/inf to the webview."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value):
        return None
    return int(value)


class StateReader:
    def __init__(self, state_dir: Path) -> None:
        self._dir = state_dir
        # Cache of custom-title lookups keyed by transcript path. Value is
        # (mtime, size, custom_title). The 200ms poll loop hits this method
        # 5x/sec per session — without caching we'd re-read 256KB per call
        # even when the transcript hasn't changed. We invalidate on either
        # mtime or size change so an in-place append (mtime updates but size
        # might collide briefly under fast typing) and a same-size overwrite
        # are both detected.
        self._title_cache: dict[str, tuple[float, int, str | None]] = {}

    def snapshot_for_tty(self, tty: str | None) -> dict[str, Any] | None:
        """Return the full snapshot for the session attached to `tty`, or None.

        None is returned when:
          - tty is None or empty (e.g., focused pane has no claude session)
          - tty is not present in tty-map.json
          - tty-map.json is missing or corrupt
          - the resolved session has no meta.json (treated as "no session")
        """
        if not tty:
            return None
        tty_map = self._load_json(self._dir / "tty-map.json")
        if not isinstance(tty_map, dict):
            return None
        entry = tty_map.get(tty)
        if not isinstance(entry, dict):
            return None
        session_id = entry.get("session_id")
        if not isinstance(session_id, str):
            return None

        session_dir = self._dir / "sessions" / session_id
        meta = self._load_json(session_dir / "meta.json")
        if not isinstance(meta, dict):
            return None

        # todos, current, subagents are all optional — a fresh session has none.
        todos_doc = self._load_json(session_dir / "todos.json") or {}
        todos = todos_doc.get("todos", []) if isinstance(todos_doc, dict) else []

        current_doc = self._load_json(session_dir / "current.json")
        current = self._enrich_current(current_doc) if isinstance(current_doc, dict) else None

        subagents = self._collect_subagents(session_dir / "subagents")

        # Remote-control indicator (issue #6). Presence of remote.json signals
        # that this session is reachable from outside the local terminal
        # (scheduled trigger, MCP, etc.). Content is just a tooltip-friendly
        # descriptor — never a secret. See clud/docs/REMOTE_CONTROL.md for the
        # writer contract.
        remote_doc = self._load_json(session_dir / "remote.json")
        remote_control = (
            self._normalize_remote(remote_doc) if isinstance(remote_doc, dict) else None
        )

        # Session name (issue #5). Claude Code persists `/rename` and
        # `claude -n <name>` as `{"type":"custom-title", ...}` lines appended
        # to the live transcript JSONL. We scan its tail lazily — there is no
        # hook that fires on /rename, so the reader is the right place to
        # pick it up. None when the user hasn't renamed the session; the
        # webview falls back to the project basename in that case.
        transcript_path = meta.get("transcript_path")
        name = self._read_custom_title(transcript_path) if transcript_path else None

        return {
            "tty": tty,
            "session": {
                "id": session_id,
                "name": name,
                "model": meta.get("model"),
                "project": meta.get("project", ""),
                "remote_control": remote_control,
                # Epoch seconds from the SessionStart hook; the webview's
                # card footer renders it as "Started @ <clock time>".
                "started_at": _epoch_or_none(meta.get("started_at")),
            },
            "current": current,
            "todos": todos,
            "subagents": subagents,
        }

    def snapshot_all(self, focused_tty: str | None) -> dict[str, Any]:
        """Snapshot every live Claude session, marking the focused one.

        Returns {focused_tty, sessions: [snapshot,...]} where each snapshot is
        what `snapshot_for_tty` returns. `focused_tty` is normalized through
        the tty-map keys so the webview can match it by string equality.

        Sessions whose meta.json is missing or tty-map entry is malformed are
        silently dropped — same robustness contract as the single-session path.
        Always returns a dict (never None) so the SSE push has a stable shape.
        """
        tty_map = self._load_json(self._dir / "tty-map.json")
        sessions: list[dict[str, Any]] = []
        if isinstance(tty_map, dict):
            # Preserve insertion order so the HUD doesn't reshuffle cards
            # between polls. Python dicts are insertion-ordered ≥3.7.
            for tty in tty_map:
                snap = self.snapshot_for_tty(tty)
                if snap is not None:
                    sessions.append(snap)
        return {
            "focused_tty": focused_tty,
            "sessions": sessions,
            "usage": self._read_usage(),
            "status": self._read_status(),
            "config": {"usage_poll_interval_s": read_usage_interval(self._dir)},
        }

    def _read_usage(self) -> dict[str, Any] | None:
        """Global usage snapshot from usage.json (None if absent/corrupt)."""
        doc = self._load_json(self._dir / "usage.json")
        if not isinstance(doc, dict):
            return None
        return self._normalize_usage(doc)

    @staticmethod
    def _normalize_usage(doc: dict[str, Any]) -> dict[str, Any]:
        out: dict[str, Any] = {"ok": bool(doc.get("ok"))}
        reason = doc.get("reason")
        if isinstance(reason, str):
            out["reason"] = reason
        for key in ("five_hour", "seven_day"):
            bucket = doc.get(key)
            if isinstance(bucket, dict):
                util = bucket.get("utilization")
                if isinstance(util, (int, float)) and not isinstance(util, bool):
                    resets = bucket.get("resets_at")
                    out[key] = {
                        "utilization": max(0, min(100, round(util))),
                        "resets_at": resets if isinstance(resets, str) else None,
                    }
        return out

    def _read_status(self) -> dict[str, Any] | None:
        """Global service-status snapshot from status.json (None if absent)."""
        doc = self._load_json(self._dir / "status.json")
        if not isinstance(doc, dict):
            return None
        return self._normalize_status(doc)

    @staticmethod
    def _normalize_status(doc: dict[str, Any]) -> dict[str, Any]:
        indicator = doc.get("indicator")
        indicator = indicator if indicator in _STATUS_INDICATORS else "unknown"
        description = doc.get("description")
        description = description[:200] if isinstance(description, str) else ""
        incident: dict[str, Any] | None = None
        raw = doc.get("incident")
        if isinstance(raw, dict):
            incident = {
                "name": _cap_str(raw.get("name"), 120),
                "status": _cap_str(raw.get("status"), 32),
                "impact": _cap_str(raw.get("impact"), 32),
                "body": _cap_str(raw.get("body"), 500),
                "updated_at": _cap_str(raw.get("updated_at"), 40),
            }
        return {
            "ok": bool(doc.get("ok")),
            "indicator": indicator,
            "description": description,
            "incident": incident,
        }

    @staticmethod
    def _load_json(path: Path) -> Any:
        # Catches every plausible "no data" case: missing file, corrupt JSON,
        # permission denied, etc. The HUD must not crash from disk surprises.
        try:
            return json.loads(path.read_text())
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return None

    @staticmethod
    def _enrich_current(doc: dict[str, Any]) -> dict[str, Any]:
        # running_for_ms is computed at read time so it always reflects the
        # actual elapsed since the tool started, regardless of when the hook
        # last wrote (which is just once, at PreToolUse).
        started_at = doc.get("started_at", 0)
        running_for_ms = max(0, int((time.time() - started_at) * 1000))
        return {
            "tool_name": doc.get("tool_name", ""),
            "input_summary": doc.get("input_summary", ""),
            "running_for_ms": running_for_ms,
        }

    def _collect_subagents(self, subagents_dir: Path) -> list[dict[str, Any]]:
        """List currently-running sub-agent markers, oldest first.

        One file per concurrent Agent invocation, keyed by tool_use_id and
        written by hud-pre-tool.sh. PostToolUse removes the file when the
        sub-agent returns (foreground) — until then we treat it as live and
        compute running_for_ms here, same pattern as `current`.
        """
        if not subagents_dir.is_dir():
            return []
        agents: list[dict[str, Any]] = []
        now = time.time()
        try:
            entries = sorted(subagents_dir.iterdir())
        except OSError:
            return []
        for path in entries:
            if not path.is_file() or path.name.startswith("."):
                continue
            doc = self._load_json(path)
            if not isinstance(doc, dict):
                continue
            started_at = doc.get("started_at", 0)
            agents.append(
                {
                    "tool_use_id": doc.get("tool_use_id", ""),
                    "description": doc.get("description", ""),
                    "subagent_type": doc.get("subagent_type", ""),
                    "model": doc.get("model", ""),
                    "run_in_background": bool(doc.get("run_in_background", False)),
                    "running_for_ms": max(0, int((now - started_at) * 1000)),
                }
            )
        # Stable ordering by start time so the HUD doesn't reshuffle rows
        # when iterdir() returns inodes in a different order on rescan.
        agents.sort(key=lambda a: a["running_for_ms"], reverse=True)
        return agents

    @staticmethod
    def _normalize_remote(doc: dict[str, Any]) -> dict[str, Any]:
        """Normalize a remote.json payload into the snapshot shape.

        Presence-of-file is the source of truth (issue #6) — so this returns a
        dict (never None) whenever the file parsed as a dict. Bad fields are
        dropped to None individually so a malformed-but-present file still
        lights the indicator, just with a bare tooltip.

        Channel must be a real str (rejects lists/dicts/ints), trimmed,
        non-empty, and ≤32 chars (defense in depth against bad writers
        leaking long blobs into the DOM).

        last_remote_at must coerce to a non-negative int. Booleans are
        rejected explicitly because `isinstance(True, int) is True` in Python.
        """
        channel: str | None = None
        raw_channel = doc.get("channel")
        if isinstance(raw_channel, str):
            trimmed = raw_channel.strip()
            if trimmed and len(trimmed) <= 32:
                channel = trimmed

        last_remote_at: int | None = None
        raw_ts = doc.get("last_remote_at")
        if isinstance(raw_ts, bool):
            pass  # bool is a subclass of int; reject explicitly
        elif isinstance(raw_ts, (int, float)):
            ts = int(raw_ts)
            if ts >= 0:
                last_remote_at = ts

        return {"channel": channel, "last_remote_at": last_remote_at}

    def _read_custom_title(self, transcript_path: str) -> str | None:
        """Return the latest custom session name from the transcript, or None.

        Claude Code persists `/rename` (and `claude -n`) as JSONL events of the
        shape `{"type":"custom-title","customTitle":"…","sessionId":"…"}`
        appended to the live transcript at the path in meta.json. The latest
        such line wins — a session can be renamed multiple times.

        We scan only the trailing `_TRANSCRIPT_TAIL_BYTES` and short-circuit
        on the first `custom-title` line found walking backwards. Cached by
        (mtime, size) so an unchanged transcript skips the read entirely; the
        HUD polls every 200ms and transcripts can grow to multiple megabytes.

        Returns None for any read failure, malformed JSON, missing field, etc.
        — the snapshot must never raise from a disk surprise.
        """
        try:
            st = Path(transcript_path).stat()
        except OSError:
            return None

        cached = self._title_cache.get(transcript_path)
        if cached is not None and cached[0] == st.st_mtime and cached[1] == st.st_size:
            return cached[2]

        title: str | None = None
        try:
            with open(transcript_path, "rb") as f:
                if st.st_size > _TRANSCRIPT_TAIL_BYTES:
                    f.seek(-_TRANSCRIPT_TAIL_BYTES, 2)
                    # If we seeked into the middle of a line, drop the partial
                    # leading fragment so json.loads doesn't see a half-record.
                    # On a freshly-truncated boundary readline() returns up to
                    # and including the next newline.
                    f.readline()
                tail = f.read()
        except OSError:
            self._title_cache[transcript_path] = (st.st_mtime, st.st_size, None)
            return None

        # Walk lines from the end so we stop at the most recent custom-title.
        # The substring check is a cheap pre-filter that lets us skip JSON
        # parsing for ~all transcript lines (which are tool calls / messages).
        for line in reversed(tail.splitlines()):
            if b'"type":"custom-title"' not in line:
                continue
            try:
                doc = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if not isinstance(doc, dict):
                continue
            if doc.get("type") != "custom-title":
                continue
            candidate = doc.get("customTitle")
            if isinstance(candidate, str) and candidate:
                title = candidate
                break

        self._title_cache[transcript_path] = (st.st_mtime, st.st_size, title)
        return title
