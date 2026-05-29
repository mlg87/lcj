"""StatusFetcher: GET status.claude.com summary.json -> normalize -> status.json.

ETag-conditional; a 304 leaves the file untouched. Any failure writes an
ok:false / indicator:"unknown" status.json so the strip never shows green on
a failed fetch.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from status_fetcher import StatusFetcher

_OPERATIONAL = json.dumps(
    {"status": {"indicator": "none", "description": "All Systems Operational"}, "incidents": []}
)
_INCIDENT = json.dumps(
    {
        "status": {"indicator": "minor", "description": "Minor Service Outage"},
        "incidents": [
            {
                "name": "Elevated errors on Claude API",
                "status": "investigating",
                "impact": "minor",
                "updated_at": "2026-05-28T19:04:00Z",
                "incident_updates": [
                    {
                        "body": "We are investigating elevated error rates.",
                        "created_at": "2026-05-28T19:04:00Z",
                    },
                    {"body": "older update", "created_at": "2026-05-28T18:00:00Z"},
                ],
            }
        ],
    }
)


def _read_status(tmp_path: Path) -> dict[str, Any]:
    return json.loads((tmp_path / "status.json").read_text())


async def test_operational_writes_none_indicator(tmp_path: Path) -> None:
    async def http(url: str, etag: str | None) -> tuple[int, dict[str, str], str]:
        return 200, {"ETag": "v1"}, _OPERATIONAL

    f = StatusFetcher(tmp_path, http_get=http, clock=lambda: 1000.0)
    await f.fetch_once()
    doc = _read_status(tmp_path)
    assert doc["ok"] is True
    assert doc["indicator"] == "none"
    assert doc["incident"] is None


async def test_active_incident_extracts_latest_update(tmp_path: Path) -> None:
    async def http(url: str, etag: str | None) -> tuple[int, dict[str, str], str]:
        return 200, {"ETag": "v2"}, _INCIDENT

    f = StatusFetcher(tmp_path, http_get=http, clock=lambda: 1000.0)
    await f.fetch_once()
    doc = _read_status(tmp_path)
    assert doc["indicator"] == "minor"
    assert doc["incident"]["name"] == "Elevated errors on Claude API"
    assert doc["incident"]["body"] == "We are investigating elevated error rates."
    assert doc["incident"]["status"] == "investigating"


async def test_304_leaves_file_untouched(tmp_path: Path) -> None:
    # Seed a known file; a 304 must not overwrite it.
    (tmp_path / "status.json").write_text(
        json.dumps({"ok": True, "indicator": "none", "sentinel": 1})
    )

    async def http(url: str, etag: str | None) -> tuple[int, dict[str, str], str]:
        return 304, {}, ""

    f = StatusFetcher(tmp_path, http_get=http, clock=lambda: 1000.0)
    await f.fetch_once()
    assert _read_status(tmp_path)["sentinel"] == 1


async def test_sends_stored_etag_on_next_request(tmp_path: Path) -> None:
    seen: list[str | None] = []

    async def http(url: str, etag: str | None) -> tuple[int, dict[str, str], str]:
        seen.append(etag)
        return 200, {"ETag": "abc"}, _OPERATIONAL

    f = StatusFetcher(tmp_path, http_get=http, clock=lambda: 1000.0)
    await f.fetch_once()  # first: no etag
    await f.fetch_once()  # second: should send "abc"
    assert seen == [None, "abc"]


async def test_network_error_writes_unknown(tmp_path: Path) -> None:
    async def http(url: str, etag: str | None) -> tuple[int, dict[str, str], str]:
        raise OSError("down")

    f = StatusFetcher(tmp_path, http_get=http, clock=lambda: 1000.0)
    await f.fetch_once()
    doc = _read_status(tmp_path)
    assert doc["ok"] is False
    assert doc["indicator"] == "unknown"


async def test_non_200_writes_unknown(tmp_path: Path) -> None:
    async def http(url: str, etag: str | None) -> tuple[int, dict[str, str], str]:
        return 500, {}, "err"

    f = StatusFetcher(tmp_path, http_get=http, clock=lambda: 1000.0)
    await f.fetch_once()
    assert _read_status(tmp_path)["indicator"] == "unknown"
