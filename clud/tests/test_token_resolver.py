"""token_resolver: locate the Claude Code OAuth access token locally.

Order: env CLAUDE_CODE_OAUTH_TOKEN -> ~/.claude/.credentials.json -> macOS
Keychain. The raw token is NEVER returned on a failure path and NEVER logged;
the result carries only token-present-or-not, the source, and a reason.
"""

from __future__ import annotations

import json
from pathlib import Path

from token_resolver import resolve_token


def test_env_wins(tmp_path: Path) -> None:
    res = resolve_token(
        env={"CLAUDE_CODE_OAUTH_TOKEN": "env-tok"},
        credentials_path=tmp_path / "nope.json",
        keychain_reader=lambda _s: None,
    )
    assert res.token == "env-tok"
    assert res.source == "env"
    assert res.reason is None


def test_file_fallback(tmp_path: Path) -> None:
    cred = tmp_path / ".credentials.json"
    cred.write_text(
        json.dumps({"claudeAiOauth": {"accessToken": "file-tok", "expiresAt": 9999999999999}})
    )
    res = resolve_token(env={}, credentials_path=cred, keychain_reader=lambda _s: None, now_ms=1)
    assert res.token == "file-tok"
    assert res.source == "file"


def test_keychain_fallback(tmp_path: Path) -> None:
    blob = json.dumps({"claudeAiOauth": {"accessToken": "kc-tok", "expiresAt": 9999999999999}})
    res = resolve_token(
        env={}, credentials_path=tmp_path / "nope.json", keychain_reader=lambda _s: blob, now_ms=1
    )
    assert res.token == "kc-tok"
    assert res.source == "keychain"


def test_no_token_anywhere(tmp_path: Path) -> None:
    res = resolve_token(
        env={}, credentials_path=tmp_path / "nope.json", keychain_reader=lambda _s: None
    )
    assert res.token is None
    assert res.reason == "no_token"


def test_expired_token_reports_expired_and_hides_token(tmp_path: Path) -> None:
    cred = tmp_path / ".credentials.json"
    # expiresAt in the past (epoch ms). now_ms is well after it.
    cred.write_text(json.dumps({"claudeAiOauth": {"accessToken": "old", "expiresAt": 1000}}))
    res = resolve_token(env={}, credentials_path=cred, keychain_reader=lambda _s: None, now_ms=2000)
    assert res.token is None  # never hand back an expired token
    assert res.reason == "expired"


def test_seconds_valued_expiry_is_treated_as_ms(tmp_path: Path) -> None:
    # A seconds-valued expiry (e.g. 1.8e9) must not be mistaken for "expired"
    # against a ms-valued now. 1_800_000_000 s -> coerced to ms is far future.
    cred = tmp_path / ".credentials.json"
    cred.write_text(
        json.dumps({"claudeAiOauth": {"accessToken": "live", "expiresAt": 1_800_000_000}})
    )
    res = resolve_token(
        env={}, credentials_path=cred, keychain_reader=lambda _s: None, now_ms=1_700_000_000_000
    )
    assert res.token == "live"


def test_corrupt_credentials_falls_through_to_no_token(tmp_path: Path) -> None:
    cred = tmp_path / ".credentials.json"
    cred.write_text("{not json")
    res = resolve_token(env={}, credentials_path=cred, keychain_reader=lambda _s: None)
    assert res.token is None
    assert res.reason == "no_token"
