#!/usr/bin/env bash
# clud/install.sh — one-shot install for Claude HUD.
#
# Lays down the hooks and the iTerm2 Full Environment script layout that
# iTerm requires. Some steps still need a human:
#   - Enabling iTerm's Python API
#   - Creating the iterm2env via iTerm's "New Python Script → Full Environment" UI
#     (it's the only sanctioned way to populate iterm2env/versions/<python>/)
#   - Merging hook config into ~/.claude/settings.json
#   - Toggling View → Toolbelt → Show Toolbelt (and checking "Claude HUD")
#
# WHY the nested claude_hud/claude_hud/ layout: iTerm's loader requires
# Full Environment scripts to live at <pkg>/<pkg>/<pkg>.py alongside a
# top-level setup.cfg. Documented in iTermAPIScriptLauncher.m and
# iTermScriptsMenuController.m. Deviating gets you "Cannot Run Script
# — malformed".
#
# WHY setup.cfg pins python_requires to the bundled interpreter: iTerm's
# iTermSetupCfgParser validates these fields; mismatch causes silent
# launch failure with no log output.
#
# WHY we discover the AutoLaunch root instead of hard-coding it (issue #4):
# iTerm's "scripts root" isn't always under ~/Library/Application Support.
# Some installs (or XDG-style configs) put it under
# ~/.config/iterm2/AppSupport/Scripts/. When they're symlinked together
# writes "just work"; when they aren't, installs silently land in a
# directory iTerm never reads. We resolve to the live path before copying
# and verify after.
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
HOOKS_DEST="$HOME/.claude/hooks"

# Candidate AutoLaunch roots, in priority order. The XDG-style ~/.config path
# is checked first because when both exist independently (not symlinked),
# iTerm has been observed to load from the .config one — and getting this
# wrong is the silent-failure mode issue #4 was filed against.
AUTOLAUNCH_CANDIDATES=(
    "$HOME/.config/iterm2/AppSupport/Scripts/AutoLaunch"
    "$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
)
# Fallback used only when no candidate already exists — the Library path is
# what iTerm creates by default on a clean macOS install.
AUTOLAUNCH_FALLBACK="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!  \033[0m %s\n' "$1"; }
fail() { printf '\n\033[1;31m✗ \033[0m %s\n' "$1" >&2; exit 1; }

