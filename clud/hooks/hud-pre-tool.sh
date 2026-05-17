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
#   Agent|Task   → description (shows "Implement Task 1: foo" etc.)
#   TaskCreate   → subject (the to-do being added)
#   TaskUpdate   → "<taskId> → <status>" so the HUD shows progression
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
        Agent | Task)
            jq -r '.description // ""' <<<"$input"
            ;;
        TaskCreate)
            jq -r '.subject // ""' <<<"$input"
            ;;
        TaskUpdate)
            jq -r '"\(.taskId) → \(.status // "?")"' <<<"$input"
            ;;
        *)
            printf ''
            ;;
    esac
}

# When the Agent tool starts, write a marker file the HUD reads to show
# "▶ Agent · <description> · 1m02s". One file per concurrent sub-agent,
# keyed by tool_use_id so PostToolUse / SubagentStop can remove the right
# one. tool_use_id comes from Claude's hook payload (PreToolUse contract).
write_subagent_marker() {
    local session_id="$1" input="$2" now="$3"
    local tool_use_id description subagent_type model run_in_bg subagents_dir
    # Some hook payloads use snake_case `tool_use_id`, others camelCase
    # `toolUseID` (the latter is documented in Claude's hook attachment
    # metadata; the former is what the docs claim is on stdin). Try both
    # so we don't silently skip the marker if the casing differs.
    tool_use_id=$(jq -r '.tool_use_id // .toolUseID // empty' <<<"$input")
    [ -z "$tool_use_id" ] && return 0
    description=$(jq -r '.tool_input.description // ""' <<<"$input")
    subagent_type=$(jq -r '.tool_input.subagent_type // "general-purpose"' <<<"$input")
    model=$(jq -r '.tool_input.model // ""' <<<"$input")
    run_in_bg=$(jq -r '.tool_input.run_in_background // false' <<<"$input")

    subagents_dir="$(hud_state_dir)/sessions/$session_id/subagents"
    local marker
    marker=$(jq -n \
        --arg id "$tool_use_id" \
        --arg desc "$description" \
        --arg type "$subagent_type" \
        --arg model "$model" \
        --argjson bg "$run_in_bg" \
        --argjson now "$now" \
        '{
            tool_use_id: $id,
            description: $desc,
            subagent_type: $type,
            model: $model,
            run_in_background: $bg,
            started_at: $now
        }')
    hud_atomic_write "$subagents_dir/$tool_use_id.json" "$marker"
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

    # Agent / Task = "spawn a sub-agent". Record so the HUD can show it
    # alongside the parent's running tool. PostToolUse / SubagentStop clear it.
    case "$tool_name" in
        Agent | Task)
            write_subagent_marker "$session_id" "$input" "$now"
            ;;
    esac
}

hud_safe main
