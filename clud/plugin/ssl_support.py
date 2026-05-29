"""Shared TLS setup for the HUD's outbound fetchers (usage + status).

WHY this module exists:
    iTerm provisions its own interpreter under iterm2env/versions/<python>/,
    and install.sh historically installed only `aiohttp` into it. That
    interpreter's OpenSSL has no populated CA store, so aiohttp's *default*
    SSL context (`ssl.create_default_context()` with OpenSSL's default verify
    paths) trusts nothing and every HTTPS handshake dies with
    `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`.

    Both fetchers hit the network (api.anthropic.com for usage,
    status.claude.com for status) and both caught the error and degraded to
    ok:false — which surfaced to the user as the strip's "usage unavailable"
    and "Status unavailable" with no hint as to why.

    Pinning the CA bundle to certifi makes verification independent of
    whatever the bundled interpreter's OpenSSL was compiled to look for.
    certifi is the same bundle pip and requests use, so this is the
    conventional fix rather than disabling verification.
"""

from __future__ import annotations

import ssl
from functools import lru_cache

import certifi


@lru_cache(maxsize=1)
def default_ssl_context() -> ssl.SSLContext:
    """Verifying SSL context whose trust roots come from certifi.

    Cached: an SSLContext is safe to share across concurrent handshakes, and
    re-parsing certifi's bundle on every fetch tick (usage: ≥60s, status: 60s)
    would be wasteful. `create_default_context` keeps hostname checking and
    CERT_REQUIRED on — we are fixing *where the roots come from*, not loosening
    verification.
    """
    return ssl.create_default_context(cafile=certifi.where())
