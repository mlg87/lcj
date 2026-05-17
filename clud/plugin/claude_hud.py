# clud/plugin/claude_hud.py
"""Auto-launch entry point for the Claude HUD iTerm2 plugin.

Wiring:
    1. Start an aiohttp server bound to 127.0.0.1 on a random port.
       This server hosts the webview HTML/CSS/JS and an SSE endpoint
       that streams snapshots to the toolbelt webview.
    2. Register a toolbelt webview tool pointed at that server. iTerm
       embeds the URL as a webview in its toolbelt sidebar.
    3. Poll iTerm's focused session every 200ms; resolve its tty to a
       claude session_id (via tty-map.json), assemble the snapshot,
       and push it to the webview if it differs from the last snapshot.
    4. GC stale tty-map entries every ~12s (60 polls x 200ms).
    5. Write diagnostics.json every ~5s (25 polls x 200ms) so users can
       answer "why isn't the HUD updating?" by `cat`-ing one file.

WHY polling not file-watch:
    Polling 5x/sec on three tiny JSON files is essentially free with
    the kernel page cache, and the same loop handles BOTH state changes
    (file mtime) and focus changes (iTerm internal events). One control
    flow to debug. Snapshots are only pushed when actually different.

WHY 200ms:
    Below ~250ms feels live to humans for tool-state updates. Above
    ~500ms feels laggy. 200ms is comfortably in the live zone with
    headroom for jitter.

Failure modes:
    - Plugin crashes mid-poll: caught and logged; the loop continues.
    - GC fails: caught and logged; the loop continues.
    - iTerm API daemon disabled: this script can't even start. Document
      the fix in README ("Settings → General → Magic → Enable Python API").
"""

from __future__ import annotations

import asyncio
import calendar
import json
import logging
import sys
import time
from pathlib import Path
from typing import Any

import iterm2

# Absolute imports (no `from .X`) so this works both ways:
#   - Dev: pytest discovers modules via `plugin/` being on sys.path; mypy
#     finds them via `mypy_path = ["plugin"]` in pyproject.
#   - iTerm runtime: `main.py` is a symlink to this file. When iTerm runs it
#     as a script, sys.path[0] is the script's own directory, so sibling
#     modules import by bare name.
from hud_server import HudServer  # type: ignore[import-not-found]
from iterm2.tool import async_register_web_view_tool
from state_reader import StateReader  # type: ignore[import-not-found]
from tty_resolver import TtyResolver  # type: ignore[import-not-found]

STATE_DIR = Path("~/.claude/state/hud").expanduser()
POLL_INTERVAL_S = 0.2
GC_EVERY_N_POLLS = 60  # ~12s
DIAG_EVERY_N_POLLS = 25  # ~5s — periodic diagnostics.json refresh
TOOL_IDENTIFIER = "com.masongoetz.claude.hud"
TOOL_DISPLAY_NAME = "Claude HUD"

log = logging.getLogger("claude_hud")


