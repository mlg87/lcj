#!/usr/bin/env bash
# clud/install.sh — one-shot install for Claude HUD.
#
# Copies the bash hooks into ~/.claude/hooks/ and the plugin into iTerm's
# AutoLaunch directory, then prints the manual steps still needed:
#   - Enabling iTerm's Python API
#   - Installing runtime deps into iTerm's full-environment venv
#   - Merging the hook config into ~/.claude/settings.json
#
# WHY the iTerm steps are manual: iTerm's full-environment script setup
# uses an interactive UI flow we can't fully script around; better to
# document it explicitly than to half-automate and confuse the user.
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
HOOKS_DEST="$HOME/.claude/hooks"
PLUGIN_DEST_BASE="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
PLUGIN_DEST="$PLUGIN_DEST_BASE/claude_hud"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!  \033[0m %s\n' "$1"; }

step "Installing hooks → $HOOKS_DEST"
mkdir -p "$HOOKS_DEST"
cp "$REPO/hooks/"*.sh "$HOOKS_DEST/"
chmod +x "$HOOKS_DEST/"*.sh

step "Copying plugin → $PLUGIN_DEST"
mkdir -p "$PLUGIN_DEST"
cp -R "$REPO/plugin/." "$PLUGIN_DEST/"

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
   This creates a venv at:
     $PLUGIN_DEST/iterm2env/
3. Activate that venv and install the runtime deps:
     source "$PLUGIN_DEST/iterm2env/versions/"*/bin/activate
     pip install aiohttp iterm2
4. Move iTerm's generated launcher out of the way (we use our own):
     mv "$PLUGIN_DEST/claude_hud.py" "$PLUGIN_DEST/.claude_hud.iterm.bak" 2>/dev/null || true
     ln -sf "$PLUGIN_DEST/claude_hud.py" "$PLUGIN_DEST/main.py"
5. Restart iTerm. View → Toolbelt → check "Claude HUD".
EOF

warn "If the toolbelt entry doesn't appear, see docs/SMOKE.md and check iTerm2's Python script console for errors."
