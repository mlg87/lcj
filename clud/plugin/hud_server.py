"""Tiny aiohttp app: serves the webview and pushes snapshots over SSE.

Architecture role:
    iTerm's `async_register_web_view_tool` only takes a URL — the toolbelt
    panel is just a webview pointed at it. So we host the HUD ourselves
    on a 127.0.0.1-bound HTTP server with a kernel-chosen random port.

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
from pathlib import Path
from typing import Any

from aiohttp import web


class HudServer:
    def __init__(self, webview_dir: Path) -> None:
        self._webview_dir = webview_dir
        self._subscribers: set[asyncio.Queue[str]] = set()
        self._latest: dict[str, Any] | None = None

        self.app = web.Application()
        self.app["server"] = self  # tests + entry point reach for push() via app dict
        self.app.router.add_get("/", self._index)
        self.app.router.add_get("/events", self._events)
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

    @staticmethod
    def _frame(snapshot: dict[str, Any] | None) -> str:
        # SSE frame format: "data: <json>\n\n". The double-newline marks the
        # end of an event — the browser fires "message" once it sees it.
        return f"data: {json.dumps(snapshot)}\n\n"
