"""Shared pytest fixtures for HUD tests.

The hook-test helper (`run_hook`) invokes the actual bash scripts via
subprocess.run, with HUD_STATE_DIR pointed at a tmp dir. This keeps tests
hermetic without requiring us to reimplement the hook behavior in Python.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
HOOKS_DIR = REPO_ROOT / "hooks"


@pytest.fixture
def state_dir(tmp_path: Path) -> Path:
    """Isolated HUD state directory for the duration of one test."""
    d = tmp_path / "hud"
    d.mkdir()
    return d


def run_hook(name: str, payload: dict[str, Any], state_dir: Path,
             ppid_tty: str = "ttys999") -> subprocess.CompletedProcess[str]:
    """Invoke a hook script with stdin JSON and an isolated state dir.

    `ppid_tty` simulates the value `ps -o tty= -p $PPID` would return for
    Claude. The hook normalizes this to the canonical `/dev/ttys999` form.
    A clean PATH avoids picking up dev-machine shims that don't exist on
    other contributors' machines.
    """
    script = HOOKS_DIR / name
    return subprocess.run(
        ["bash", str(script)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=10,
        env={
            "HUD_STATE_DIR": str(state_dir),
            "HUD_TTY_OVERRIDE": ppid_tty,
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        },
    )
