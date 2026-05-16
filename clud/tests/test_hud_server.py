"""HudServer: serves /, /events (SSE), and pushes snapshots.

WHY SSE not WebSocket: server->client one-way push is exactly what we need;
SSE is half the code, native to the browser (EventSource), and auto-reconnects.

The "initial snapshot on connect" behavior is deliberate — without it, a
just-opened toolbelt would be blank until the next state change, which
might be a long wait if Claude is idle.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from aiohttp.test_utils import TestClient, TestServer

from plugin.hud_server import HudServer


@pytest.fixture
async def server_client(tmp_path: Path) -> TestClient:
    webview_dir = tmp_path / "webview"
    webview_dir.mkdir()
    (webview_dir / "index.html").write_text("<h1>HUD</h1>")
    (webview_dir / "hud.css").write_text("body { color: white; }")

    server = HudServer(webview_dir=webview_dir)
    test_server = TestServer(server.app)
    client = TestClient(test_server)
    await client.start_server()
    yield client
    await client.close()


async def test_serves_index(server_client: TestClient) -> None:
    resp = await server_client.get("/")
    assert resp.status == 200
    body = await resp.text()
    assert "HUD" in body


async def test_serves_static_assets(server_client: TestClient) -> None:
    resp = await server_client.get("/hud.css")
    assert resp.status == 200
    assert "color: white" in await resp.text()


async def test_sse_receives_pushed_snapshot(server_client: TestClient) -> None:
    snapshot = {"tty": "/dev/ttys003", "session": {"id": "abc"}, "todos": []}

    async with server_client.get("/events") as resp:
        assert resp.status == 200
        assert resp.headers["Content-Type"].startswith("text/event-stream")

        async def pusher() -> None:
            await asyncio.sleep(0.05)
            await server_client.app["server"].push(snapshot)

        push_task = asyncio.create_task(pusher())

        line = await asyncio.wait_for(resp.content.readline(), timeout=2.0)
        assert line.startswith(b"data: ")
        payload = json.loads(line[len(b"data: ") :].decode().rstrip())
        assert payload == snapshot

        await push_task


async def test_sse_pushes_initial_snapshot_on_connect(server_client: TestClient) -> None:
    snapshot = {"tty": "/dev/ttys999", "session": None, "todos": []}
    await server_client.app["server"].push(snapshot)

    async with server_client.get("/events") as resp:
        line = await asyncio.wait_for(resp.content.readline(), timeout=2.0)
        payload = json.loads(line[len(b"data: ") :].decode().rstrip())
        assert payload == snapshot
