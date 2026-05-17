#!/usr/bin/env bash
# clud/hooks/hud-post-tool.sh
# Fires after each tool invocation. Always clears current.json (the
# matching PreToolUse set it). Tool-specific persistence:
#   - TodoWrite           → overwrite todos.json with the full array (legacy)
#   - TaskCreate          → append the new task to todos.json (agent-teams)
#   - TaskUpdate          → mutate the matching task in todos.json
#   - Agent (foreground)  → delete subagents/<tool_use_id>.json (the marker
#                            written by hud-pre-tool.sh; clears the HUD row)
#
# WHY a single hook handles all of this:
#   Claude Code only allows one PostToolUse handler per matcher. Splitting
#   per-tool would either need duplicate matchers or many command entries —
#   for no benefit. One script with a case dispatch is clearer.
#
# WHY we maintain todos.json incrementally for Task*:
#   Unlike legacy TodoWrite (which posts the full snapshot every call),
#   the agent-teams Task* tools mutate one task at a time. The hook reads
#   the prior todos.json, applies the delta, and writes back atomically.
#   See `todos_apply_task_*` helpers.
set -u
# shellcheck disable=SC2034
HOOK_NAME="hud-post-tool"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh disable=SC1091
source "$SCRIPT_DIR/lib.sh"

# Read the current todos.json (or an empty doc if missing/corrupt) and
# re-emit it with the given jq filter applied. Args after the filter are
# forwarded as jq --arg / --argjson pairs. $now is always pre-bound.
todos_mutate() {
    local session_dir="$1" filter="$2"; shift 2
    local path="$session_dir/todos.json"
    local current
    if [ -s "$path" ]; then
        current=$(cat "$path")
    else
        current='{"updated_at":0,"todos":[]}'
    fi
    local now next
    now=$(date +%s)
    next=$(jq --argjson now "$now" "$filter" "$@" <<<"$current") || return 1
    hud_atomic_write "$path" "$next"
}

# TaskCreate payload (from stdin tool_input + tool_response):
#   input: {subject, description, activeForm?, metadata?}
#   response: {task: {id, subject}}  ← id is the canonical key
# We coalesce these into a todo row that's a superset of the legacy shape,
# so the frontend and state_reader keep working unchanged on old fields.
todos_apply_task_create() {
    local session_dir="$1" input="$2"
    local id subject active_form description
    id=$(jq -r '.tool_response.task.id // empty' <<<"$input")
    subject=$(jq -r '.tool_input.subject // ""' <<<"$input")
    active_form=$(jq -r '.tool_input.activeForm // ""' <<<"$input")
    description=$(jq -r '.tool_input.description // ""' <<<"$input")
    # No id ⇒ we can't track this task across updates; skip silently.
    [ -z "$id" ] && return 0
    # shellcheck disable=SC2016  # $now/$id/$subject/etc. are jq bindings, not shell vars
    todos_mutate "$session_dir" \
        '.updated_at = $now
         | .todos += [{
             id: $id,
             content: $subject,
             status: "pending",
             activeForm: $af,
             description: $desc
         }]' \
        --arg id "$id" \
        --arg subject "$subject" \
        --arg af "$active_form" \
        --arg desc "$description"
}

# TaskUpdate payload:
#   input: {taskId, status?, subject?, activeForm?, owner?, description?, ...}
# Status "deleted" removes the row entirely (matches the tool's "permanently
# remove" semantics). Any other status update mutates in place; if the row
# isn't in our local todos.json (e.g. created before HUD started), append it
# so the HUD doesn't silently drop late-arriving updates.
todos_apply_task_update() {
    local session_dir="$1" input="$2"
    local id status
    id=$(jq -r '.tool_input.taskId // empty' <<<"$input")
    [ -z "$id" ] && return 0
    status=$(jq -r '.tool_input.status // empty' <<<"$input")
    if [ "$status" = "deleted" ]; then
        # shellcheck disable=SC2016  # jq bindings
        todos_mutate "$session_dir" \
            '.updated_at = $now | .todos |= map(select(.id != $id))' \
            --arg id "$id"
        return 0
    fi
    # Build a patch object of only the fields the user supplied so we don't
    # overwrite existing values with empty strings.
    local patch
    patch=$(jq -c '
        .tool_input
        | { status, activeForm, owner, description, content: .subject }
        | with_entries(select(.value != null))
    ' <<<"$input")
    # shellcheck disable=SC2016  # jq bindings
    todos_mutate "$session_dir" '
        .updated_at = $now
        | if any(.todos[]; .id == $id) then
            .todos |= map(if .id == $id then . + $patch else . end)
          else
            .todos += [({id: $id, content: "", status: "pending", activeForm: ""} + $patch)]
          end
    ' --arg id "$id" --argjson patch "$patch"
}

# Foreground Agent calls: PreTool wrote the marker, we remove it now. Background
# agents (run_in_background=true) keep the marker so the HUD shows them as
# still running — the SubagentStop hook clears them when they actually finish.
subagent_clear_if_foreground() {
    local session_dir="$1" input="$2"
    local tool_use_id run_in_bg
    # Match hud-pre-tool.sh: accept both snake_case and camelCase.
    tool_use_id=$(jq -r '.tool_use_id // .toolUseID // empty' <<<"$input")
    [ -z "$tool_use_id" ] && return 0
    run_in_bg=$(jq -r '.tool_input.run_in_background // false' <<<"$input")
    [ "$run_in_bg" = "true" ] && return 0
    rm -f "$session_dir/subagents/$tool_use_id.json"
    # Clean empty dir so state_reader doesn't list an empty subagents key.
    rmdir "$session_dir/subagents" 2>/dev/null || true
}

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

    case "$tool_name" in
        TodoWrite)
            # Legacy snapshot semantics: input.todos is the full list.
            local todos now todos_json
            todos=$(jq -c '.tool_input.todos // []' <<<"$input")
            now=$(date +%s)
            todos_json=$(jq -n --argjson todos "$todos" --argjson now "$now" \
                '{updated_at: $now, todos: $todos}')
            hud_atomic_write "$session_dir/todos.json" "$todos_json"
            ;;
        TaskCreate)
            todos_apply_task_create "$session_dir" "$input"
            ;;
        TaskUpdate)
            todos_apply_task_update "$session_dir" "$input"
            ;;
        Agent)
            subagent_clear_if_foreground "$session_dir" "$input"
            ;;
    esac
}

hud_safe main
