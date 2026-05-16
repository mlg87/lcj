#!/usr/bin/env bash
# clud/hooks/hud-post-tool.sh
# Fires after each tool invocation. Always clears current.json (the
# matching PreToolUse set it). For the TodoWrite tool, also persists
# the latest todos array to todos.json so the HUD can display them.
#
# WHY a single hook handles both:
#   Claude Code only allows one PostToolUse handler per matcher. Splitting
#   this into "clear current" + "todowrite snapshot" would either need
#   duplicate matchers or two separate command entries — adds surface area
#   for no benefit. One script with a case is clearer.
set -u
# shellcheck disable=SC2034
HOOK_NAME="hud-post-tool"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh disable=SC1091
source "$SCRIPT_DIR/lib.sh"

main() {
    local input
    input=$(cat)

    local session_id tool_name
    session_id=$(jq -r '.session_id // empty' <<<"$input")
    hud_validate_session_id "$session_id" || return 0
    tool_name=$(jq -r '.tool_name // empty' <<<"$input")

    local session_dir
    session_dir="$(hud_state_dir)/sessions/$session_id"

    # Always: clear current.json (idempotent — `rm -f` is silent on missing).
    rm -f "$session_dir/current.json"

    # If TodoWrite: persist the todos array verbatim. updated_at lets the
    # plugin show "todos updated 5s ago" if we ever surface that.
    if [ "$tool_name" = "TodoWrite" ]; then
        local todos now todos_json
        todos=$(jq -c '.tool_input.todos // []' <<<"$input")
        now=$(date +%s)
        todos_json=$(jq -n --argjson todos "$todos" --argjson now "$now" \
            '{updated_at: $now, todos: $todos}')
        hud_atomic_write "$session_dir/todos.json" "$todos_json"
    fi
}

hud_safe main
