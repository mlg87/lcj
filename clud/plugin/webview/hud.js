// clud/plugin/webview/hud.js
//
// Subscribes to /events SSE and patches the DOM on each snapshot.
// EventSource auto-reconnects on disconnect so we don't need any
// reconnection logic of our own.
//
// Snapshot shape (multi-session):
//   {focused_tty: "/dev/ttys001", sessions: [{tty, session, current, todos, subagents}, ...]}
//
// We keep one .card per session_id in the DOM and patch in place so the
// browser doesn't reflow the whole list every snapshot. Cards are cloned
// from the <template id="session-card"> in index.html.
//
// Security: we never use innerHTML with snapshot content — all text
// goes through textContent. Todo status icons are rendered via a CSS
// attr() rule on data-icon, so even a malicious snapshot can't inject markup.

const els = {
  hud:         document.getElementById("hud"),
  sessions:    document.getElementById("sessions"),
  lastUpdated: document.getElementById("last-updated"),
  template:    document.getElementById("session-card"),
};

const ICON = { completed: "✓", in_progress: "▶", pending: "○" };
// If a tool has been "running" for >10min, it's almost certainly that
// PreToolUse fired but PostToolUse never did (claude crashed mid-tool).
// Show "interrupted?" rather than letting the timer tick up indefinitely.
const STALE_MS = 10 * 60 * 1000;

// session_id → {card, snapshot} so we can patch in place and avoid full
// re-renders. Cards live in els.sessions in tty insertion order.
const cardsBySessionId = new Map();
let lastSnapshot = null;
let lastReceivedAt = 0;

function render(snapshot) {
  if (!snapshot || !snapshot.sessions || snapshot.sessions.length === 0) {
    els.hud.dataset.state = "empty";
    // Drop stale cards so when sessions come back the DOM is fresh.
    els.sessions.replaceChildren();
    cardsBySessionId.clear();
    return;
  }
  els.hud.dataset.state = "ready";

  const focusedTty = snapshot.focused_tty;
  const seenIds = new Set();

  // First pass: ensure a card exists for every session in the snapshot.
  // We preserve tty-map order so the user's mental model of "tab 1 / tab 2"
  // matches the HUD's visual order.
  snapshot.sessions.forEach((sess, idx) => {
    const sid = sess.session && sess.session.id;
    if (!sid) return;
    seenIds.add(sid);
    let entry = cardsBySessionId.get(sid);
    if (!entry) {
      const card = els.template.content.firstElementChild.cloneNode(true);
      entry = { card };
      cardsBySessionId.set(sid, entry);
    }
    // Re-attach in the order the snapshot listed them so reordered tabs
    // (e.g. user dragged a pane) show up in the new order without churn.
    if (els.sessions.children[idx] !== entry.card) {
      els.sessions.insertBefore(entry.card, els.sessions.children[idx] || null);
    }
    entry.snapshot = sess;
    renderCard(entry.card, sess, sess.tty === focusedTty);
  });

  // Second pass: evict cards for sessions that disappeared (claude exited).
  for (const [sid, entry] of cardsBySessionId) {
    if (!seenIds.has(sid)) {
      entry.card.remove();
      cardsBySessionId.delete(sid);
    }
  }

  els.lastUpdated.textContent = "just now";
}

function renderCard(card, snap, focused) {
  card.dataset.focused = focused ? "1" : "0";

  card.querySelector(".model").textContent = (snap.session && snap.session.model) || "?";
  card.querySelector(".project").textContent = basename(snap.session && snap.session.project);

  const currentEl = card.querySelector(".current");
  if (snap.current) {
    currentEl.classList.remove("hidden");
    currentEl.querySelector(".tool").textContent    = snap.current.tool_name || "";
    currentEl.querySelector(".summary").textContent = snap.current.input_summary || "";
    const ms = snap.current.running_for_ms || 0;
    currentEl.querySelector(".elapsed").textContent =
      ms > STALE_MS ? "interrupted?" : formatElapsed(ms);
  } else {
    currentEl.classList.add("hidden");
  }

  // Sub-agents.
  const subagents = snap.subagents || [];
  const saWrap = card.querySelector(".subagents-wrap");
  const saList = card.querySelector(".subagents");
  if (subagents.length > 0) {
    saWrap.classList.remove("hidden");
    card.querySelector(".subagents-count").textContent = String(subagents.length);
    saList.replaceChildren(...subagents.map(renderSubagentRow));
  } else {
    saWrap.classList.add("hidden");
    saList.replaceChildren();
  }

  // Todos. Replace all <li>s in one shot. replaceChildren() is the safe
  // modern alternative to setting innerHTML — no parsing, no XSS surface.
  const todos = snap.todos || [];
  const liElements = todos.map(t => {
    const li = document.createElement("li");
    li.dataset.status = t.status;
    li.dataset.icon = ICON[t.status] || "?";
    // New TaskCreate-shaped rows have `subject` instead of `content`; fall
    // back so legacy TodoWrite rows (just `content`) still render.
    li.textContent = t.content || t.subject || "";
    return li;
  });
  card.querySelector(".todos").replaceChildren(...liElements);

  // Skip "deleted" status if it ever leaks through so it doesn't skew the bar.
  const visible = todos.filter(t => t.status !== "deleted");
  const done = visible.filter(t => t.status === "completed").length;
  card.querySelector(".todos-count").textContent = `${done}/${visible.length}`;
  card.querySelector(".progress .bar").style.width =
    visible.length ? `${(done / visible.length) * 100}%` : "0";
}

function renderSubagentRow(sa) {
  const li = document.createElement("li");
  li.className = "subagent";
  if (sa.run_in_background) li.dataset.bg = "1";

  const desc = document.createElement("span");
  desc.className = "desc";
  desc.textContent = sa.description || sa.subagent_type || "(sub-agent)";

  const meta = document.createElement("span");
  meta.className = "meta";
  const parts = [];
  if (sa.subagent_type) parts.push(sa.subagent_type);
  if (sa.model) parts.push(sa.model);
  if (sa.run_in_background) parts.push("bg");
  meta.textContent = parts.join(" · ");

  const elapsed = document.createElement("span");
  elapsed.className = "elapsed";
  const ms = sa.running_for_ms || 0;
  elapsed.textContent = ms > STALE_MS ? "interrupted?" : formatElapsed(ms);

  li.append(desc, meta, elapsed);
  return li;
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

// Tick the "last updated" + all live elapsed counters every 500ms so the
// UI feels alive between snapshot pushes (which only happen on state change).
setInterval(() => {
  if (!lastSnapshot) return;
  const ageS = Math.floor((Date.now() - lastReceivedAt) / 1000);
  els.lastUpdated.textContent = ageS < 2 ? "just now" : `${ageS}s ago`;
  const sinceLast = Date.now() - lastReceivedAt;

  for (const { card, snapshot } of cardsBySessionId.values()) {
    if (snapshot.current) {
      const total = (snapshot.current.running_for_ms || 0) + sinceLast;
      const el = card.querySelector(".current .elapsed");
      if (el) el.textContent = total > STALE_MS ? "interrupted?" : formatElapsed(total);
    }
    const saRows = card.querySelectorAll(".subagent");
    const sas = snapshot.subagents || [];
    for (let i = 0; i < saRows.length && i < sas.length; i++) {
      const total = (sas[i].running_for_ms || 0) + sinceLast;
      const el = saRows[i].querySelector(".elapsed");
      if (el) el.textContent = total > STALE_MS ? "interrupted?" : formatElapsed(total);
    }
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
