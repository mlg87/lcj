# Claude HUD

iTerm2 toolbelt panel that mirrors live Claude Code session state — todos, current tool, model, project — for whichever Claude tab is focused.

## Architecture

Three independent layers communicate only through JSON files under `~/.claude/state/hud/`. The hooks (write side) and plugin (read side) never talk to each other directly; the filesystem is the only contract.

```
┌─ Claude side ──────────┐    ┌─ Filesystem state ─────┐    ┌─ iTerm side ──────────┐
│ hooks/                 │    │ ~/.claude/state/hud/   │    │ plugin/               │
│  hud-session-start.sh  │───▶│  tty-map.json          │◀───│  claude_hud.py        │
│  hud-pre-tool.sh       │───▶│  sessions/<id>/        │    │  state_reader.py      │
│  hud-post-tool.sh      │───▶│   meta|todos|current   │    │  tty_resolver.py      │
│  hud-session-end.sh    │───▶│                        │    │  hud_server.py (SSE)  │
└────────────────────────┘    └────────────────────────┘    │  webview/             │
                                                            └───────────────────────┘
```

Update path: hook writes JSON → plugin polls (200ms) and notices change → plugin pushes snapshot via SSE → webview re-renders.

Each module's docstring explains WHY it exists. Start with `plugin/claude_hud.py` for the orchestration overview.

## Install

The install has three pieces: **hooks** (script-only, copies straight in), **plugin sources** (need iTerm's specific nested directory layout), and **iTerm runtime** (needs manual UI clicks to provision Python and toggle visibility — iTerm exposes no scripted way to do these).

### 1. Enable iTerm's Python API

`iTerm2 → Settings → General → Magic → ☑ Enable Python API`

Without this, the auto-launch script can't talk to iTerm and will exit silently.

### 2. Create the Full Environment venv via iTerm's wizard

`iTerm2 → Scripts → Manage → New Python Script → Full Environment → name: claude_hud`

This is the **only** way to provision the bundled Python iTerm requires at `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/claude_hud/iterm2env/versions/<python>/`. The script will be a stub — we overwrite it next.

> WHY this step is manual: iTerm validates the script directory against a `setup.cfg` and a bundled Python interpreter version. Skipping the wizard ("bringing your own venv") produces a silent "Cannot Run Script — malformed" dialog with no log output. Reverse-engineering the validator (see `iTermSetupCfgParser.m` in the iTerm2 source) confirmed the wizard is load-bearing.

### 3. Run the installer

```bash
./install.sh
```

This copies:
- `hooks/*.sh` → `~/.claude/hooks/`
- `plugin/*` → `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/claude_hud/claude_hud/` (the nested layout iTerm requires)
- A generated `setup.cfg` → `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/claude_hud/`

It also prints the next manual steps. The rest of this section repeats them in case you need to re-run them later.

### 4. Install aiohttp into iTerm's bundled Python

```bash
PLUGIN=~/Library/Application\ Support/iTerm2/Scripts/AutoLaunch/claude_hud
PY=$(ls -d "$PLUGIN"/iterm2env/versions/*/bin/python3 | head -1)
"$PY" -m pip install aiohttp
```

`iterm2` is preinstalled by the Full Environment. We must invoke `python3 -m pip` instead of `pip3` directly — iTerm templates pip3's shebang with `__ITERM2_ENV__` and it breaks when called directly.

### 5. Merge hook config into `~/.claude/settings.json`

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

Merge into your existing `hooks` block (don't overwrite — other tools likely have hooks registered too).

### 6. Restart iTerm

The plugin auto-launches. Verify with:

```bash
ps -ef | grep claude_hud | grep -v grep
```

You should see a `python3 .../claude_hud/claude_hud.py` process.

### 7. Show the toolbelt and enable the HUD

This is the step that's easy to miss — registering a webview tool with iTerm makes it *available*, but it's hidden until you opt it in:

1. `View → Toolbelt → ☑ Show Toolbelt` (or `⌘⇧B`)
2. In the toolbelt's gear menu (or right-click in the toolbelt area), check `☑ Claude HUD`

The panel should appear on the right side. With no Claude session in the focused tab, it shows "No Claude session in this tab." Run `claude` and the panel populates within ~200ms.

## Troubleshooting

| Symptom | Check |
|---|---|
| Plugin process not running | iTerm Settings → General → Magic → Python API enabled? |
| "Cannot Run Script — malformed" dialog | Re-run `./install.sh`; verify `setup.cfg` exists and `claude_hud/claude_hud/claude_hud.py` exists |
| Toolbelt entry missing | View → Toolbelt → Show Toolbelt; then check Claude HUD in toolbelt menu |
| Toolbelt entry present but blank | Curl `http://127.0.0.1:<port>/` — find the port via `lsof -nP -iTCP -sTCP:LISTEN \| grep python3` |
| HUD shows "No Claude session" even with Claude running | `cat ~/.claude/state/hud/tty-map.json` — should contain your tab's tty |
| Tool indicator stuck | Check `~/.claude/state/hud/errors.log` — likely a PreToolUse hook ran but PostToolUse didn't |

Live diagnostics: `cat ~/.claude/state/hud/diagnostics.json` (rewritten every ~5s while plugin is running).

## Development

```bash
make install   # set up dev venv (uv) — for tests / typecheck only
make check     # ruff + mypy + shellcheck + pytest
make test      # just pytest
make smoke     # print the manual smoke-test checklist
```

## Smoke test

See `docs/SMOKE.md`. The smoke checklist is the final acceptance gate before merging — automated tests cover the data layer but the iTerm integration only verifies end-to-end with real Claude.
