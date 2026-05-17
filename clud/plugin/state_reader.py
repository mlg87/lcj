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
import time
from pathlib import Path
from typing import Any


class StateReader:
    def __init__(self, state_dir: Path) -> None:
        self._dir = state_dir

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

        return {
            "tty": tty,
            "session": {
                "id": session_id,
                "model": meta.get("model"),
                "project": meta.get("project", ""),
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
        return {"focused_tty": focused_tty, "sessions": sessions}

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
