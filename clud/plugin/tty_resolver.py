# clud/plugin/tty_resolver.py
"""TTY normalization and stale-session garbage collection.

Architecture role:
    The resolver does NOT do tty→session_id lookup itself — that's the
    state_reader's job (it reads tty-map.json directly). This module
    exists for the two side concerns:

        1. Normalizing iTerm's tty string into the canonical form the
           hooks write. iTerm returns "/dev/ttys003"; older ps versions
           sometimes return "ttys003" or "s003"; we coerce all to
           "/dev/ttys003" so map lookup is a straight key compare.

        2. Pruning entries whose claude_pid is no longer alive. Happy-path
           cleanup is the SessionEnd hook (clud/hooks/hud-session-end.sh),
           but Claude can crash without firing it. The plugin runs this
           GC at startup and every ~12s thereafter.
"""

from __future__ import annotations

import json
import os
from pathlib import Path


class TtyResolver:
    def __init__(self, state_dir: Path) -> None:
        self._dir = state_dir

    @staticmethod
    def normalize(tty: str | None) -> str | None:
        """Canonicalize iTerm's tty string to "/dev/ttys003" form."""
        if not tty or tty in ("?", "??"):
            return None
        if tty.startswith("/dev/"):
            return tty
        if tty.startswith("ttys"):
            return f"/dev/{tty}"
        if tty.startswith("s") and tty[1:].isdigit():
            return f"/dev/tty{tty}"
        return f"/dev/{tty}"

    def gc_dead_sessions(self) -> None:
        """Remove tty-map entries whose claude_pid is no longer running."""
        # NOTE: does not hold the bash mkdir lock used by hud_map_edit, so a
        # concurrent SessionStart write may have its entry lost. Window is small
        # (GC runs every ~12s) and the next SessionStart re-fire heals it.
        map_path = self._dir / "tty-map.json"
        try:
            current = json.loads(map_path.read_text())
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            # Missing → nothing to GC. Corrupt → don't risk overwriting
            # state we can't read (the user can wipe it manually).
            return
        if not isinstance(current, dict):
            return

        live: dict[str, dict[str, object]] = {}
        for tty, entry in current.items():
            if not isinstance(entry, dict):
                continue
            pid = entry.get("claude_pid")
            if isinstance(pid, int) and self._pid_alive(pid):
                live[tty] = entry

        # Only rewrite if we actually changed something — saves an fsync
        # storm if the map is stable.
        if live != current:
            tmp = map_path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(live))
            tmp.replace(map_path)

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        # `kill -0` is the canonical "is this pid alive?" probe — it sends
        # no signal, just performs the permission check. PermissionError
        # means the process exists but belongs to another user (we still
        # count it as alive).
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True
