"""Timer-driven writer for usage.json — the 5h/weekly Claude usage bars.

Calls the same endpoint Claude Code's own /usage uses
(api.anthropic.com/api/oauth/usage) with the local OAuth token. `utilization`
comes back already as a 0-100 percent. Every failure mode degrades to an
ok:false usage.json with a machine reason — it never raises into the poll
loop and never writes the token to disk.

Cadence is user-configurable (config.json, 1/2/5/10/15/30m). The loop wakes
on a short tick and fetches when the configured interval has elapsed, so an
interval change applies within ~TICK_S with no restart and no coupling to the
server (which only writes config.json).
"""

from __future__ import annotations

import asyncio
import json
import logging
import subprocess
import time
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

import aiohttp
from hud_config import read_usage_interval  # type: ignore[import-not-found]
from ssl_support import default_ssl_context  # type: ignore[import-not-found]
from state_io import atomic_write_json  # type: ignore[import-not-found]
from token_resolver import TokenResult, resolve_token  # type: ignore[import-not-found]

log = logging.getLogger("claude_hud.usage")

_FALLBACK_VERSION = "claude-code/2.1.156"

HttpGet = Callable[[str, dict[str, str]], Awaitable[tuple[int, str]]]


def _run_claude_version() -> str | None:
    try:
        proc = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return proc.stdout if proc.returncode == 0 else None


def detect_claude_version(runner: Callable[[], str | None] | None = None) -> str:
    """Return the `claude-code/<version>` User-Agent the endpoint requires.

    WHY this UA matters: without `claude-code/<version>` the request is routed
    to an aggressively rate-limited bucket that returns persistent 429s. We
    parse the first whitespace token of `claude --version` (e.g.
    "2.1.156 (Claude Code)" -> "2.1.156") and fall back to a known-good
    constant if the CLI isn't on PATH.
    """
    runner = runner or _run_claude_version
    raw = runner()
    if raw and raw.strip():
        first = raw.strip().split()[0]
        if first:
            return f"claude-code/{first}"
    return _FALLBACK_VERSION


async def _default_http_get(url: str, headers: dict[str, str]) -> tuple[int, str]:
    timeout = aiohttp.ClientTimeout(total=15)
    # certifi-backed TLS verification — iterm2env's Python has no CA store of
    # its own (see ssl_support). Without this the GET raises and we'd write
    # the ok:false {"reason":"network"} usage.json forever.
    connector = aiohttp.TCPConnector(ssl=default_ssl_context())
    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        async with session.get(url, headers=headers) as resp:
            return resp.status, await resp.text()


class UsageFetcher:
    URL = "https://api.anthropic.com/api/oauth/usage"
    BETA = "oauth-2025-04-20"
    TICK_S = 15  # how often the loop re-checks the configured interval

    def __init__(
        self,
        state_dir: Path,
        *,
        http_get: HttpGet | None = None,
        token_fn: Callable[[], TokenResult] | None = None,
        user_agent: str | None = None,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self._dir = state_dir
        self._http_get = http_get or _default_http_get
        self._token_fn = token_fn or resolve_token
        self._ua = user_agent or detect_claude_version()
        self._clock = clock or time.time
        self._last_fetch_at = 0.0

    async def run(self) -> None:
        """Background loop. Never returns; never lets an exception escape."""
        await self._safe_fetch()
        while True:
            await asyncio.sleep(self.TICK_S)
            await self._maybe_fetch()

    async def _maybe_fetch(self) -> bool:
        """Fetch iff the configured interval has elapsed since the last fetch."""
        interval = read_usage_interval(self._dir)
        if (self._clock() - self._last_fetch_at) >= interval:
            await self._safe_fetch()
            return True
        return False

    def mark_fetched(self) -> None:
        self._last_fetch_at = self._clock()

    async def _safe_fetch(self) -> None:
        try:
            await self.fetch_once()
        except Exception:
            # Belt-and-suspenders: fetch_once already maps known failures to
            # ok:false; this catches anything truly unexpected so the loop
            # survives. Matches claude_hud.py's poll-loop discipline.
            log.exception("usage fetch failed; continuing")
        self.mark_fetched()

    async def fetch_once(self) -> None:
        tr = self._token_fn()
        if tr.token is None:
            self._write({"ok": False, "reason": tr.reason or "no_token"})
            return
        headers = {
            "Authorization": f"Bearer {tr.token}",
            "anthropic-beta": self.BETA,
            "User-Agent": self._ua,
        }
        try:
            status, body = await self._http_get(self.URL, headers)
        except Exception:
            self._write({"ok": False, "reason": "network"})
            return
        if status in (401, 403):
            self._write({"ok": False, "reason": "http_401"})
            return
        if status != 200:
            self._write({"ok": False, "reason": "http_5xx"})
            return
        parsed = self._parse(body)
        if parsed is None:
            self._write({"ok": False, "reason": "bad_shape"})
            return
        self._write({"ok": True, **parsed})

    @staticmethod
    def _parse(body: str) -> dict[str, Any] | None:
        try:
            doc = json.loads(body)
        except (json.JSONDecodeError, ValueError):
            return None
        if not isinstance(doc, dict):
            return None
        out: dict[str, Any] = {}
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
        # five_hour is the headline bar; its absence means the response isn't
        # the shape we expect -> bad_shape (caller writes ok:false).
        if "five_hour" not in out:
            return None
        return out

    def _write(self, payload: dict[str, Any]) -> None:
        payload["updated_at"] = int(self._clock())
        atomic_write_json(self._dir / "usage.json", payload)