async def main(connection: iterm2.Connection) -> None:  # type: ignore[name-defined]
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    # Webview lives next to this file inside the plugin package.
    webview_dir = Path(__file__).parent / "webview"
    server = HudServer(webview_dir=webview_dir)
    port = await server.start()
    log.info("HUD server bound at http://127.0.0.1:%d", port)

    # reveal_if_already_registered=True so dev iterations (re-run the
    # script during a session) re-show the panel instead of silently
    # erroring on the duplicate identifier.
    await async_register_web_view_tool(
        connection,
        display_name=TOOL_DISPLAY_NAME,
        identifier=TOOL_IDENTIFIER,
        reveal_if_already_registered=True,
        url=f"http://127.0.0.1:{port}/",
    )

    reader = StateReader(STATE_DIR)
    resolver = TtyResolver(STATE_DIR)
    app = await iterm2.async_get_app(connection)  # type: ignore[attr-defined]
    assert app is not None  # iTerm always provides one when the plugin is running

    # Sentinel that compares unequal to any real snapshot — guarantees the
    # first iteration always pushes, even if the state happens to be None.
    last_snapshot: object = object()
    poll_count = 0
    started_at = int(time.time())
    last_pushed_at = 0
    hook_error_count = 0  # crude: we count errors.log line count once per diag

    while True:
        snapshot: dict[str, Any] | None = None
        tty: str | None = None
        try:
            tty = await _focused_tty(app)
            normalized = resolver.normalize(tty)
            # Multi-session shape: render every live Claude session as its
            # own card and tag the one that owns the currently-focused pane.
            # Each card's snapshot is the same dict snapshot_for_tty used to
            # return; the webview reads `sessions[]` and matches `focused_tty`.
            snapshot = reader.snapshot_all(normalized)
            if snapshot != last_snapshot:
                await server.push(snapshot)
                last_snapshot = snapshot
                last_pushed_at = int(time.time())
        except Exception:
            log.exception("poll iteration failed; continuing")

        poll_count += 1
        if poll_count % GC_EVERY_N_POLLS == 0:
            try:
                resolver.gc_dead_sessions()
            except Exception:
                log.exception("gc failed; continuing")

        # Diagnostics let users debug "why isn't the HUD updating?" without
        # needing to add print statements. Written every ~5s; cheap.
        if poll_count % DIAG_EVERY_N_POLLS == 0:
            try:
                hook_error_count = _count_hook_errors(STATE_DIR)
                tty_map_size = _tty_map_size(STATE_DIR)
                # snapshot is now multi-session: extract focused session_id
                # by matching the focused_tty against each session's tty.
                resolved = None
                if snapshot:
                    for s in snapshot.get("sessions", []):
                        if s.get("tty") == snapshot.get("focused_tty"):
                            sess = s.get("session") or {}
                            resolved = sess.get("id")
                            break
                _write_diagnostics(
                    STATE_DIR,
                    {
                        "plugin_started_at": started_at,
                        "focused_tty": tty,
                        "resolved_session_id": resolved,
                        "session_count": len(snapshot.get("sessions", [])) if snapshot else 0,
                        "last_snapshot_pushed_at": last_pushed_at,
                        "hook_error_count_24h": hook_error_count,
                        "tty_map_size": tty_map_size,
                    },
                )
            except Exception:
                log.exception("diagnostics write failed; continuing")

        await asyncio.sleep(POLL_INTERVAL_S)


async def _focused_tty(app: iterm2.App) -> str | None:  # type: ignore[name-defined]
    """Return the tty of iTerm's currently-focused session, or None.

    iTerm exposes the tty as a session variable named "tty"; the value
    looks like "/dev/ttys003". Returns None if there's no focused window
    (e.g., iTerm was just launched and no window is open yet).
    """
    win = app.current_terminal_window
    if win is None:
        return None
    tab = win.current_tab
    if tab is None:
        return None
    sess = tab.current_session
    if sess is None:
        return None
    result = await sess.async_get_variable("tty")
    return result if isinstance(result, str) else None


def _write_diagnostics(state_dir: Path, payload: dict[str, Any]) -> None:
    """Atomic-write diagnostics.json so readers never see a torn write."""
    dest = state_dir / "diagnostics.json"
    tmp = dest.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload))
    tmp.replace(dest)


def _count_hook_errors(state_dir: Path) -> int:
    """Best-effort count of recent error lines. Missing log → 0."""
    log_path = state_dir / "errors.log"
    try:
        cutoff = time.time() - 24 * 3600
        count = 0
        with log_path.open() as f:
            for line in f:
                # Lines start with ISO-8601 UTC: "2026-05-15T19:51:13Z [hook] msg"
                try:
                    ts_str = line.split(" ", 1)[0]
                    ts = calendar.timegm(time.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ"))
                    if ts >= cutoff:
                        count += 1
                except (ValueError, IndexError):
                    continue
        return count
    except (FileNotFoundError, OSError):
        return 0


def _tty_map_size(state_dir: Path) -> int:
    try:
        m = json.loads((state_dir / "tty-map.json").read_text())
        return len(m) if isinstance(m, dict) else 0
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return 0


if __name__ == "__main__":
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s: %(message)s",
    )
    iterm2.run_forever(main)  # type: ignore[attr-defined]
