# lcj — agent guide

Monorepo of personal Claude Code tooling. Every project is self-contained in its
own top-level directory; each project's README is the source of truth for
install and development. Read it before working in that directory.

## Repo rules
- Never commit or push to `main` — all changes land via PR; never bypass branch protection.
- One PR per logical change. Branch prefixes: `feat/`, `fix/`, `chore/`.
- Run the relevant linter after every file change (`make lint` where a Makefile exists).
- Comments explain WHY, not what; reference issues/PRD sections where relevant.

## Projects
| Dir | What | Dev commands |
|---|---|---|
| `clud/` | iTerm2 Claude HUD panel (Python) | see `clud/README.md` |
| `clusage-menubar/` | macOS menu bar Claude usage app (Swift 6, AppKit) | `make -C clusage-menubar check` |

## Releasing clusage-menubar (fully automated — never release manually)
- NEVER create `clusage-menubar-v*` tags or GitHub releases by hand; CI owns them.
- To ship: one PR that bumps `clusage-menubar/VERSION` AND adds a matching
  `## vX.Y.Z` section to `clusage-menubar/CHANGELOG.md` (release notes are taken
  from it verbatim; the workflow fails loudly if the section is missing). Merge to `main`.
- `.github/workflows/clusage-menubar-release.yml` runs on every push to `main`
  touching `clusage-menubar/**`: always runs `make check`; publishes tag + DMG
  release only when the `VERSION` tag doesn't exist yet. No bump ⇒ CI checks only.
- Signing is ad-hoc unless `CODESIGN_IDENTITY` is configured. Keychain access
  re-prompts after each rebuild because the macOS ACL binds to the code signature.
