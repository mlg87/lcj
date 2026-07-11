# Clusage — Claude usage in your macOS menu bar

A Stats-style macOS menu bar app showing your Claude Code usage as three compact
segments with mini progress bars, powered by the same local OAuth token Claude Code
already holds — no cookie pasting, no API key setup.

```
┌──────────────────────────────────────────────┐
│  5H      FABLE     WEEK      │  9:00 PM      │
│ ████░░░  ██░░░░░  ████████░  │               │
│  9%        5%       12%      │               │
└──────────────────────────────────────────────┘
```

**Segments (left → right):** 5-hour session · Fable weekly · Weekly (all models)  
**Right side:** 5-hour window reset time (12 or 24h, follows your system setting)  
**Colors:** green <70% · yellow 70–89% · red ≥90%

---

## Install

### Download (easiest)

1. Download `ClusageMenubar-X.Y.Z.dmg` from [Releases](../../releases).
2. Open the DMG, drag **ClusageMenubar** to Applications.
3. Launch it. macOS will prompt: **"ClusageMenubar" wants to use data from other apps.**
   Click **Always Allow** — this grants access to the Claude Code credentials in your Keychain (one-time, survives restarts).
4. The usage bars appear in your menu bar within a few seconds.

> **Gatekeeper note:** The DMG is ad-hoc signed. If macOS blocks it, right-click
> the app in Finder → Open → Open (first launch only).

### Build from source

Prerequisites: macOS 13+, Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/mlg87/lcj.git
cd lcj/clusage-menubar
make dmg          # builds ClusageMenubar.app + ClusageMenubar-X.Y.Z.dmg
# or just:
make app          # builds build/ClusageMenubar.app (no DMG)
```

---

## How auth works

Clusage resolves your Claude Code OAuth token from three places, in order:

1. **`CLAUDE_CODE_OAUTH_TOKEN` environment variable** — set this for CI/testing.
2. **`~/.claude/.credentials.json`** — Claude Code's credentials file (if present).
3. **macOS Keychain** — service `Claude Code-credentials`, account matching your
   username. Two items may share this service (one for MCP OAuth, one for the Claude AI
   OAuth token); Clusage enumerates all items and picks the one with a valid
   `claudeAiOauth.accessToken`.

The token is **never logged, never persisted by Clusage, and never returned on a failure
path.** Every failure mode degrades to "usage unavailable" — nothing crashes.

### Compliance / gray-area disclaimer

The usage data comes from `GET https://api.anthropic.com/api/oauth/usage` — the same
endpoint Claude Code's own `/usage` screen uses. This is an **undocumented, internal
endpoint** and may change or disappear without notice. Clusage degrades gracefully
(shows "–" bars) whenever it becomes unavailable. Use is at your own discretion.

The `User-Agent: claude-code/<version>` header is required; without it the request
is routed to a throttled bucket that returns persistent 429s.

---

## Dev commands

```sh
make build    # swift build (debug)
make test     # swift run ClusageTests  (assertion-based; no XCTest needed)
make lint     # shellcheck all .sh scripts
make check    # build + test + lint
make app      # ./build.sh — release app bundle in build/
make dmg      # app + ./create_dmg.sh — DMG in clusage-menubar/
```

### Build env vars

| Variable | Default | Purpose |
|---|---|---|
| `ARCHS` | `arm64 x86_64` | Architectures to build. Set to `arm64` if x86_64 CLT build fails. |
| `CODESIGN_IDENTITY` | `-` (ad-hoc) | Set to your Developer ID for distribution signing. |
| `NOTARY_PROFILE` | *(unset)* | `notarytool` credential profile; DMG is notarized only when both this and `CODESIGN_IDENTITY` are set. |
| `SKIP_DMG_LAYOUT` | *(unset)* | Set to any value to skip the Finder AppleScript icon-layout step (used on headless CI). |

---

## Release procedure

Releases are fully automated by [`.github/workflows/clusage-menubar-release.yml`](../.github/workflows/clusage-menubar-release.yml). Never create `clusage-menubar-v*` tags or releases manually — CI owns them.

1. Bump `VERSION` (e.g. `echo "0.2.0" > VERSION`).
2. Add a `## v0.2.0` section to `CHANGELOG.md` — the release notes come from it verbatim; the workflow fails loudly without it.
3. Open a PR with both changes, get it merged to `main`.

On merge, the workflow runs `make check` and — because tag `clusage-menubar-v0.2.0` doesn't exist yet — builds the universal binary, creates the DMG, and publishes the tag + GitHub release. Merges that don't bump `VERSION` run CI checks only.
---

## Troubleshooting

**"Usage unavailable: No Claude Code token found"** — run `claude` in your terminal
and sign in. Clusage polls every 5 min and will pick up the new token automatically.

**"Token rejected"** — your token expired. Run `claude` to refresh.

**Menu bar shows "–" after the first launch** — click **Always Allow** on the Keychain
prompt. If you missed it, go to Keychain Access, find `Claude Code-credentials`, and
grant access to Clusage.

**Launch at Login doesn't work** — `SMAppService` requires the app to be in a stable
location (e.g. `/Applications`). It won't work when run via `swift run` or directly
from the build directory.