# Canonicalize a path the way realpath would, but without depending on
# GNU coreutils. macOS ships BSD readlink which doesn't accept -f; this
# Python one-liner is portable and uses only what's already on every
# macOS install. We canonicalize so two paths that point at the same
# physical directory via symlink don't both show up as "live."
canonical_path() {
    /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

resolve_autolaunch_dir() {
    # 1. Explicit override wins. Power users with a known-good path can
    #    short-circuit discovery entirely.
    if [ -n "${CLAUDE_HUD_AUTOLAUNCH_DIR:-}" ]; then
        printf '%s\n' "$CLAUDE_HUD_AUTOLAUNCH_DIR"
        return 0
    fi

    # 2. First existing candidate wins. We dedupe by canonical path so a
    #    candidate that's just a symlink to a later candidate doesn't
    #    cause us to pick the "wrong" lexical name.
    local seen=()
    for candidate in "${AUTOLAUNCH_CANDIDATES[@]}"; do
        if [ -d "$candidate" ]; then
            local canon
            canon=$(canonical_path "$candidate")
            local already=0
            for s in "${seen[@]:-}"; do
                if [ "$s" = "$canon" ]; then
                    already=1
                    break
                fi
            done
            if [ "$already" -eq 0 ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
            seen+=("$canon")
        fi
    done

    # 3. Nothing exists yet (e.g., iTerm has never run on this machine).
    #    Use the Library default — it's what iTerm provisions by default,
    #    so the next iTerm launch will find our files there.
    printf '%s\n' "$AUTOLAUNCH_FALLBACK"
}

PLUGIN_DEST_BASE=$(resolve_autolaunch_dir)
PLUGIN_DEST="$PLUGIN_DEST_BASE/claude_hud"
PLUGIN_INNER="$PLUGIN_DEST/claude_hud"

# Resolve PLUGIN_DEST_BASE to its canonical form for display so symlinked
# layouts don't hide where the files actually landed. Source of issue #4:
# the installer printed a path that wasn't where iTerm read from.
PLUGIN_DEST_BASE_CANONICAL=$(canonical_path "$PLUGIN_DEST_BASE" 2>/dev/null || printf '%s' "$PLUGIN_DEST_BASE")

step "Resolved AutoLaunch root → $PLUGIN_DEST_BASE"
if [ "$PLUGIN_DEST_BASE_CANONICAL" != "$PLUGIN_DEST_BASE" ]; then
    printf '   (canonical: %s)\n' "$PLUGIN_DEST_BASE_CANONICAL"
fi
if [ -n "${CLAUDE_HUD_AUTOLAUNCH_DIR:-}" ]; then
    printf '   (via CLAUDE_HUD_AUTOLAUNCH_DIR env override)\n'
fi

step "Installing hooks → $HOOKS_DEST"
mkdir -p "$HOOKS_DEST"
cp "$REPO/hooks/"*.sh "$HOOKS_DEST/"
chmod +x "$HOOKS_DEST/"*.sh

step "Copying plugin → $PLUGIN_INNER (iTerm's required <name>/<name>/<name>.py layout)"
mkdir -p "$PLUGIN_INNER"
cp -R "$REPO/plugin/." "$PLUGIN_INNER/"

# Verify the copy landed where we expect. A wrong-path install used to
# fail silently — the Python module cache in the live plugin then kept
# serving the previous build, and reinstalls appeared to have no effect.
# Hard-fail here so the user knows immediately instead of debugging a
# stale-code symptom later. (issue #4 acceptance)
if [ ! -f "$PLUGIN_INNER/claude_hud.py" ]; then
    fail "Expected $PLUGIN_INNER/claude_hud.py to exist after copy — install failed. See clud/docs/SMOKE.md for diagnostics."
fi

step "Writing setup.cfg → $PLUGIN_DEST/setup.cfg"
# python_requires must match the interpreter iTerm provisions under
# iterm2env/versions/. If you upgrade iterm2env, update this version.
cat > "$PLUGIN_DEST/setup.cfg" <<'EOF'
[metadata]
name = claude_hud
version = 1.0

[options]
scripts = claude_hud/claude_hud.py
# certifi: iterm2env's Python has no CA store, so aiohttp can't verify HTTPS
# certs without it — both usage and status fetchers fail otherwise.
install_requires = iterm2; aiohttp; certifi
python_requires = =3.14.0

[iterm2]
environment = >=79
EOF

step "Settings snippet for ~/.claude/settings.json"
cat <<'EOF'
Add (or merge) the following into ~/.claude/settings.json:

  {
    "hooks": {
      "SessionStart": [{"hooks":[{"type":"command","command":"~/.claude/hooks/hud-session-start.sh"}]}],
      "PreToolUse":   [{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/hooks/hud-pre-tool.sh"}]}],
      "PostToolUse":  [{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/hooks/hud-post-tool.sh"}]}],
      "SessionEnd":   [{"hooks":[{"type":"command","command":"~/.claude/hooks/hud-session-end.sh"}]}]
    }
  }
EOF

step "iTerm2 setup"
cat <<EOF
1. Open iTerm2 → Settings → General → Magic → enable "Python API".
2. Scripts → Manage → New Python Script → Full Environment → name "claude_hud".
   This provisions iTerm's bundled Python at:
     $PLUGIN_DEST/iterm2env/versions/<python>/
   (iTerm refuses to launch the script without this — there's no way to
    skip the wizard and bring your own venv.)
3. Re-run this installer so the plugin sources overwrite the stub iTerm wrote.
4. Install the runtime deps into iTerm's bundled Python. Use 'python3 -m pip'
   because pip3's shebang is templated and breaks when invoked directly:
     "\$(ls -d "$PLUGIN_DEST/iterm2env/versions/"*/bin/python3 | head -1)" -m pip install aiohttp certifi
   (iterm2 is preinstalled by the Full Environment. certifi supplies the CA
    bundle iterm2env's Python lacks — without it both fetchers fail TLS
    verification and the strip shows "usage/Status unavailable".)
5. Restart iTerm. The plugin auto-launches; check it with:
     ps -ef | grep claude_hud
6. View → Toolbelt → Show Toolbelt   (⌘⇧B)
   Then in the toolbelt's gear/menu, check "Claude HUD".
EOF

# Python module cache pins old code: even after install.sh overwrites the
# files, the running plugin keeps serving the previous build until its
# process is restarted. This used to be the "reinstalls have no effect"
# symptom in issue #4; surface it explicitly.
step "Restart the running plugin to pick up changes"
cat <<'EOF'
If the plugin is already running, the Python module cache means it's still
holding the previous build in memory. Either restart iTerm, or:
     pkill -f claude_hud
…and let iTerm auto-relaunch it.
EOF

warn "If the toolbelt entry doesn't appear, see clud/docs/SMOKE.md and check iTerm2's Python script console for errors."
