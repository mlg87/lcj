"""Timer-driven writer for status.json — the service-status indicator.

Reads the public Atlassian Statuspage JSON at status.claude.com
(status.anthropic.com 302-redirects there). No auth. ETag-conditional so a
304 is cheap and skips the write entirely. Any failure writes an
ok:false / indicator:"unknown" file so the strip shows "unknown" — never a
misleading green — when we can't reach the status page.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

import aiohttp
from ssl_support import default_ssl_context  # type: ignore[import-not-found]
from state_io import atomic_write_json  # type: ignore[import-not-found]

log = logging.getLogger("claude_hud.status")

# http_get returns (status_code, response_headers, body_text).
HttpGet = Callable[[str, "str | None"], Awaitable[tuple[int, dict[str, str], str]]]


async def _default_http_get(url: str, etag: str | None) -> tuple[int, dict[str, str], str]:
    headers = {"If-None-Match": etag} if etag else {}
    timeout = aiohttp.ClientTimeout(total=15)
    # certifi-backed TLS verification — iterm2env's Python has no CA store of
    # its own (see ssl_support). Without this the GET raises and we'd write
    # the "Status unavailable" ok:false file forever.
    connector = aiohttp.TCPConnector(ssl=default_ssl_context())
    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        async with session.get(url, headers=headers) as resp:
            return resp.status, dict(resp.headers), await resp.text()


class StatusFetcher:
    URL = "https://status.claude.com/api/v2/summary.json"
    POLL_S = 60

    def __init__(
        self,
        state_dir: Path,
        *,
        http_get: HttpGet | None = None,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self._dir = state_dir
        self._http_get = http_get or _default_http_get
        self._clock = clock or time.time
        self._etag: str | None = None

    async def run(self) -> None:
        await self._safe_fetch()
        while True:
            await asyncio.sleep(self.POLL_S)
            await self._safe_fetch()

    async def _safe_fetch(self) -> None:
        try:
            await self.fetch_once()
        except Exception:
            log.exception("status fetch failed; continuing")

    async def fetch_once(self) -> None:
        try:
            status, headers, body = await self._http_get(self.URL, self._etag)
        except Exception:
            self._write_unknown()
            return
        if status == 304:
            return  # unchanged — leave status.json as-is, no snapshot churn
        if status != 200:
            self._write_unknown()
            return
        parsed = self._parse(body)
        if parsed is None:
            self._write_unknown()
            return
        # Only adopt the new ETag once we have a usable 200 body.
        self._etag = headers.get("ETag") or headers.get("etag")
        self._write({"ok": True, **parsed})

    @staticmethod
    def _parse(body: str) -> dict[str, Any] | None:
        try:
            doc = json.loads(body)
        except (json.JSONDecodeError, ValueError):
            return None
        if not isinstance(doc, dict):
            return None
        status = doc.get("status")
        if not isinstance(status, dict):
            return None
        indicator = status.get("indicator")
        description = status.get("description")
        incident: dict[str, Any] | None = None
        incidents = doc.get("incidents")
        if isinstance(incidents, list) and incidents and isinstance(incidents[0], dict):
            first = incidents[0]
            body_text: str | None = None
            updates = first.get("incident_updates")
            if isinstance(updates, list) and updates and isinstance(updates[0], dict):
                b = updates[0].get("body")
                body_text = b if isinstance(b, str) else None
            incident = {
                "name": _as_str(first.get("name")),
                "status": _as_str(first.get("status")),
                "impact": _as_str(first.get("impact")),
                "body": body_text,
                "updated_at": _as_str(first.get("updated_at")),
            }
        return {
            "indicator": indicator if isinstance(indicator, str) else "unknown",
            "description": description if isinstance(description, str) else "",
            "incident": incident,
        }

    def _write(self, payload: dict[str, Any]) -> None:
        payload["updated_at"] = int(self._clock())
        atomic_write_json(self._dir / "status.json", payload)

    def _write_unknown(self) -> None:
        self._write(
            {
                "ok": False,
                "indicator": "unknown",
                "description": "Status unavailable",
                "incident": None,
            }
        )


def _as_str(value: object) -> str | None:
    return value if isinstance(value, str) else None
