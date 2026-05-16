# Claude HUD — Design

**Status:** Draft
**Author:** Mason Goetz (with Claude)
**Date:** 2026-05-15

## Summary

A toolbelt-resident HUD for iTerm2 that mirrors the live state of Claude Code sessions — current todos, currently running tool, model, project — in a sidebar panel that follows whichever Claude session is focused. The HUD lives in iTerm's chrome (the toolbelt sidebar), so it doesn't compete with Claude for terminal real estate, and a single instance handles any number of concurrent Claude sessions across tabs.

## Goals

- Always-visible mirror of Claude's current todo list and live tool activity for the focused tab.
- One HUD instance for all Claude sessions; follows focus across tabs.
- Zero impact on the terminal viewport.
- Hooks degrade gracefully — Claude must never break because of HUD code.

## Non-Goals (v1)

- Bidirectional control (clicking todos to inject text into the session).
- Token / cost tracking.
- Cross-window orchestration UI or a "sessions tree" panel.
- tmux / screen multiplexer support.

## Architecture

Three independent layers communicating only through files under `~/.claude/state/hud/`. The hooks and the iTerm plugin never talk to each other directly — the filesystem is the only contract.

```
┌─────────────────────────┐    ┌─────────────────────────┐    ┌─────────────────────────┐
│   Claude side (hooks)   │    │  State (filesystem)     │    │   iTerm side (plugin)   │
│                         │    │  ~/.claude/state/hud/   │    │                         │
│ • SessionStart          │───▶│ • tty-map.json          │◀───│ • claude_hud.py         │
│ • PreToolUse            │───▶│ • sessions/<id>/        │    │ • hud_server.py (SSE)   │
│ • PostToolUse           │───▶│   ├─ meta.json          │    │ • state_reader.py       │
│ • SessionEnd            │───▶│   ├─ todos.json         │    │ • tty_resolver.py       │
│                         │    │   └─ current.json       │    │ • webview/ (HTML/JS)    │
└─────────────────────────┘    └─────────────────────────┘    └─────────────────────────┘
```

**Update propagation:**

```
claude-code  ─writes→  ~/.claude/state/hud/sessions/<id>/*.json
claude_hud.py  ─watches→ same dir  AND  iTerm focus events
   ↓ on either change
resolver: focused tty → session_id → load {meta,todos,current}.json
   ↓
webview ← SSE push (snapshot JSON) ← server.push() → re-render
```

**Why this shape:**

- **Files as the only contract** — either side can be replaced or debugged in isolation.
- **One TTY map, many sessions** — same plugin works whether you have 1 or 12 Claude tabs.
- **No long-lived process besides iTerm's auto-launch** — no daemon to babysit.
- **Hooks degrade gracefully** — if a hook fails, Claude keeps working; HUD just shows stale data.

## Layer 1 — Claude hooks

