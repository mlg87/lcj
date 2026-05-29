"""UsageFetcher: token -> GET oauth/usage -> normalize -> write usage.json.

The HTTP layer and token resolver are injected so the whole fetch is testable
offline. Every failure mode writes an ok:false usage.json with a reason; the
token value is never written into the file.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from token_resolver import TokenResult
from usage_fetcher import UsageFetcher, detect_claude_version

_GOOD_BODY = json.dumps(
    {
        "five_hour": {"utilization": 52.4, "resets_at": "2026-05-28T07:50:00+00:00"},
        "seven_day": {"utilization": 22.0, "resets_at": "2026-05-29T19:00:00+00:00"},
        "seven_day_opus": None,
    }
)


def _fetcher(tmp_path: Path, *, token: TokenResult, http: Any) -> UsageFetcher:
    return UsageFetcher(
        tmp_path,
        http_get=http,
        token_fn=lambda: token,
        user_agent="claude-code/test",
        clock=lambda: 1000.0,
    )


def _read_usage(tmp_path: Path) -> dict[str, Any]:
    return json.loads((tmp_path / "usage.json").read_text())


async def test_happy_path_writes_normalized_usage(tmp_path: Path) -> None:
    async def http(url: str, headers: dict[str, str]) -> tuple[int, str]:
        assert headers["Authorization"] == "Bearer good-tok"
        assert headers["anthropic-beta"] == "oauth-2025-04-20"
        assert headers["User-Agent"] == "claude-code/test"
        return 200, _GOOD_BODY

    f = _fetcher(tmp_path, token=TokenResult("good-tok", "env", None), http=http)
    await f.fetch_once()

    doc = _read_usage(tmp_path)
    assert doc["ok"] is True
    assert doc["five_hour"]["utilization"] == 52  # rounded + clamped int
    assert doc["five_hour"]["resets_at"] == "2026-05-28T07:50:00+00:00"
    assert doc["seven_day"]["utilization"] == 22
    assert isinstance(doc["updated_at"], int)
    # The token must never leak into the state file.
    assert "good-tok" not in (tmp_path / "usage.json").read_text()


async def test_no_token_writes_unavailable(tmp_path: Path) -> None:
    async def http(url: str, headers: dict[str, str]) -> tuple[int, str]:
        raise AssertionError("must not call HTTP without a token")

    f = _fetcher(tmp_path, token=TokenResult(None, "none", "no_token"), http=http)
    await f.fetch_once()
    doc = _read_usage(tmp_path)
    assert doc == {"ok": False, "reason": "no_token", "updated_at": doc["updated_at"]}


async def test_http_401_writes_unavailable(tmp_path: Path) -> None:
    async def http(url: str, headers: dict[str, str]) -> tuple[int, str]:
        return 401, "unauthorized"

    f = _fetcher(tmp_path, token=TokenResult("t", "env", None), http=http)
    await f.fetch_once()
    assert _read_usage(tmp_path)["reason"] == "http_401"
    assert _read_usage(tmp_path)["ok"] is False


async def test_http_500_writes_unavailable(tmp_path: Path) -> None:
    async def http(url: str, headers: dict[str, str]) -> tuple[int, str]:
        return 503, "nope"

    f = _fetcher(tmp_path, token=TokenResult("t", "env", None), http=http)
    await f.fetch_once()
    assert _read_usage(tmp_path)["reason"] == "http_5xx"


async def test_network_error_writes_unavailable(tmp_path: Path) -> None:
    async def http(url: str, headers: dict[str, str]) -> tuple[int, str]:
        raise OSError("connection refused")

    f = _fetcher(tmp_path, token=TokenResult("t", "env", None), http=http)
    await f.fetch_once()
    assert _read_usage(tmp_path)["reason"] == "network"


async def test_garbage_shape_writes_bad_shape(tmp_path: Path) -> None:
    async def http(url: str, headers: dict[str, str]) -> tuple[int, str]:
        return 200, json.dumps({"unexpected": "shape"})

    f = _fetcher(tmp_path, token=TokenResult("t", "env", None), http=http)
    await f.fetch_once()
    assert _read_usage(tmp_path)["reason"] == "bad_shape"


async def test_missing_seven_day_keeps_five_hour(tmp_path: Path) -> None:
    async def http(url: str, headers: dict[str, str]) -> tuple[int, str]:
        return 200, json.dumps({"five_hour": {"utilization": 10, "resets_at": None}})

    f = _fetcher(tmp_path, token=TokenResult("t", "env", None), http=http)
    await f.fetch_once()
    doc = _read_usage(tmp_path)
    assert doc["ok"] is True
    assert doc["five_hour"]["utilization"] == 10
    assert "seven_day" not in doc


async def test_maybe_fetch_honors_configured_interval(tmp_path: Path) -> None:
    calls = {"n": 0}

    async def http(url: str, headers: dict[str, str]) -> tuple[int, str]:
        calls["n"] += 1
        return 200, _GOOD_BODY

    # config.json = 60s. Drive the clock manually.
    (tmp_path / "config.json").write_text(json.dumps({"usage_poll_interval_s": 60}))
    now = {"t": 1000.0}
    f = UsageFetcher(
        tmp_path,
        http_get=http,
        token_fn=lambda: TokenResult("t", "env", None),
        user_agent="claude-code/test",
        clock=lambda: now["t"],
    )
    await f.fetch_once()  # seed last_fetch_at
    f.mark_fetched()
    now["t"] = 1030.0  # +30s < 60s -> not due
    assert await f._maybe_fetch() is False
    now["t"] = 1061.0  # +61s >= 60s -> due
    assert await f._maybe_fetch() is True
    assert calls["n"] == 2  # one from fetch_once seed + one from the due tick


def test_detect_version_parses_first_token() -> None:
    assert detect_claude_version(runner=lambda: "2.1.156 (Claude Code)") == "claude-code/2.1.156"


def test_detect_version_falls_back_when_unavailable() -> None:
    assert detect_claude_version(runner=lambda: None) == "claude-code/2.1.156"
