#!/usr/bin/env bash
# clud/hooks/lib.sh — shared helpers for HUD hook scripts.
# Sourced by hud-*.sh; not executed directly.
#
# Architecture role:
#   The hooks are the WRITE side of the HUD's filesystem contract under
#   ~/.claude/state/hud/. They capture Claude Code session events from
#   stdin (per Claude's hook protocol) and produce JSON state files that
#   the iTerm Python plugin reads. Hooks must NEVER fail Claude:
#   every hook wraps its body in `hud_safe`, which logs errors and exits 0.
#
# Concurrency:
#   tty-map.json is shared across all sessions, so SessionStart/End edits
#   are wrapped in flock (see hud_map_edit). Per-session state files
#   (meta/todos/current.json) are owned by exactly one session and don't
#   need locking.
#
# Atomicity:
#   All JSON writes use tmp-file + rename, so readers (the plugin) never
#   observe a torn write. POSIX rename(2) is atomic on the same filesystem.

# State dir respects HUD_STATE_DIR for testing; defaults to ~/.claude/state/hud.
hud_state_dir() {
    printf '%s' "${HUD_STATE_DIR:-$HOME/.claude/state/hud}"
}

# Append a timestamped error line to errors.log. Never fails — error logging
# is best-effort and must not propagate failures back into the hook.
hud_log_error() {
    local msg="$1"
    local dir
    dir=$(hud_state_dir)
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${HOOK_NAME:-?}" "$msg" \
        >> "$dir/errors.log" 2>/dev/null || true
}

# Atomic JSON write: writes to a sibling tmp file in the same dir, then renames.
# Same-filesystem rename is required for atomicity, hence the sibling tmp.
hud_atomic_write() {
    local dest="$1"
    local content="$2"
    local dir
    dir=$(dirname "$dest")
    mkdir -p "$dir"
    local tmp
    tmp=$(mktemp "$dir/.tmp.XXXXXX")
    printf '%s' "$content" > "$tmp"
    mv -f "$tmp" "$dest"
}

# Resolve the controlling tty in the form "/dev/ttys003" — this matches
# what iTerm's `tty` session variable returns, so the read side can do a
# straight key lookup without normalization.
#
# Honors HUD_TTY_OVERRIDE so tests don't depend on the host's real tty.
hud_tty() {
    local raw="${HUD_TTY_OVERRIDE:-$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')}"
    case "$raw" in
        "" | "?" | "??")     printf '' ;;        # no controlling tty (daemon, etc.)
        /dev/*)              printf '%s' "$raw" ;;
        ttys*)               printf '/dev/%s' "$raw" ;;
        s[0-9]*)             printf '/dev/tty%s' "$raw" ;;  # very old ps
        *)                   printf '/dev/%s' "$raw" ;;
    esac
}

# Edit tty-map.json under flock. Args:
#   $1 = jq filter operating on the current map (object)
#   remaining args = jq --arg / --argjson pairs forwarded as-is
hud_map_edit() {
    local filter="$1"; shift
    local map
    map="$(hud_state_dir)/tty-map.json"
    local lock="$map.lock"
    mkdir -p "$(dirname "$map")"
    : >> "$lock"  # touch the lockfile so flock has a target
    (
        flock 9
        local current="{}"
        [ -s "$map" ] && current=$(cat "$map")
        local next
        next=$(jq "$filter" "$@" <<<"$current") || return 1
        hud_atomic_write "$map" "$next"
    ) 9>"$lock"
}

# Wrap any hook body so it never fails the parent (Claude). Logs errors and
# exits 0. Stderr from the body is captured line-by-line and routed to
# the error log so we don't lose diagnostic info.
hud_safe() {
    "$@" 2> >(while IFS= read -r line; do hud_log_error "$line"; done) || hud_log_error "non-zero exit"
    exit 0
}
