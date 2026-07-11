# Changelog

All notable changes to clusage-menubar.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.1.0

Initial release.

### Added
- Stats-style macOS menu bar display: three compact segments (5H / Fable / weekly-all) each with a mini progress bar, percentage, and thin vertical separators.
- 5-hour session reset time shown at the right of the menu bar label.
- Auth via local Claude Code OAuth token — no cookie pasting. Resolves from `CLAUDE_CODE_OAUTH_TOKEN` env → `~/.claude/.credentials.json` → macOS Keychain service `Claude Code-credentials`. Multi-item Keychain selection picks the `claudeAiOauth` item correctly even when an `mcpOAuth`-only item shares the same service name.
- Dynamic color bands: green (<70%), yellow (70–89%), red (≥90%).
- Dropdown menu: per-bucket detail rows with reset weekday + time, "Updated N min ago" timestamp, Refresh Now (⌘R), Launch at Login toggle, Quit (⌘Q).
- Degraded state: when the token is missing/expired or the API is unreachable, all bars show "–" and the dropdown explains why.
- Auto-refresh every 5 minutes + immediate refresh on system wake.
- 12/24-hour time format follows the machine's system preference via `.autoupdatingCurrent` locale.
- Universal binary (arm64 + x86_64) assembled via two SPM release builds + `lipo`.
- Ad-hoc code signing by default; `CODESIGN_IDENTITY` env enables notarization-ready signing.
- DMG distribution with drag-to-Applications layout.
- Automated releases: pushes to `main` touching `clusage-menubar/` run CI checks and, on a new `VERSION`, tag and publish the DMG release with notes from this file (GitHub Actions, macos-15).
