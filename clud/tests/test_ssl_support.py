"""ssl_support: a verifying SSL context pinned to certifi's CA bundle.

Regression coverage for the "usage unavailable" / "Status unavailable" strip
bug: iTerm's bundled Python (iterm2env) ships no populated CA store, so
aiohttp's default SSL context failed every HTTPS handshake with
CERTIFICATE_VERIFY_FAILED and BOTH fetchers silently degraded to ok:false.
The fix pins verification to certifi; these tests guard that wiring.
"""

from __future__ import annotations

import ssl

import certifi
from ssl_support import default_ssl_context


def test_returns_verifying_context() -> None:
    ctx = default_ssl_context()
    assert isinstance(ctx, ssl.SSLContext)
    # The whole point is verification — a context that doesn't verify would
    # "work" against the bug by silently trusting everything. Reject that.
    assert ctx.verify_mode == ssl.CERT_REQUIRED
    assert ctx.check_hostname is True


def test_loads_certifi_ca_bundle() -> None:
    # Without trusted roots the handshake fails; assert the bundle actually
    # loaded so an empty-store regression is caught offline.
    assert default_ssl_context().get_ca_certs(), "expected CA certs from certifi bundle"


def test_context_is_cached() -> None:
    # Built once and reused — parsing certifi's bundle on every 15s/60s fetch
    # tick would be wasteful, and an SSLContext is safe to share.
    assert default_ssl_context() is default_ssl_context()


def test_uses_certifi_path() -> None:
    # Pin the source explicitly: the bug was OpenSSL's *default* paths being
    # empty, so the fix must load from certifi.where(), not the default store.
    ctx = ssl.create_default_context(cafile=certifi.where())
    assert ctx.get_ca_certs() == default_ssl_context().get_ca_certs()
