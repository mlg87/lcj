# HUD Usage + Status Strip — data contracts

The top-of-panel strip shows two usage bars (5-hour session + weekly), a
service-status indicator, and a usage-refresh cadence selector. Two
timer-driven writers in the plugin process produce three state files under
`~/.claude/state/hud/`; `StateReader` folds them into the snapshot.

## Where the data comes from

- **Usage** — `GET https://api.anthropic.com/api/oauth/usage` (the endpoint
  Claude Code's own `/usage` uses), with the local Claude Code OAuth token
  (`token_resolver.py`: env `CLAUDE_CODE_OAUTH_TOKEN` → `~/.claude/.credentials.json`
  → macOS Keychain item `Claude Code-credentials`). Headers: `Authorization:
  Bearer …`, `anthropic-beta: oauth-2025-04-20`, `User-Agent:
  claude-code/<version>` (the UA is required to avoid a throttled bucket).
  `utilization` is already a 0–100 percent. **Undocumented endpoint, gray-area
  per ToS — every failure degrades to "usage unavailable", never crashes.**
  The token is never written to disk, a snapshot, or the DOM.
- **Status** — `GET https://status.claude.com/api/v2/summary.json` (public
  Statuspage; `status.anthropic.com` redirects there). ETag-conditional.

## State files (all atomic tmp+rename writes)

### `usage.json`
`{ "updated_at": <epoch>, "ok": true, "five_hour": {"utilization": 52, "resets_at": "<ISO|null>"}, "seven_day": {…} }`
or on failure `{ "updated_at": <epoch>, "ok": false, "reason": "no_token|expired|http_401|http_5xx|network|bad_shape" }`.

### `status.json`
`{ "updated_at": <epoch>, "ok": true, "indicator": "none|minor|major|critical", "description": "…", "incident": null }`
or with an incident `"incident": { "name", "status", "impact", "body", "updated_at" }`;
on failure `{ "ok": false, "indicator": "unknown", "description": "Status unavailable", "incident": null }`.

### `config.json`
`{ "usage_poll_interval_s": <60|120|300|600|900|1800> }` — written by
`PUT /config/usage-interval` (the strip's cadence chip), hot-reloaded by the
usage fetcher each tick. Default/invalid → 300.

## Cadence

Usage poll interval is user-selectable (1/2/5/10/15/30m, default 5m). Status
poll is fixed at 60s. The allowed interval set lives once in `hud_config.py`.
