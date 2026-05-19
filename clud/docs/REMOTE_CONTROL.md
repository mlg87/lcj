# HUD Remote-Control Indicator — Writer Contract

The HUD shows a `◉` indicator on a session card when remote-control is
enabled for that session. The HUD itself does not decide what counts as
remote-control — it only renders whatever writer opts in by creating a
small JSON file. This doc is for **future writers** (a `/schedule`
integration, an MCP server, a `clud remote-control` CLI, anything that
makes a Claude session reachable from outside the local terminal).

Tracking: [issue #6](https://github.com/mlg87/lcj/issues/6).

## The file

**Path:** `~/.claude/state/hud/sessions/<session_id>/remote.json`

`<session_id>` is the Claude Code session UUID — the same one used by
the rest of the HUD state files (`meta.json`, `todos.json`, `current.json`).
The HUD's hooks create the parent directory on `SessionStart`; writers
only need to create the file.

## Schema

```json
{
  "channel": "schedule",
  "last_remote_at": 1779200000
}
```

Both fields are optional. Unknown keys are ignored (additive evolution
is safe).

| Field | Type | Meaning | Constraints |
|---|---|---|---|
| `channel` | string | Short label shown in the indicator tooltip — e.g. `schedule`, `mcp`, `cron` | Trimmed, non-empty, ≤32 chars. Anything else is dropped. |
| `last_remote_at` | int | Epoch seconds of the most recent remote interaction | Non-negative; booleans rejected. |

## Lifecycle

- **File present** → indicator on for the next snapshot tick (≤200 ms).
- **File deleted** → indicator off for the next snapshot tick.
- **There is no `enabled: false` form.** Deletion is the off-switch.
  This keeps writers honest: a stale "disabled" file cannot lie
  indefinitely after a crash.
- On `SessionEnd`, the entire session directory is cleaned up, so the
  file vanishes automatically — writers do not need to handle session
  shutdown.

## How to write the file

**From a bash hook** — use the existing helper in `clud/hooks/lib.sh`:

```bash
hud_atomic_write "$(hud_state_dir)/sessions/$session_id/remote.json" \
    "$(jq -n --arg ch schedule --argjson ts "$(date +%s)" \
        '{channel: $ch, last_remote_at: $ts}')"
```

**From any other process** — use tmp + `rename(2)` on the same filesystem:

```python
import json, os, tempfile
from pathlib import Path

target = Path.home() / ".claude/state/hud/sessions" / sid / "remote.json"
target.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=str(target.parent), suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump({"channel": "schedule", "last_remote_at": int(time.time())}, f)
os.rename(tmp, target)  # atomic on the same filesystem
```

## Security

- **Never** put secrets, webhook URLs, tokens, or any credential-shaped
  string in this file. The HUD renders the `channel` value into a tooltip
  — anything you write here can end up in a screenshot.
- The HUD enforces a ≤32-char ceiling on `channel` as defense in depth,
  but writers should treat it as a hard cap, not a fallback.
- Do not write content from untrusted input. `channel` should be a
  fixed-set label chosen by the writer ("schedule", "mcp", etc.), not a
  passthrough of any user-controlled value.

## Reader implementation

The HUD reads this file in `clud/plugin/state_reader.py` via
`StateReader._normalize_remote()` and surfaces it on the snapshot as
`session.remote_control`. Tests live in `clud/tests/test_state_reader.py`
under the `test_remote_control_*` names.
