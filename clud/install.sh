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
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
HOOKS_DEST="$HOME/.claude/hooks"
PLUGIN_DEST_BASE="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
PLUGIN_DEST="$PLUGIN_DEST_BASE/claude_hud"
PLUGIN_INNER="$PLUGIN_DEST/claude_hud"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!  \033[0m %s\n' "$1"; }

step "Installing hooks → $HOOKS_DEST"
mkdir -p "$HOOKS_DEST"
cp "$REPO/hooks/"*.sh "$HOOKS_DEST/"
chmod +x "$HOOKS_DEST/"*.sh

step "Copying plugin → $PLUGIN_INNER (iTerm's required <name>/<name>/<name>.py layout)"
mkdir -p "$PLUGIN_INNER"
cp -R "$REPO/plugin/." "$PLUGIN_INNER/"

step "Writing setup.cfg → $PLUGIN_DEST/setup.cfg"
# python_requires must match the interpreter iTerm provisions under
# iterm2env/versions/. If you upgrade iterm2env, update this version.
cat > "$PLUGIN_DEST/setup.cfg" <<'EOF'
[metadata]
name = claude_hud
version = 1.0

[options]
scripts = claude_hud/claude_hud.py
install_requires = iterm2; aiohttp
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
4. Install the runtime dep into iTerm's bundled Python. Use 'python3 -m pip'
   because pip3's shebang is templated and breaks when invoked directly:
     "\$(ls -d "$PLUGIN_DEST/iterm2env/versions/"*/bin/python3 | head -1)" -m pip install aiohttp
   (iterm2 is preinstalled by the Full Environment.)
5. Restart iTerm. The plugin auto-launches; check it with:
     ps -ef | grep claude_hud
6. View → Toolbelt → Show Toolbelt   (⌘⇧B)
   Then in the toolbelt's gear/menu, check "Claude HUD".
EOF

warn "If the toolbelt entry doesn't appear, see docs/SMOKE.md and check iTerm2's Python script console for errors."
