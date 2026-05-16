#!/usr/bin/env bash
# clud/hooks/hud-session-start.sh
# Fires when Claude Code starts a session. Reads {session_id, source,
# transcript_path, cwd} from stdin (Claude's hook protocol) and writes:
#   1. sessions/<session_id>/meta.json   — full session metadata
#   2. tty-map.json                      — adds {tty: {session_id, pid, ts}}
#
# WHY two files: per-session state lives in its own dir for clean lifecycle
# (write-once-per-event, easy GC on SessionEnd). tty-map.json is the
# shared lookup table the plugin needs to resolve focused tty → session.
set -u
# shellcheck disable=SC2034
HOOK_NAME="hud-session-start"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=./lib.sh disable=SC1091
source "$SCRIPT_DIR/lib.sh"

main() {
    local input
    input=$(cat)

    local session_id
    session_id=$(jq -r '.session_id // empty' <<<"$input")
    hud_validate_session_id "$session_id" || return 0

    local cwd transcript_path now tty
    cwd=$(jq -r '.cwd // ""' <<<"$input")
    transcript_path=$(jq -r '.transcript_path // ""' <<<"$input")
    now=$(date +%s)
    tty=$(hud_tty)

    # meta.json: model is null at start (Claude doesn't expose it via this hook
    # payload as of writing); ended_at: null is the live-session sentinel.
    local meta_path
    meta_path="$(hud_state_dir)/sessions/$session_id/meta.json"
    local meta
    meta=$(jq -n \
        --arg id "$session_id" \
        --arg project "$cwd" \
        --arg transcript "$transcript_path" \
        --argjson now "$now" \
        '{
            session_id: $id,
            model: null,
            project: $project,
            transcript_path: $transcript,
            started_at: $now,
            last_updated: $now,
            ended_at: null
        }')
    hud_atomic_write "$meta_path" "$meta"

    # Only record a tty-map entry if we actually got a tty — daemon/no-tty
    # contexts (CI, VS Code task runner, etc.) shouldn't poison the map.
    if [ -n "$tty" ]; then
        hud_map_edit \
            ". + {(\$tty): {session_id: \$id, claude_pid: \$pid, started_at: \$now}}" \
            --arg tty "$tty" \
            --arg id "$session_id" \
            --argjson pid "$PPID" \
            --argjson now "$now"
    fi
}

hud_safe main
