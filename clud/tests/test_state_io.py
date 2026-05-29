"""state_io.atomic_write_json: tmp-then-rename so readers never see torn writes.

The fetchers and the server's config endpoint all write state files the
200ms poll loop may read on the very next tick. POSIX rename(2) on the same
filesystem is atomic, so a sibling .tmp + rename guarantees the reader sees
either the old file or the whole new one — never a half-written one.
"""

from __future__ import annotations

import json
from pathlib import Path

from state_io import atomic_write_json


def test_writes_json(tmp_path: Path) -> None:
    dest = tmp_path / "usage.json"
    atomic_write_json(dest, {"ok": True, "n": 1})
    assert json.loads(dest.read_text()) == {"ok": True, "n": 1}


def test_overwrites_existing(tmp_path: Path) -> None:
    dest = tmp_path / "usage.json"
    dest.write_text('{"old": true}')
    atomic_write_json(dest, {"new": True})
    assert json.loads(dest.read_text()) == {"new": True}


def test_creates_parent_dirs(tmp_path: Path) -> None:
    dest = tmp_path / "nested" / "dir" / "status.json"
    atomic_write_json(dest, {"ok": True})
    assert json.loads(dest.read_text()) == {"ok": True}


def test_leaves_no_tmp_straggler(tmp_path: Path) -> None:
    dest = tmp_path / "config.json"
    atomic_write_json(dest, {"usage_poll_interval_s": 60})
    stragglers = [p.name for p in tmp_path.iterdir() if p.name.startswith(".tmp")]
    assert stragglers == []
    assert sorted(p.name for p in tmp_path.iterdir()) == ["config.json"]
