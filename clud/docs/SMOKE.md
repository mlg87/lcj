# Claude HUD — Smoke Test Checklist

Run after any change to hooks or plugin. Takes ~2 minutes.

1. **Restart iTerm** with the auto-launch script in place.
   - Verify "Claude HUD" appears under **View → Toolbelt**.

2. **Open the HUD panel** (`⌘⇧B` if hidden, then check "Claude HUD").
   - Verify "No Claude sessions running." empty state when nothing is running.

3. **Run `claude`** in the tab.
   - Verify a session card appears with the project basename within ~200ms.
   - Model will show "?" — the SessionStart hook payload doesn't expose the model name as of writing. Not a bug.

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

If anything misbehaves, check:
- `~/.claude/state/hud/errors.log` (hook errors)
- iTerm's Python script console (plugin errors)
- `~/.claude/state/hud/diagnostics.json` (plugin diagnostics, when present)
