"""Resolve the Claude Code OAuth access token from where Claude Code stores it.

WHY local token (not a claude.ai cookie): clud runs inside the Claude Code
environment; reusing the same token Claude Code's own /usage uses needs zero
manual setup. See the spec's compliance note — this is an undocumented,
best-effort path; every failure degrades to "usage unavailable".

SECURITY: the raw token value is never logged and never returned on a failure
path. TokenResult carries only whether a (live) token was found, its source,
and a machine reason — safe to log/diagnose.
"""

from __future__ import annotations

import json
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

KEYCHAIN_SERVICE = "Claude Code-credentials"
CREDENTIALS_PATH = Path("~/.claude/.credentials.json").expanduser()
_MS_THRESHOLD = 1_000_000_000_000  # values below this look like epoch seconds
# Lower bound for the seconds-coercion: a *plausible* epoch-seconds timestamp is
# >= 1e9 s (year 2001). Only values in [1e9, 1e12) are coerced s->ms; anything
# smaller (e.g. a tiny test/sentinel value) is taken as already-ms so a clearly
# past timestamp still reads as expired instead of being inflated into the future.
_SECONDS_FLOOR = 1_000_000_000


@dataclass(frozen=True)
class TokenResult:
    token: str | None
    source: str  # "env" | "file" | "keychain" | "none"
    reason: str | None  # None on success; "no_token" | "expired"


def _read_keychain(service: str) -> str | None:
    """Read a generic-password value from the macOS login Keychain, or None.

    First access of an item another app created may prompt the user for
    authorization (one-time "Always Allow"); a denial / missing item / any
    error just yields None → usage degrades to unavailable, never crashes.
    """
    try:
        proc = subprocess.run(
            ["security", "find-generic-password", "-s", service, "-w"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def _parse_oauth_blob(text: str) -> tuple[str | None, int | None]:
    """Extract (accessToken, expiresAt_ms) from a credentials JSON blob.

    Shape: {"claudeAiOauth": {"accessToken": "...", "expiresAt": <epoch ms>}}.
    Returns (None, None) for any malformed input.
    """
    try:
        doc = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return None, None
    oauth = doc.get("claudeAiOauth") if isinstance(doc, dict) else None
    if not isinstance(oauth, dict):
        return None, None
    token = oauth.get("accessToken")
    expires = oauth.get("expiresAt")
    token = token if isinstance(token, str) and token else None
    expires_ms: int | None = None
    if isinstance(expires, (int, float)) and not isinstance(expires, bool):
        expires_ms = int(expires)
        # Guard a seconds-valued field so we never false-flag a live token, but
        # only when the value is a plausible epoch-seconds timestamp ([1e9, 1e12)).
        if _SECONDS_FLOOR <= expires_ms < _MS_THRESHOLD:
            expires_ms *= 1000
    return token, expires_ms


def resolve_token(
    *,
    env: dict[str, str] | None = None,
    credentials_path: Path | None = None,
    keychain_reader: Callable[[str], str | None] | None = None,
    now_ms: int | None = None,
) -> TokenResult:
    """Resolve a live OAuth token, or a TokenResult explaining why not.

    Re-call this every fetch: a token Claude Code rotates on disk is picked
    up automatically. The seams (env / credentials_path / keychain_reader /
    now_ms) are injected so the resolver is fully unit-testable offline.
    """
    import os

    env = env if env is not None else dict(os.environ)
    credentials_path = credentials_path or CREDENTIALS_PATH
    keychain_reader = keychain_reader or _read_keychain
    now_ms = now_ms if now_ms is not None else int(time.time() * 1000)

    env_tok = env.get("CLAUDE_CODE_OAUTH_TOKEN")
    if env_tok:
        return TokenResult(token=env_tok, source="env", reason=None)

    token: str | None = None
    expires_ms: int | None = None
    source = "none"
    try:
        token, expires_ms = _parse_oauth_blob(credentials_path.read_text())
        if token is not None:
            source = "file"
    except (FileNotFoundError, OSError):
        pass

    if token is None:
        blob = keychain_reader(KEYCHAIN_SERVICE)
        if blob:
            token, expires_ms = _parse_oauth_blob(blob)
            if token is not None:
                source = "keychain"

    if token is None:
        return TokenResult(token=None, source="none", reason="no_token")
    if expires_ms is not None and expires_ms <= now_ms:
        return TokenResult(token=None, source=source, reason="expired")
    return TokenResult(token=token, source=source, reason=None)
