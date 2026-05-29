"""Tiny aiohttp app: serves the webview and pushes snapshots over SSE.

Architecture role:
    iTerm's `async_register_web_view_tool` only takes a URL — the toolbelt
    panel is just a webview pointed at it. So we host the HUD ourselves
    on a 127.0.0.1-bound HTTP server with a kernel-chosen random port.

    Mostly read-side: the server serves static files and pushes snapshots.
    The single write-side endpoint is `DELETE /sessions/<sid>/todos`, the
    backing for the HUD's "clear todos" button — see _clear_todos below.

WHY SSE not WebSocket:
    One-way server→client push is exactly what we need. SSE is half the
    code, browsers ship it natively (EventSource), and it auto-reconnects.

WHY a single in-memory subscriber set:
    The HUD has at most a handful of subscribers (the toolbelt webview,
    plus a debug browser tab if the developer opens one). No need for
    pub/sub infrastructure.

Latest-snapshot replay:
    push() also caches the most-recent snapshot, and new subscribers get
    it as their first frame. Without this, opening the toolbelt while
    Claude is idle would leave the panel blank until the next state change.
"""

from __future__ import annotations

import asyncio
import json
import re
import time
from pathlib import Path
from typing import Any

from aiohttp import web
from hud_config import ALLOWED_USAGE_INTERVALS_S  # type: ignore[import-not-found]
from state_io import atomic_write_json  # type: ignore[import-not-found]

# Defense-in-depth: even though aiohttp won't put `/` in a path param, we
# explicitly validate the session id format on the DELETE route below so
# nothing under .../sessions/ can ever resolve outside its expected dir.
# Matches UUID-ish ids Claude Code generates plus the test-fixture form
# ("abc-123"). Restrictive enough to make path traversal impossible.
_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")


