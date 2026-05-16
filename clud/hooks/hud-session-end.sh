#!/usr/bin/env bash
# clud/hooks/hud-session-end.sh
# Removes this session_id from tty-map.json and stamps meta.ended_at.
# Happy-path cleanup; the plugin also GCs crashed sessions that never
# fired this hook (see plugin/tty_resolver.gc_dead_sessions).
set -u
# shellcheck disable=SC2034
HOOK_NAME="hud-session-end"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

main() {
    local input
    input=$(cat)

    local session_id now
    session_id=$(jq -r '.session_id // empty' <<<"$input")
    hud_validate_session_id "$session_id" || return 0
    now=$(date +%s)

    # Remove all tty-map entries pointing at this session_id. We filter by
    # session_id (not by tty) because we can't trust HUD_TTY_OVERRIDE here —
    # SessionEnd may run from a different shell than SessionStart did.
    hud_map_edit \
        "with_entries(select(.value.session_id != \$id))" \
        --arg id "$session_id"

    # Stamp ended_at on meta.json if it exists. Don't recreate it from scratch
    # if missing — that would lose the rest of the metadata.
    local meta_path
    meta_path="$(hud_state_dir)/sessions/$session_id/meta.json"
    if [ -f "$meta_path" ]; then
        local updated
        updated=$(jq --argjson now "$now" '.ended_at = $now' "$meta_path")
        hud_atomic_write "$meta_path" "$updated"
    fi
}

hud_safe main
