# Changelog

All notable changes to clusage-menubar.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0](https://github.com/mlg87/lcj/compare/clusage-menubar-v0.7.0...clusage-menubar-v0.8.0) (2026-09-24)


### Features

* **clusage-menubar:** move preferences into a Settings submenu ([2bb61b6](https://github.com/mlg87/lcj/commit/2bb61b698b9db8d64a3e9d01c2894821d85f3696))
* **clusage-menubar:** redesign the dropdown, add Center Dash layout and a Settings submenu ([d3a8c2e](https://github.com/mlg87/lcj/commit/d3a8c2e87bdbe137ef6baa5c27f3ce8ec096e0fa))


### Bug Fixes

* **clusage-menubar:** package the binary swift build just produced ([844efa4](https://github.com/mlg87/lcj/commit/844efa47b120e95e0abe6808f9da0c5035f96484))
* **clusage-menubar:** package the binary swift build just produced ([f4265d7](https://github.com/mlg87/lcj/commit/f4265d7b615854621690e2e7aec9f00c14993c47))

## [0.7.0](https://github.com/mlg87/lcj/compare/clusage-menubar-v0.6.0...clusage-menubar-v0.7.0) (2026-09-14)


### Features

* **clusage-menubar:** add Codex usage column ([d2ec6e8](https://github.com/mlg87/lcj/commit/d2ec6e8964c807053dee6c459c96e1830f866513))
* **clusage-menubar:** add Codex usage column + Remaining Capacity layout ([59c1e7f](https://github.com/mlg87/lcj/commit/59c1e7f1b9a0864d3b13c49772f6ad4182a70573))
* **clusage-menubar:** add Remaining Capacity menu bar layout ([8be8589](https://github.com/mlg87/lcj/commit/8be8589e80c3dc45ddd7a82ef2a1b19fe950ca9a))
* **clusage-menubar:** toggle Claude and Codex independently ([e290707](https://github.com/mlg87/lcj/commit/e2907073734276d88c13d5cc3f61013e1c20c4a8))


### Bug Fixes

* **clusage-menubar:** address review on [#40](https://github.com/mlg87/lcj/issues/40) ([f10f2da](https://github.com/mlg87/lcj/commit/f10f2da212b30af49d5e7376a3f44198b7b20b59))

## [0.6.0](https://github.com/mlg87/lcj/compare/clusage-menubar-v0.5.0...clusage-menubar-v0.6.0) (2026-07-29)


### Features

* **clusage-menubar:** configurable refresh interval (1/2/3/5/8/13 min) ([72526e9](https://github.com/mlg87/lcj/commit/72526e92cff612347b8634e55ba4c8914f95badf))
* **clusage-menubar:** configurable refresh interval (1/2/3/5/8/13 min) ([f535f21](https://github.com/mlg87/lcj/commit/f535f210d636fefd1ed68e2a48790fc0133d47cf))

## [0.5.0](https://github.com/mlg87/lcj/compare/clusage-menubar-v0.4.0...clusage-menubar-v0.5.0) (2026-07-11)


### Features

* **clusage-menubar:** two-column menu bar grid layout ([d4e1553](https://github.com/mlg87/lcj/commit/d4e155320bbf5c4d722981c212347a5143e27fe7))
* **clusage-menubar:** two-column menu bar grid layout ([1959f88](https://github.com/mlg87/lcj/commit/1959f88b2f087e344832115be730afaaee2f3cfc))

## [0.4.0](https://github.com/mlg87/lcj/compare/clusage-menubar-v0.3.1...clusage-menubar-v0.4.0) (2026-07-11)


### Features

* **clusage-menubar:** stack menu bar gauges vertically ([c87df3c](https://github.com/mlg87/lcj/commit/c87df3c9258dae51310eb86f8c052c05a7171591))
* **clusage-menubar:** stack menu bar gauges vertically (Mockup D) ([15a138e](https://github.com/mlg87/lcj/commit/15a138e94b1edc713d3eff9eda529451fb4cf1ad))

## [0.3.1](https://github.com/mlg87/lcj/compare/clusage-menubar-v0.3.0...clusage-menubar-v0.3.1) (2026-07-11)


### Bug Fixes

* **clusage-menubar:** make cookie field focusable for paste in Set Session Cookie dialog ([603c8ba](https://github.com/mlg87/lcj/commit/603c8ba4cf27b42426a10907aaa8a189b1110b33))

## [0.3.0](https://github.com/mlg87/lcj/compare/clusage-menubar-v0.2.0...clusage-menubar-v0.3.0) (2026-07-11)


### Features

* **clusage-menubar:** distribute via install script + ad-hoc signing, dropping Apple Developer Program requirement ([0ca914f](https://github.com/mlg87/lcj/commit/0ca914ff7c145436aad15839fc4f54d20bf56510))
* **clusage-menubar:** distribute via install script + ad-hoc signing, dropping the Apple Developer Program requirement ([b7c243d](https://github.com/mlg87/lcj/commit/b7c243ddd26e4d4481ed3c143a80a8d5f1d72c69))

## [0.2.0](https://github.com/mlg87/lcj/compare/clusage-menubar-v0.1.2...clusage-menubar-v0.2.0) (2026-07-11)


### Features

* **clusage-menubar:** notarized releases + release-please automation ([54182fd](https://github.com/mlg87/lcj/commit/54182fd74ee72892798a15e8e69e99b821dff677))


### Bug Fixes

* **clusage-menubar:** sign and notarize release DMGs so downloads pass Gatekeeper ([be4af80](https://github.com/mlg87/lcj/commit/be4af807978116a47057b7644c965a8c2cb049ef))

## v0.1.2

### Changed
- New app icon: embroidered-patch "lcj/cm" artwork masked to the Apple-standard squircle (824×824 rounded-rect, radius 185.4, transparent margins on the 1024 canvas).

## v0.1.1

### Changed
- Auth via pasted claude.ai session cookie (ClaudeUsageBar-style): paste once from DevTools, stored in app preferences (`com.mlg87.clusage-menubar`, key `session_cookie`), `CLUSAGE_COOKIE` env override. No keychain access, no prompts.
- Removed all Keychain / credentials-file / OAuth-token auth paths (keychain ACL binds to the ad-hoc signature — re-prompts on every rebuild; unusable for end-users).

## v0.1.0

Initial release.

### Added
- Stats-style macOS menu bar display: three compact segments (5H / Fable / weekly-all) each with a mini progress bar, percentage, and thin vertical separators.
- 5-hour session reset time shown at the right of the menu bar label.
- Auth via pasted claude.ai session cookie (ClaudeUsageBar-style): paste once from DevTools, stored in app preferences (`com.mlg87.clusage-menubar`, key `session_cookie`), `CLUSAGE_COOKIE` env override. No keychain access, no prompts.
- Dynamic color bands: green (<70%), yellow (70–89%), red (≥90%).
- Dropdown menu: per-bucket detail rows with reset weekday + time, "Updated N min ago" timestamp, Refresh Now (⌘R), Launch at Login toggle, Quit (⌘Q).
- Degraded state: when the token is missing/expired or the API is unreachable, all bars show "–" and the dropdown explains why.
- Auto-refresh every 5 minutes + immediate refresh on system wake.
- 12/24-hour time format follows the machine's system preference via `.autoupdatingCurrent` locale.
- Universal binary (arm64 + x86_64) assembled via two SPM release builds + `lipo`.
- Ad-hoc code signing by default; `CODESIGN_IDENTITY` env enables notarization-ready signing.
- DMG distribution with drag-to-Applications layout.
- Automated releases: pushes to `main` touching `clusage-menubar/` run CI checks and, on a new `VERSION`, tag and publish the DMG release with notes from this file (GitHub Actions, macos-15).
