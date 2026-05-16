"""Read JSON state files written by the Claude Code hooks.

Architecture role:
    The reader is the read-side anchor of the HUD's filesystem contract.
    It is the *only* piece that knows the on-disk layout under
    ~/.claude/state/hud/. Everything downstream (the server, the webview)
    consumes the dict it returns from `snapshot_for_tty()`.

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

        # todos and current are both optional — a fresh session has neither.
        todos_doc = self._load_json(session_dir / "todos.json") or {}
        todos = todos_doc.get("todos", []) if isinstance(todos_doc, dict) else []

        current_doc = self._load_json(session_dir / "current.json")
        current = self._enrich_current(current_doc) if isinstance(current_doc, dict) else None

        return {
            "tty": tty,
            "session": {
                "id": session_id,
                "model": meta.get("model"),
                "project": meta.get("project", ""),
            },
            "current": current,
            "todos": todos,
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
