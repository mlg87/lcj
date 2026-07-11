# Clusage — Claude usage in your macOS menu bar

A Stats-style macOS menu bar app showing your Claude Code usage as three compact
segments with mini progress bars, authenticated by your claude.ai session cookie —
paste it once, no keychain access, no API key setup.

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
3. Launch it. A dialog explains how to copy your session cookie from claude.ai
   (Settings → Usage → DevTools → Network → `usage` request → `Cookie` request header).
   Paste and Save.
4. The usage bars appear within a few seconds.

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

Clusage uses your **pasted claude.ai session cookie** — no Keychain access, no API key.

Resolution order:
1. **`CLUSAGE_COOKIE` environment variable** — overrides the stored value (tests/CI).
2. **UserDefaults** — stored in the `com.mlg87.clusage-menubar` preferences domain under
   key `session_cookie` after your first paste.

The cookie is stored **unencrypted** in the app's preferences plist — the same trust
level as the browser profile it was copied from. It is never logged and never sent
anywhere but `claude.ai`.

### Compliance / gray-area disclaimer

The usage data comes from `GET https://claude.ai/api/organizations/<orgId>/usage` — the
same internal API the claude.ai usage page calls. This is an **undocumented, internal
endpoint** and may change or disappear without notice. Clusage degrades gracefully
(shows "–" bars) whenever it becomes unavailable. Use is at your own discretion.

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

### Env vars

| Variable | Default | Purpose |
|---|---|---|
| `ARCHS` | `arm64 x86_64` | Architectures to build. Set to `arm64` if x86_64 CLT build fails. |
| `CODESIGN_IDENTITY` | `-` (ad-hoc) | Set to your Developer ID for distribution signing. |
| `NOTARY_PROFILE` | *(unset)* | `notarytool` credential profile; DMG is notarized only when both this and `CODESIGN_IDENTITY` are set. |
| `SKIP_DMG_LAYOUT` | *(unset)* | Set to any value to skip the Finder AppleScript icon-layout step (used on headless CI). |
| `CLUSAGE_COOKIE` | *(unset)* | Overrides the stored session cookie at runtime (tests/CI). |

---

## Release procedure

Releases are fully automated by [`.github/workflows/clusage-menubar-release.yml`](../.github/workflows/clusage-menubar-release.yml). Never create `clusage-menubar-v*` tags or releases manually — CI owns them.

1. Bump `VERSION` (e.g. `echo "0.2.0" > VERSION`).
2. Add a `## v0.2.0` section to `CHANGELOG.md` — the release notes come from it verbatim; the workflow fails loudly without it.
3. Open a PR with both changes, get it merged to `main`.

On merge, the workflow runs `make check` and — because tag `clusage-menubar-v0.2.0` doesn't exist yet — builds the universal binary, creates the DMG, and publishes the tag + GitHub release. Merges that don't bump `VERSION` run CI checks only.
---

## Troubleshooting

**No session cookie set** — use **Set Session Cookie…** in the menu bar dropdown.
Follow the in-app instructions to copy the `Cookie` header from DevTools on
claude.ai/settings/usage and paste it into the dialog.

**Cookie rejected or expired** — your session has expired. Log in to claude.ai again,
then copy a fresh cookie via the same DevTools steps and paste it with
**Set Session Cookie…**.

**Launch at Login doesn't work** — `SMAppService` requires the app to be in a stable
location (e.g. `/Applications`). It won't work when run via `swift run` or directly
from the build directory.
