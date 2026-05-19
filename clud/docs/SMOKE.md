# Claude HUD — Smoke Test Checklist

Run after any change to hooks or plugin. Takes ~2 minutes.

1. **Restart iTerm** with the auto-launch script in place.
   - Verify "Claude HUD" appears under **View → Toolbelt**.

2. **Open the HUD panel** (`⌘⇧B` if hidden, then check "Claude HUD").
   - Verify "No Claude sessions running." empty state when nothing is running.

3. **Run `claude`** in the tab.
   - Verify a session card appears within ~200ms with the project basename as the header label.
   - When the model name isn't known (SessionStart hook payload doesn't expose it as of writing), no bare `?` appears — the header is just the label.
   - Run `/rename my-name` (or launch with `claude -n my-name`). Within one poll cycle (~200ms) the header label should switch to `my-name`. Rename again — the label updates again.
   - With two `claude` sessions in the same project, give them different `/rename` names and confirm both cards show distinct labels.

4. **Trigger any tool call** (e.g. ask Claude to `git status`).
   - Verify `▶ Bash · Xs` appears in the "current" line and clears when the tool returns.

5. **Trigger TodoWrite** (legacy) or **TaskCreate / TaskUpdate** (agent-teams mode, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`).
   - Verify todos render with correct status icons (✓ completed, ▶ in_progress, ○ pending).
   - Verify the progress bar fills proportionally.
   - For Task*: a single TaskCreate appends one row; a TaskUpdate to `status: "in_progress"` switches the icon; `status: "deleted"` removes the row.

6. **Spawn a sub-agent** (`Agent` tool, e.g. ask Claude to dispatch a sub-agent).
   - Verify a row appears in the "Sub-agents" section with the description, subagent_type · model, and a ticking elapsed time.
   - For a foreground sub-agent, the row disappears once it returns.
   - For a backgrounded sub-agent (`run_in_background: true`), the row gets a `· bg` tag and stays until the agent finishes.

7. **Open a second tab, run another `claude`, switch focus** between tabs.
   - Verify both sessions appear as separate cards stacked top-to-bottom.
   - Verify the focused tab's card has the brighter accent (left border + panel background).
   - Verify switching focus between tabs flips the accent within ~200ms — both cards stay visible the whole time.

8. **Remote-control indicator** (issue #6). With at least one Claude session running:
   - Discover the session id from the HUD state dir:
     `SID=$(ls -1 ~/.claude/state/hud/sessions | head -1)`
   - Light the indicator:
     `printf '{"channel":"manual","last_remote_at":%s}' "$(date +%s)" \
        > ~/.claude/state/hud/sessions/$SID/remote.json`
     Expected: the `◉` glyph appears in that card's header within ~200 ms,
     in the same accent color as the focused-card outline. Hovering it
     reveals `Remote-control enabled (manual) · last 0s ago`.
   - Toggle off:
     `rm ~/.claude/state/hud/sessions/$SID/remote.json`
     Expected: the glyph disappears within ~200 ms.
   - Corrupt write (no crash, no indicator):
     `printf 'not valid json' > ~/.claude/state/hud/sessions/$SID/remote.json`
     Expected: no indicator, no console error in the iTerm Python script
     console, the HUD keeps running. Clean up with `rm` after.
   - Oversized channel (presence still lights, tooltip bare):
     `printf '{"channel":"%s"}' "$(printf 'x%.0s' {1..100})" \
        > ~/.claude/state/hud/sessions/$SID/remote.json`
     Expected: indicator on; tooltip reads `Remote-control enabled`
     (no channel suffix). Clean up with `rm`.
   - Verify cards without `remote.json` are pixel-identical to before
     this PR — no stray whitespace at the end of the header, no glyph.

If anything misbehaves, check:
- `~/.claude/state/hud/errors.log` (hook errors)
- iTerm's Python script console (plugin errors)
- `~/.claude/state/hud/diagnostics.json` (plugin diagnostics, when present)
