"""Single source of truth for the usage-fetch cadence config (issue: usage strip).

The allowed interval set is referenced in three places — the usage fetcher's
loop, the StateReader snapshot, and the server's PUT validation — and the
webview menu mirrors it. Defining it once here keeps them from drifting.

The config lives at <state_dir>/config.json as {"usage_poll_interval_s": <int>}.
Any unexpected value (missing file, corrupt JSON, out-of-range, wrong type)
normalizes to the 5-minute default — a bad config must never break fetching.
"""

from __future__ import annotations

import json
from pathlib import Path

# WHY these six values: the user-facing menu is 1/2/5/10/15/30 minutes.
ALLOWED_USAGE_INTERVALS_S: tuple[int, ...] = (60, 120, 300, 600, 900, 1800)
DEFAULT_USAGE_INTERVAL_S = 300  # 5m — matches ClaudeUsageBar's default cadence.


def normalize_interval(value: object) -> int:
    """Snap an arbitrary value to an allowed interval, else the default.

    Rejects bool explicitly (`isinstance(True, int)` is True in Python) so a
    stray `true` in config.json can't be read as 1 second.
    """
    if isinstance(value, bool):
        return DEFAULT_USAGE_INTERVAL_S
    if isinstance(value, int) and value in ALLOWED_USAGE_INTERVALS_S:
        return value
    return DEFAULT_USAGE_INTERVAL_S


def read_usage_interval(state_dir: Path) -> int:
    """Read + normalize the configured usage-poll interval (seconds).

    Never raises on disk surprises — same robustness contract as StateReader.
    """
    try:
        doc = json.loads((state_dir / "config.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return DEFAULT_USAGE_INTERVAL_S
    if not isinstance(doc, dict):
        return DEFAULT_USAGE_INTERVAL_S
    return normalize_interval(doc.get("usage_poll_interval_s"))
