"""Atomic JSON state writes for the plugin-side writers (usage/status fetchers,
config endpoint).

Mirrors the hooks' `hud_atomic_write` (clud/hooks/lib.sh): write a sibling
tmp file in the destination directory, then rename over the target. Same
filesystem → atomic rename → the StateReader never observes a torn write.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any


def atomic_write_json(dest: Path, obj: Any) -> None:
    """Serialize `obj` to `dest` atomically. Creates parent dirs as needed.

    Cleans up the tmp file if the rename never happens (e.g. serialization
    raised), so a failed write can't leave .tmp stragglers the reader's dir
    listing would find confusing.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(dest.parent), prefix=".tmp.", suffix=".json")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        tmp.replace(dest)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