class HudServer:
    def __init__(self, webview_dir: Path, state_dir: Path | None = None) -> None:
        self._webview_dir = webview_dir
        # state_dir is where the hooks write per-session state. The server
        # only needs it for write-side endpoints (currently just clear-todos).
        # Default to the production location so the iTerm plugin doesn't need
        # to pass it explicitly; tests inject a tmp dir.
        self._state_dir = state_dir or Path("~/.claude/state/hud").expanduser()
        self._subscribers: set[asyncio.Queue[str]] = set()
        self._latest: dict[str, Any] | None = None

        self.app = web.Application()
        self.app["server"] = self  # tests + entry point reach for push() via app dict
        self.app.router.add_get("/", self._index)
        self.app.router.add_get("/events", self._events)
        # User-initiated clear: empties `sessions/<sid>/todos.json` so the
        # HUD card's Todos section drops back to 0/0 within one poll tick.
        # 127.0.0.1-bound listener + strict sid regex = no auth needed.
        self.app.router.add_delete("/sessions/{sid}/todos", self._clear_todos)
        # Cadence selector backing: the strip's "5m ⌄" chip PUTs the chosen
        # usage-poll interval here. Constrained integer -> no injection surface.
        self.app.router.add_put("/config/usage-interval", self._set_usage_interval)
        # Static route after specific routes — order matters for aiohttp.
        self.app.router.add_static("/", self._webview_dir, show_index=False)

        self._runner: web.AppRunner | None = None
        self._site: web.TCPSite | None = None

    async def start(self, host: str = "127.0.0.1", port: int = 0) -> int:
        """Bind and return the actual port (kernel-chosen if port=0)."""
        self._runner = web.AppRunner(self.app)
        await self._runner.setup()
        self._site = web.TCPSite(self._runner, host, port)
        await self._site.start()
        # aiohttp doesn't expose the bound port via a public accessor; reach
        # into the underlying server's socket. This is stable across versions.
        srv = self._site._server
        assert srv is not None and hasattr(srv, "sockets") and srv.sockets
        return int(srv.sockets[0].getsockname()[1])

    async def push(self, snapshot: dict[str, Any] | None) -> None:
        """Broadcast a snapshot to all current subscribers (and remember it)."""
        self._latest = snapshot
        frame = self._frame(snapshot)
        # Iterate over a copy because subscribers may unregister mid-broadcast.
        for q in list(self._subscribers):
            try:
                q.put_nowait(frame)
            except asyncio.QueueFull:
                # Subscriber too slow — drop the frame, they'll catch up
                # on the next push. Better than blocking the producer.
                pass

    async def _index(self, _request: web.Request) -> web.FileResponse:
        return web.FileResponse(self._webview_dir / "index.html")

    async def _events(self, request: web.Request) -> web.StreamResponse:
        resp = web.StreamResponse(
            status=200,
            headers={
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
            },
        )
        await resp.prepare(request)

        # Per-subscriber bounded queue. maxsize=8 absorbs short bursts but
        # bounds memory if a subscriber stalls.
        q: asyncio.Queue[str] = asyncio.Queue(maxsize=8)
        self._subscribers.add(q)
        try:
            # Replay the latest snapshot so a new subscriber sees current
            # state immediately, not "blank until next state change".
            if self._latest is not None:
                await resp.write(self._frame(self._latest).encode())
            while True:
                frame = await q.get()
                await resp.write(frame.encode())
        except (ConnectionResetError, asyncio.CancelledError):
            # Subscriber went away; nothing to do but tear down cleanly.
            pass
        finally:
            self._subscribers.discard(q)
        return resp

    async def _clear_todos(self, request: web.Request) -> web.Response:
        """Empty the todos.json for one session.

        This is the backing for the HUD's per-card "✕" button. We atomic-write
        `{"updated_at": <now>, "todos": []}` so the next poll-loop snapshot
        sees an empty list and renders the card with no rows. The user can
        keep working — the next TaskCreate / TodoWrite seeds a fresh batch.

        Returns:
            204 on success, 400 for a malformed sid, 404 if the session has
            no state on disk (avoid creating ghost session dirs).
        """
        sid = request.match_info["sid"]
        if not _SESSION_ID_RE.match(sid):
            # Don't echo the bad sid back in the body — it ends up in HTTP
            # logs and webview devtools and there's no need to surface it.
            return web.Response(status=400, text="invalid session id")

        session_dir = self._state_dir / "sessions" / sid
        # `sessions/<sid>/` is created by SessionStart hook. If it doesn't
        # exist, there's no live session to clear — refuse so we don't
        # silently invent state the rest of the HUD has no record of.
        if not session_dir.is_dir():
            return web.Response(status=404, text="session not found")

        target = session_dir / "todos.json"
        payload = json.dumps({"updated_at": int(time.time()), "todos": []})
        # Same tmp-then-rename pattern as the hooks (hud_atomic_write).
        # Required: state_reader may be mid-read on the very next poll tick
        # and a torn write would surface as "{not json" → snapshot drops
        # the whole session card.
        tmp = target.with_suffix(".json.tmp")
        try:
            tmp.write_text(payload)
            tmp.replace(target)
        except OSError as e:
            # Cleanup half-written tmp so it doesn't accumulate. The reader's
            # robustness contract already handles missing/corrupt todos.json
            # as "empty", so this failure is observable to the user as
            # "button didn't seem to work" — better than a crash, and they
            # can retry.
            tmp.unlink(missing_ok=True)
            return web.Response(status=500, text=f"write failed: {e!s}")

        return web.Response(status=204)

    async def _set_usage_interval(self, request: web.Request) -> web.Response:
        """Persist the usage-poll interval the user picked in the strip.

        Validates against the single allowed set (hud_config) and atomic-writes
        config.json; the usage fetcher hot-reloads it on its next tick. 400 on
        anything that isn't one of the allowed integers.
        """
        try:
            body = await request.json()
        except (json.JSONDecodeError, ValueError):
            return web.Response(status=400, text="invalid json")
        interval = body.get("interval_s") if isinstance(body, dict) else None
        if (
            not isinstance(interval, int)
            or isinstance(interval, bool)
            or interval not in ALLOWED_USAGE_INTERVALS_S
        ):
            return web.Response(status=400, text="invalid interval")
        atomic_write_json(self._state_dir / "config.json", {"usage_poll_interval_s": interval})
        return web.Response(status=204)

    @staticmethod
    def _frame(snapshot: dict[str, Any] | None) -> str:
        # SSE frame format: "data: <json>\n\n". The double-newline marks the
        # end of an event — the browser fires "message" once it sees it.
        return f"data: {json.dumps(snapshot)}\n\n"
