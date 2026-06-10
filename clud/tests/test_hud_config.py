"""hud_config: the single source of truth for the allowed usage-poll intervals.

Shared by the usage fetcher (cadence), the reader (snapshot config), and the
server (PUT validation) so the allowed set is defined exactly once.
"""

from __future__ import annotations

import json
import plistlib
from pathlib import Path

import pytest
from hud_config import (
    ALLOWED_USAGE_INTERVALS_S,
    DEFAULT_USAGE_INTERVAL_S,
    normalize_interval,
    read_system_hour_cycle,
    read_usage_interval,
)


def test_allowed_set_matches_the_ui_menu() -> None:
    assert ALLOWED_USAGE_INTERVALS_S == (60, 120, 300, 600, 900, 1800)
    assert DEFAULT_USAGE_INTERVAL_S == 300


@pytest.mark.parametrize("value", [60, 120, 300, 600, 900, 1800])
def test_normalize_passes_allowed_values(value: int) -> None:
    assert normalize_interval(value) == value


@pytest.mark.parametrize("value", [0, 30, 301, -60, "300", 300.0, None, True, False])
def test_normalize_rejects_everything_else(value: object) -> None:
    # Includes bool (True == 1 in Python) and float/str look-alikes.
    assert normalize_interval(value) == DEFAULT_USAGE_INTERVAL_S


def test_read_interval_missing_file_defaults(tmp_path: Path) -> None:
    assert read_usage_interval(tmp_path) == DEFAULT_USAGE_INTERVAL_S


def test_read_interval_valid_file(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text(json.dumps({"usage_poll_interval_s": 60}))
    assert read_usage_interval(tmp_path) == 60


def test_read_interval_corrupt_file_defaults(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text("{not json")
    assert read_usage_interval(tmp_path) == DEFAULT_USAGE_INTERVAL_S


def test_read_interval_out_of_range_defaults(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text(json.dumps({"usage_poll_interval_s": 45}))
    assert read_usage_interval(tmp_path) == DEFAULT_USAGE_INTERVAL_S


# --- read_system_hour_cycle -------------------------------------------------
# The webview's Intl can't see macOS's 12/24-hour override (browsers hide OS
# format customizations from web content), so the plugin resolves it from
# GlobalPreferences and ships it through the snapshot config (PR #17).


def _write_plist(path: Path, doc: dict) -> Path:
    with path.open("wb") as f:
        plistlib.dump(doc, f)
    return path


def test_hour_cycle_force_24h(tmp_path: Path) -> None:
    p = _write_plist(tmp_path / "g.plist", {"AppleICUForce24HourTime": True})
    assert read_system_hour_cycle(p) == "h23"


def test_hour_cycle_force_12h(tmp_path: Path) -> None:
    p = _write_plist(tmp_path / "g.plist", {"AppleICUForce12HourTime": True})
    assert read_system_hour_cycle(p) == "h12"


def test_hour_cycle_no_override_is_none(tmp_path: Path) -> None:
    p = _write_plist(tmp_path / "g.plist", {"AppleLocale": "en_US"})
    assert read_system_hour_cycle(p) is None


def test_hour_cycle_falsy_overrides_are_none(tmp_path: Path) -> None:
    # macOS writes 0 (rather than deleting the key) when the user toggles the
    # setting back to the locale default — that's "no override", not "h12".
    p = _write_plist(
        tmp_path / "g.plist",
        {"AppleICUForce24HourTime": False, "AppleICUForce12HourTime": 0},
    )
    assert read_system_hour_cycle(p) is None


def test_hour_cycle_24h_wins_when_both_set(tmp_path: Path) -> None:
    # Shouldn't happen in practice; prefer 24h so a stale 12h leftover can't
    # downgrade an explicit 24h choice.
    p = _write_plist(
        tmp_path / "g.plist",
        {"AppleICUForce24HourTime": True, "AppleICUForce12HourTime": True},
    )
    assert read_system_hour_cycle(p) == "h23"


def test_hour_cycle_missing_file_is_none(tmp_path: Path) -> None:
    assert read_system_hour_cycle(tmp_path / "nope.plist") is None


def test_hour_cycle_corrupt_plist_is_none(tmp_path: Path) -> None:
    p = tmp_path / "g.plist"
    p.write_bytes(b"not a plist")
    assert read_system_hour_cycle(p) is None
