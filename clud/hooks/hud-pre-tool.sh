#!/usr/bin/env bash
# clud/hooks/hud-pre-tool.sh
# Fires before each tool invocation. Writes a "tool currently running"
# marker so the HUD can show "▶ Bash · 2.3s" or similar.
#
# WHY input_summary is computed here (not in the plugin):
#   The plugin treats current.json as opaque — it just renders whatever
#   `input_summary` contains. That keeps the plugin tool-agnostic; adding
#   a nicer summary for a new tool means editing only this case statement.
set -u
# shellcheck disable=SC2034
HOOK_NAME="hud-pre-tool"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

# Per-tool input summary derivation:
#   Bash         → first line of `command`, truncated to 80 chars
#   Read|Edit|Write|NotebookEdit → file_path
#   Grep         → search pattern
#   anything else → "" (the tool_name alone is enough info)
input_summary() {
    local tool="$1" input="$2"
    case "$tool" in
        Bash)
            jq -r '.command // ""' <<<"$input" | head -n1 | cut -c1-80
            ;;
        Read | Edit | Write | NotebookEdit)
            jq -r '.file_path // ""' <<<"$input"
            ;;
        Grep)
            jq -r '.pattern // ""' <<<"$input"
            ;;
        *)
            printf ''
            ;;
    esac
}

main() {
    local input
    input=$(cat)

    local session_id tool_name tool_input
    session_id=$(jq -r '.session_id // empty' <<<"$input")
    hud_validate_session_id "$session_id" || return 0
    tool_name=$(jq -r '.tool_name // empty' <<<"$input")
    tool_input=$(jq -c '.tool_input // {}' <<<"$input")
    [ -z "$tool_name" ] && return 0

    local summary now
    summary=$(input_summary "$tool_name" "$tool_input")
    now=$(date +%s)

    local current_path
    current_path="$(hud_state_dir)/sessions/$session_id/current.json"
    local current
    current=$(jq -n \
        --arg name "$tool_name" \
        --arg summary "$summary" \
        --argjson now "$now" \
        '{tool_name: $name, input_summary: $summary, started_at: $now}')
    hud_atomic_write "$current_path" "$current"
}

hud_safe main
