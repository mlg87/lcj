"""hud_config: the single source of truth for the allowed usage-poll intervals.

Shared by the usage fetcher (cadence), the reader (snapshot config), and the
server (PUT validation) so the allowed set is defined exactly once.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from hud_config import (
    ALLOWED_USAGE_INTERVALS_S,
    DEFAULT_USAGE_INTERVAL_S,
    normalize_interval,
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
