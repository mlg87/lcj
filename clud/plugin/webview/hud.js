// clud/plugin/webview/hud.js
//
// Subscribes to /events SSE and patches the DOM on each snapshot.
// EventSource auto-reconnects on disconnect so we don't need any
// reconnection logic of our own.
//
// Security: we never use innerHTML with snapshot content — all text
// goes through textContent, and the todo status icon is rendered via
// a CSS attr() rule using a data-icon attribute. This makes the
// webview safe even if the SSE source is somehow compromised.

const els = {
  hud:            document.getElementById("hud"),
  model:          document.getElementById("model"),
  project:        document.getElementById("project"),
  current:        document.getElementById("current"),
  currentName:    document.getElementById("current-name"),
  currentSummary: document.getElementById("current-summary"),
  currentElapsed: document.getElementById("current-elapsed"),
  todos:          document.getElementById("todos"),
  todosCount:     document.getElementById("todos-count"),
  progressBar:    document.getElementById("progress-bar"),
  lastUpdated:    document.getElementById("last-updated"),
};

const ICON = { completed: "✓", in_progress: "▶", pending: "○" };
// If a tool has been "running" for >10min, it's almost certainly that
// PreToolUse fired but PostToolUse never did (claude crashed mid-tool).
// Show "interrupted?" rather than letting the timer tick up indefinitely.
const STALE_MS = 10 * 60 * 1000;

let lastSnapshot = null;
let lastReceivedAt = 0;

function render(snapshot) {
  if (!snapshot || !snapshot.session) {
    els.hud.dataset.state = "empty";
    return;
  }
  els.hud.dataset.state = "ready";

  els.model.textContent   = snapshot.session.model || "?";
  els.project.textContent = basename(snapshot.session.project);

  if (snapshot.current) {
    els.current.classList.remove("hidden");
    els.currentName.textContent    = snapshot.current.tool_name || "";
    els.currentSummary.textContent = snapshot.current.input_summary || "";
    const elapsed = snapshot.current.running_for_ms || 0;
    els.currentElapsed.textContent =
      elapsed > STALE_MS ? "interrupted?" : formatElapsed(elapsed);
  } else {
    els.current.classList.add("hidden");
  }

  // Replace all <li>s in one shot. replaceChildren() is the safe modern
  // alternative to setting innerHTML — no parsing, no XSS surface.
  const todos = snapshot.todos || [];
  const liElements = todos.map(t => {
    const li = document.createElement("li");
    li.dataset.status = t.status;
    li.dataset.icon = ICON[t.status] || "?";
    li.textContent = t.content;
    return li;
  });
  els.todos.replaceChildren(...liElements);

  const done = todos.filter(t => t.status === "completed").length;
  els.todosCount.textContent = `${done}/${todos.length}`;
  els.progressBar.style.width = todos.length ? `${(done / todos.length) * 100}%` : "0";

  els.lastUpdated.textContent = "just now";
}

function basename(path) {
  if (!path) return "";
  const parts = path.split("/").filter(Boolean);
  return parts[parts.length - 1] || path;
}

function formatElapsed(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  return `${Math.floor(s / 60)}m${(s % 60).toString().padStart(2, "0")}s`;
}

// Tick the "last updated" + current-tool elapsed every 500ms so the UI
// feels alive between snapshot pushes (which only happen on state change).
setInterval(() => {
  if (!lastSnapshot) return;
  const ageS = Math.floor((Date.now() - lastReceivedAt) / 1000);
  els.lastUpdated.textContent = ageS < 2 ? "just now" : `${ageS}s ago`;
  if (lastSnapshot.current) {
    const total = (lastSnapshot.current.running_for_ms || 0)
                + (Date.now() - lastReceivedAt);
    els.currentElapsed.textContent =
      total > STALE_MS ? "interrupted?" : formatElapsed(total);
  }
}, 500);

const source = new EventSource("/events");
source.onmessage = (event) => {
  try {
    lastSnapshot = JSON.parse(event.data);
    lastReceivedAt = Date.now();
    render(lastSnapshot);
  } catch (e) {
    console.error("bad snapshot", e);
  }
};