Configured in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{"hooks":[{"type":"command","command":"~/.claude/hooks/hud-session-start.sh"}]}],
    "PreToolUse":   [{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/hooks/hud-pre-tool.sh"}]}],
    "PostToolUse":  [{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/hooks/hud-post-tool.sh"}]}],
    "SessionEnd":   [{"hooks":[{"type":"command","command":"~/.claude/hooks/hud-session-end.sh"}]}]
  }
}
```

| Hook | Reads from stdin | Writes |
|---|---|---|
| `SessionStart` | `{session_id, source, transcript_path, cwd, ...}` | `sessions/<id>/meta.json` and adds an entry to `tty-map.json` keyed by `ps -o tty= -p $PPID` |
| `PreToolUse` (any) | `{session_id, tool_name, tool_input, ...}` | `sessions/<id>/current.json` = `{tool_name, input_summary, started_at}` |
| `PostToolUse` (any) | `{session_id, tool_name, tool_input, tool_response, ...}` | Clears `current.json`. **If `tool_name == "TodoWrite"`** also writes `sessions/<id>/todos.json` from `tool_input.todos` |
| `SessionEnd` | `{session_id, reason, ...}` | Removes `tty-map.json` entry, sets `meta.json.ended_at` |

**TTY discovery:** hooks resolve the controlling terminal via `ps -o tty= -p $PPID` (Claude is the parent), normalized to short form like `s003`. iTerm2's Python API returns the same short form via `Session.tty`, so they line up cleanly.

## Layer 2 — Filesystem state contract

```jsonc
// ~/.claude/state/hud/tty-map.json
{
  "s003": {"session_id": "abc-123", "claude_pid": 12345, "started_at": 1736000000},
  "s004": {"session_id": "def-456", "claude_pid": 67890, "started_at": 1736000100}
}

// ~/.claude/state/hud/sessions/<id>/meta.json
{
  "session_id": "abc-123",
  "model": "claude-opus-4-7",
  "project": "/Users/masongoetz/workspace/mulligan",
  "transcript_path": "/Users/masongoetz/.claude/projects/.../session.jsonl",
  "started_at": 1736000000,
  "last_updated": 1736000100,
  "ended_at": null
}

// ~/.claude/state/hud/sessions/<id>/todos.json — verbatim copy of TodoWrite payload
{
  "updated_at": 1736000050,
  "todos": [
    {"content": "Read superpowers spec", "status": "completed",   "activeForm": "..."},
    {"content": "Sentry init module",    "status": "in_progress", "activeForm": "..."},
    {"content": "Health check route",    "status": "pending",     "activeForm": "..."}
  ]
}

// ~/.claude/state/hud/sessions/<id>/current.json — absent or {...} while a tool runs
{"tool_name": "Bash", "input_summary": "git rev-parse HEAD", "started_at": 1736000095}
```

**Three simplifications worth flagging:**

1. **No separate "plan progress" field.** The mockup's progress bar derives directly from `todos.json` (completed / total). No extra hook required.
2. **Atomic writes.** Hooks write to a sibling tmp file then `mv` it into place — POSIX `rename(2)` is atomic on the same filesystem, so readers never see torn writes.
3. **`input_summary` definition.** A short human-readable string derived per-tool from `tool_input` — `Bash` → first line of `command` truncated to 80 chars; `Read`/`Edit`/`Write` → `file_path`; `Grep` → `pattern`; everything else → `tool_name` only. Computed in the hook to keep the plugin tool-agnostic.

## Layer 3 — iTerm2 Python plugin

Installed under `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/`:

```
claude_hud/
├── claude_hud.py        # async entry point — registers tool, runs poll loop
├── hud_server.py        # aiohttp app: serves the webview + SSE push endpoint
├── state_reader.py      # reads ~/.claude/state/hud/ → snapshot dict
├── tty_resolver.py      # focused session.tty → session_id (via tty-map.json)
└── webview/
    ├── index.html
    ├── hud.css
    └── hud.js           # subscribes to /events (SSE), patches DOM on push
```

### Core loop

```python
import iterm2, asyncio
from iterm2.tool import async_register_web_view_tool

async def main(connection):
    server = HudServer(state_dir=Path("~/.claude/state/hud").expanduser())
    port = await server.start()                       # binds 127.0.0.1:<rand>

    await async_register_web_view_tool(
        connection,
        display_name="Claude HUD",
        identifier="com.masongoetz.claude.hud",
        reveal_if_already_registered=True,
        url=f"http://127.0.0.1:{port}/",
    )

    app = await iterm2.async_get_app(connection)
    last_snapshot = None
    while True:
        focused = app.current_terminal_window.current_tab.current_session
        tty = await focused.async_get_variable("session.tty")
        snapshot = state_reader.snapshot_for_tty(tty)         # None if not Claude
        if snapshot != last_snapshot:
            await server.push(snapshot)
            last_snapshot = snapshot
        await asyncio.sleep(0.2)

iterm2.run_forever(main)
```

### Snapshot schema (server → webview)

```jsonc
{
  "tty": "s003",
  "session": {"id": "abc-123", "model": "claude-opus-4-7", "project": "…/mulligan"} | null,
  "current": {"tool_name": "Bash", "input_summary": "git rev-parse HEAD", "running_for_ms": 2300} | null,
  "todos":   [{"content": "…", "status": "completed" | "in_progress" | "pending"}, ...]
}
```

`session: null` means the focused tab isn't running Claude — the webview shows a "no Claude session in this tab" empty state.

### Three calls worth flagging

1. **200ms poll loop, not a file-watcher.** Five reads/sec of three tiny JSON files is essentially free with kernel page cache, no third-party dep needed, and the same loop handles both focus and state changes. The webview is only pushed to when the snapshot actually differs from the last one.
2. **`Session.async_get_variable` only works on focused sessions** per the iTerm docs — fine for v1 since we only care about the focused session anyway.
3. **Why a local HTTP server at all?** `async_register_web_view_tool` only takes a URL. Bind to 127.0.0.1 on a random port (port `0` → kernel picks). Never exposed off-host.

### Update transport: Server-Sent Events

One-way server→client push is exactly what we need; SSE is half the code of WebSocket, native to the browser, and auto-reconnects on its own. The aiohttp endpoint `/events` holds the connection open and emits `data: <json>\n\n` whenever the server's `push()` is called.

## Failure modes

### Write-side (hooks). Non-negotiable rule: a hook NEVER breaks Claude.

| Failure | Mitigation |
|---|---|
| Hook script throws / exits nonzero | Every hook wraps body in `try/catch`, always exits 0. Errors append to `~/.claude/state/hud/errors.log` |
| Mid-write corruption | Atomic write via `tmp + mv`; POSIX `rename(2)` is atomic on the same filesystem |
| State dir doesn't exist on first run | Each hook does `mkdir -p` on its target dir before writing |
| Disk full / permission denied | Logged + swallowed. HUD shows stale data; webview's "last update Xs ago" indicator surfaces it |
| Concurrent SessionStart writes racing on `tty-map.json` | Wrap read-modify-write in `flock` on a sibling lockfile |

### Read-side (plugin)

| Failure | Mitigation |
|---|---|
| iTerm API daemon not enabled ("Allow API requests" off) | Plugin can't run at all. README's first sentence is the toggle path: *Settings → General → Magic → "Enable Python API"*. Documented loudly; not recoverable |
| Random port already taken | Bind to port `0` — kernel assigns an available one |
| State files corrupt mid-poll | Reader wraps `json.loads` in `try/except JSONDecodeError` → treat as "no data this tick", retry next poll |
| Plugin crashes during a session | iTerm doesn't auto-restart auto-launch scripts mid-session; on next iTerm launch it auto-restarts. Crashes logged to `errors.log` |
| Focused session has no `session.tty` (e.g. welcome tab) | `state_reader.snapshot_for_tty(None)` returns `None` → webview shows the empty state |
| Webview disconnects | SSE auto-reconnects from the browser side with no code from us |

### Lifecycle drift

- **Claude crashes without firing `SessionEnd`** → `tty-map.json` accumulates stale entries. *Mitigation:* on plugin startup, read `tty-map.json`, `kill -0 $pid` each entry, drop dead ones. Same GC also runs every 60 polls (~12s).
- **Same tty reused by a new Claude session** → `tty-map.json` overwrite by the new `SessionStart` is correct behavior; old session_id keeps its files for archive but stops being shown.
- **User runs Claude inside tmux/screen** → the tty Claude sees is the multiplexer's pty, not iTerm's. Resolver fails to match. *v1 scope:* documented limitation. *v2:* walk up the process tree.
- **PreToolUse fires but PostToolUse never does** (process killed mid-tool, OOM, force-quit) → `current.json` sits stale forever, "running for X" ticks up indefinitely. *Mitigation:* webview treats `current.json` older than 10 minutes as stale and renders an "interrupted?" state; plugin also clears `current.json` for any session_id whose `tty-map.json` entry has been removed.

### Diagnostic surface

`diagnostics.json` written every 5s by the plugin, plus a `--debug` flag that streams polls to stderr (visible in iTerm's Python script console):

```json
{
  "plugin_started_at": 1736000000,
  "focused_tty": "s003",
  "resolved_session_id": "abc-123",
  "last_snapshot_pushed_at": 1736000150,
  "hook_error_count_24h": 0,
  "tty_map_size": 2
}
```

## Testing strategy

### Automate (pytest)

| Module | What we test | How |
|---|---|---|
| `hooks/*.sh` | Given fixture JSON on stdin, correct file gets written, exit code is 0 even on simulated errors | `bats` or pytest invoking shell, asserting filesystem state |
| `state_reader.py` | `snapshot_for_tty()` against synthetic state dirs — happy path, missing files, partial files, idle session | pytest + `tmp_path` fixture |
| `tty_resolver.py` | tty→session_id resolution including stale-entry GC (mock `kill -0`) | pytest with monkeypatched `os.kill` |
| `hud_server.py` | aiohttp test client subscribes to `/events`, server `push(snapshot)`, assert one SSE frame received with expected JSON | `aiohttp.test_utils.TestClient` |

### Manual — `docs/SMOKE.md` checklist

1. Restart iTerm with the auto-launch script in place — verify "Claude HUD" appears in the Toolbelt menu.
2. Open the HUD panel — verify "no Claude session in this tab" empty state.
3. Run `claude` in the tab — verify session header (model, project) appears within ~200ms.
4. Trigger any tool call — verify `▶ Bash · Xs` appears in "current" line and clears when the tool returns.
5. Trigger `TodoWrite` (e.g. ask Claude to plan something) — verify todos render with correct status icons.
6. Open a second tab, run another `claude`, switch focus — verify HUD swaps to the focused session's state.

### Skip explicitly

- **No CI.** Solo-dev tool; manual loop is fast.
- **No Playwright tests.** Webview JS is ~50 lines; eyeball test in step 5 above is faster than maintaining browser fixtures.
- **No load testing.** 5 polls/sec on three tiny JSON files is not a perf concern.

### Quality signals beyond tests

- `mypy --strict` on Python, `ruff` for lint/format
- `shellcheck` on shell hooks
- `Makefile` with `test`, `lint`, `smoke` targets — single command per signal

## Future work (out of scope for v1)

- **tmux/screen support.** Walk up the process tree from Claude until an ancestor's tty matches a known iTerm pane.
- **Sessions list.** When focused tab isn't Claude, show a list of all known active Claude sessions across tabs/windows, click to focus.
- **Bidirectional control.** Clickable todos that send a message back to the corresponding Claude session.
- **Token / cost tracking.** Pull from the JSONL transcript sidecar.
