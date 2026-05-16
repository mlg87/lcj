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

Each module's docstring explains WHY it exists and what its role is. Start with `plugin/claude_hud.py` (the entry point) for the orchestration overview.

## Install

```bash
make install            # set up dev venv (only for running tests / development)
./install.sh            # copies hooks + plugin and prints next steps
```

After running `install.sh`, follow its printed steps to enable the iTerm Python API, install runtime deps into the iTerm-managed venv, and merge the hook config into `~/.claude/settings.json`. Then restart iTerm and open the toolbelt (`⌘⇧B`).

## Development

```bash
make check     # ruff + mypy + shellcheck + pytest
make test      # just pytest
make smoke     # print the manual smoke-test checklist
```

## Smoke test

See `docs/SMOKE.md`. The smoke checklist is the final acceptance gate before merging — automated tests cover the data layer but the iTerm integration only verifies end-to-end with real Claude.
