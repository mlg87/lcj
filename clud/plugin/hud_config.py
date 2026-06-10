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
import plistlib
from pathlib import Path

# macOS stores the Date & Time "24-Hour Time" toggle as an ICU override in
# the user's GlobalPreferences, not in the locale itself.
GLOBAL_PREFS_PLIST = Path("~/Library/Preferences/.GlobalPreferences.plist").expanduser()

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


def read_system_hour_cycle(plist_path: Path = GLOBAL_PREFS_PLIST) -> str | None:
    """Resolve the macOS 12/24-hour override: "h23", "h12", or None.

    Browser engines deliberately hide OS-level time-format overrides from web
    content (it's a fingerprinting surface), so the webview's Intl only sees
    the raw locale default — wrong on e.g. an en_US Mac with "24-Hour Time"
    enabled. The plugin process reads the override here and ships it to the
    webview via the snapshot config (PR #17 follow-up). None means "no
    override": let the locale default stand. 24h wins if both keys are
    somehow set, so a stale 12h leftover can't downgrade an explicit choice.
    Never raises — a missing/corrupt plist is just "no override".
    """
    try:
        with plist_path.open("rb") as f:
            prefs = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None
    if not isinstance(prefs, dict):
        return None
    if prefs.get("AppleICUForce24HourTime"):
        return "h23"
    if prefs.get("AppleICUForce12HourTime"):
        return "h12"
    return None
