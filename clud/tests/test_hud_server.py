"""HudServer: serves /, /events (SSE), and pushes snapshots.

WHY SSE not WebSocket: server->client one-way push is exactly what we need;
SSE is half the code, native to the browser (EventSource), and auto-reconnects.

The "initial snapshot on connect" behavior is deliberate — without it, a
just-opened toolbelt would be blank until the next state change, which
might be a long wait if Claude is idle.

The write-side `DELETE /sessions/<sid>/todos` endpoint is the backing for
the HUD's per-card ✕ clear button. Tests for it live below alongside the
read-side coverage.
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
    # state_dir is where the server's write-side endpoint (clear-todos)
    # lands files. Tests pass tmp_path so we never touch the real
    # ~/.claude/state/hud/. The server stashes state_dir on `app["state_dir"]`
    # for tests via the same pattern used for server itself.
    state_dir = tmp_path / "state"
    state_dir.mkdir()

    server = HudServer(webview_dir=webview_dir, state_dir=state_dir)
    server.app["state_dir"] = state_dir
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


# ---------------------------------------------------------------------------
# DELETE /sessions/<sid>/todos — backing for the HUD's per-card ✕ button.


async def test_delete_todos_writes_empty_list(server_client: TestClient) -> None:
    """Happy path: existing session, existing non-empty todos.json, ✕ click
    lands an empty list atomically. The reader's next snapshot will surface
    0/0 todos and the HUD will re-render the card with no rows."""
    state_dir: Path = server_client.app["state_dir"]
    session_dir = state_dir / "sessions" / "abc-123"
    session_dir.mkdir(parents=True)
    (session_dir / "todos.json").write_text(
        '{"updated_at": 1, "todos": [{"id": "1", "content": "A", "status": "completed"}]}'
    )

    resp = await server_client.delete("/sessions/abc-123/todos")
    assert resp.status == 204

    saved = json.loads((session_dir / "todos.json").read_text())
    assert saved["todos"] == []
    assert isinstance(saved["updated_at"], int)


async def test_delete_todos_for_session_with_no_todos_file(server_client: TestClient) -> None:
    """A session that's never run a TaskCreate has no todos.json. The ✕
    button is still a meaningful no-op — we create the empty file so the
    state on disk matches what the user just asked for."""
    state_dir: Path = server_client.app["state_dir"]
    (state_dir / "sessions" / "abc-123").mkdir(parents=True)

    resp = await server_client.delete("/sessions/abc-123/todos")
    assert resp.status == 204

    saved = json.loads((state_dir / "sessions" / "abc-123" / "todos.json").read_text())
    assert saved["todos"] == []


async def test_delete_todos_unknown_session_returns_404(server_client: TestClient) -> None:
    """Refuse to invent state for a session the rest of the HUD has no
    record of — protects against typo / stale-tab requests."""
    resp = await server_client.delete("/sessions/no-such-session/todos")
    assert resp.status == 404


@pytest.mark.parametrize(
    "bad_sid",
    [
        # Path traversal attempts (URL-encoded so aiohttp doesn't reject at routing).
        "..%2Fetc",
        "%2E%2E%2Fetc",
        # Empty
        "%20",
        # Way too long (defensive bound, our regex caps at 128 chars).
        "a" * 200,
        # Other shell/path special chars.
        "a/b",
        "a%5Cb",  # backslash
        "a%00b",  # null byte
    ],
)
async def test_delete_todos_rejects_bad_session_id(server_client: TestClient, bad_sid: str) -> None:
    """Defense-in-depth: even though 127.0.0.1-only, the sid is interpolated
    into a filesystem path, so reject anything that doesn't look like a
    Claude session id."""
    resp = await server_client.delete(f"/sessions/{bad_sid}/todos")
    # 400 from our validator, 404 from aiohttp's router rejecting the path
    # entirely, or 405 when the path matches a different route's pattern
    # but not the DELETE method (e.g. literal `/` in sid expands the path).
    # All three prove the request never reached a filesystem write.
    assert resp.status in (400, 404, 405)


async def test_delete_todos_atomic_no_torn_writes(server_client: TestClient) -> None:
    """The reader's robustness contract assumes torn writes don't happen.
    Verify there's no `.tmp` sidecar left behind after a clear — that would
    mean we wrote to a temp file but failed to rename, which the reader
    would silently swallow but a developer reading the dir might find
    confusing."""
    state_dir: Path = server_client.app["state_dir"]
    session_dir = state_dir / "sessions" / "abc-123"
    session_dir.mkdir(parents=True)

    resp = await server_client.delete("/sessions/abc-123/todos")
    assert resp.status == 204

    stragglers = [p.name for p in session_dir.iterdir() if p.name.startswith(".tmp")]
    assert stragglers == [], f"left tmp files behind: {stragglers}"
    # Final state should be exactly the one expected file.
    assert sorted(p.name for p in session_dir.iterdir()) == ["todos.json"]
