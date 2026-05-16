# Claude HUD — Smoke Test Checklist

Run after any change to hooks or plugin. Takes ~2 minutes.

1. **Restart iTerm** with the auto-launch script in place.
   - Verify "Claude HUD" appears under **View → Toolbelt**.

2. **Open the HUD panel** (`⌘⇧B` if hidden, then check "Claude HUD").
   - Verify "no Claude session in this tab" empty state in a fresh tab.

3. **Run `claude`** in the tab.
   - Verify session header (model, project basename) appears within ~200ms.

4. **Trigger any tool call** (e.g. ask Claude to `git status`).
   - Verify `▶ Bash · Xs` appears in the "current" line and clears when the tool returns.

5. **Trigger TodoWrite** (e.g. ask Claude to plan a small feature).
   - Verify todos render with correct status icons (✓ completed, ▶ in_progress, ○ pending).
   - Verify the progress bar fills proportionally.

6. **Open a second tab, run another `claude`, switch focus** between tabs.
   - Verify HUD swaps to the focused session's state within ~200ms.

If anything misbehaves, check:
- `~/.claude/state/hud/errors.log` (hook errors)
- iTerm's Python script console (plugin errors)
- `~/.claude/state/hud/diagnostics.json` (plugin diagnostics, when present)
