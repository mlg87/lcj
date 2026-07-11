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

> **Gatekeeper:** Releases v0.1.3+ are Developer ID–signed and notarized by Apple —
> they open with no warnings. For older releases macOS blocks the app: go to
> System Settings → Privacy & Security → scroll to the block message → **Open Anyway**
> (macOS 15 removed the right-click → Open bypass), or run
> `xattr -d com.apple.quarantine /Applications/ClusageMenubar.app`.

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
| `NOTARY_PROFILE` | *(unset)* | Local dev: `notarytool` credential profile; DMG is notarized only when both this and `CODESIGN_IDENTITY` are set. |
| `NOTARY_KEY_FILE` | *(unset)* | CI: path to App Store Connect API key (.p8 file). App Store Connect API-key alternative to `NOTARY_PROFILE` (all three required; used by CI). |
| `NOTARY_KEY_ID` | *(unset)* | CI: App Store Connect API key ID (all three required; used by CI). |
| `NOTARY_ISSUER_ID` | *(unset)* | CI: App Store Connect Issuer ID (all three required; used by CI). |
| `SKIP_DMG_LAYOUT` | *(unset)* | Set to any value to skip the Finder AppleScript icon-layout step (used on headless CI). |
| `CLUSAGE_COOKIE` | *(unset)* | Overrides the stored session cookie at runtime (tests/CI). |

---

## Release procedure

Releases are fully automated by [release-please](https://github.com/googleapis/release-please)
+ [`clusage-menubar-release.yml`](../.github/workflows/clusage-menubar-release.yml).
Never create `clusage-menubar-v*` tags/releases or edit `version.txt` by hand — CI owns them.

1. Merge PRs whose commits follow [Conventional Commits](https://www.conventionalcommits.org/)
   (`fix:` → patch, `feat:` → minor, `feat!:`/`BREAKING CHANGE:` → major) touching `clusage-menubar/**`.
2. release-please maintains a release PR ("chore(main): release clusage-menubar X.Y.Z")
   that accumulates merged changes, bumping `version.txt` and `CHANGELOG.md`.
3. Merge that release PR when you want to ship. CI tags `clusage-menubar-vX.Y.Z`, builds the
   Developer ID–signed + notarized DMG, uploads it, and publishes the release.

Release builds require the repo secrets `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`,
`CODESIGN_IDENTITY`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`. The build job
fails loudly if any is missing; the release stays a draft until the DMG uploads — add the
secret and re-run the failed job.
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
