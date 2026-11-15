// Shared by the public page and the admin page. Configured via data attributes on <main>:
// data-post = URL for submitting the form, data-admin = "1" shows moderation buttons.
// All server-provided text is rendered with textContent only.
const main = document.querySelector("main");
const POST_URL = main.dataset.post;
const ADMIN = main.dataset.admin === "1";
const LABELS = {waiting: "czeka na akceptację", rejected: "odrzucone", queued: "w kolejce", resolving: "łączenie…", downloading: "pobieranie", done: "gotowe", failed: "błąd"};
const expanded = new Set();  // job ids whose description the user opened; survives re-renders
const fmt = b => b == null ? "?" : b < 1048576 ? (b / 1024).toFixed(0) + " KB" : (b / 1048576).toFixed(1) + " MB";
const msg = document.getElementById("msg");

function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

function describe(j) {
  const wrap = el("div");
  const open = expanded.has(j.id);
  const d = el("div", open ? "desc" : "desc clamped", j.description);
  wrap.append(d);
  if (j.description.split("\n").length > 3 || j.description.length > 200) {
    const b = el("button", "more", open ? "mniej" : "więcej");
    b.type = "button";
    b.addEventListener("click", () => {
      const clamped = d.classList.toggle("clamped");
      if (clamped) expanded.delete(j.id); else expanded.add(j.id);
      b.textContent = clamped ? "więcej" : "mniej";
    });
    wrap.append(b);
  }
  return wrap;
}

function actions(defs, j) {
  const box = el("div", "actions");
  for (const [label, action, cls] of defs) {
    const b = el("button", cls, label);
    b.type = "button";
    b.addEventListener("click", async () => {
      b.disabled = true;
      try {
        const r = await fetch(`/admin/requests/${j.id}/${action}`, {method: "POST"});
        if (!r.ok) msg.textContent = (await r.json()).detail || "Błąd";
      } catch (e) { msg.textContent = "Brak połączenia z serwerem"; }
      await refresh();
    });
    box.append(b);
  }
  return box;
}

function render(jobs) {
  const ul = document.getElementById("jobs");
  ul.replaceChildren();
  if (!jobs.length) { ul.append(el("li", "empty", "Brak próśb.")); return; }
  if (ADMIN) {
    const rank = j => j.status === "waiting" ? 0 : 1;
    jobs = jobs.slice().sort((x, y) => rank(x) - rank(y) || y.id - x.id);
  }
  for (const j of jobs) {
    const li = el("li", j.status);
    const top = el("div", "top");
    top.append(el("span", "name", j.filename || j.name || decodeURIComponent(j.url.split("/").pop())));
    let status = LABELS[j.status] || j.status;
    if (j.status === "downloading") status += j.bytes_total ? ` ${Math.floor(100 * j.bytes_done / j.bytes_total)}%` : ` ${fmt(j.bytes_done)}`;
    if (j.status === "done") status += ` · ${fmt(j.bytes_done)}`;
    top.append(el("span", "status", status));
    li.append(top);
    const meta = [j.size_text, j.folder].filter(Boolean).join(" · ");
    if (meta) li.append(el("div", "sub", meta));
    if (j.requested_by) li.append(el("div", "who", "prosi: " + j.requested_by));
    if (j.description) li.append(describe(j));
    li.append(el("div", "sub", j.url));
    if (j.status === "downloading") {
      const p = el("progress");
      if (j.bytes_total) { p.max = j.bytes_total; p.value = j.bytes_done; }
      li.append(p);
    }
    if (j.status === "failed" && j.error_message) li.append(el("div", "err", j.error_message));
    if (ADMIN && j.status === "waiting") li.append(actions([["Akceptuj", "accept", ""], ["Odrzuć", "reject", "reject"]], j));
    if (ADMIN && j.status === "failed") li.append(actions([["Ponów", "retry", ""]], j));
    ul.append(li);
  }
}

async function refresh() {
  try { render(await (await fetch("/requests")).json()); } catch (e) { /* server restarting */ }
}

document.getElementById("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = e.target, btn = form.querySelector("button");
  btn.disabled = true; msg.textContent = "";
  try {
    const r = await fetch(POST_URL, {method: "POST", body: new FormData(form)});
    if (!r.ok) { msg.textContent = (await r.json()).detail || "Błąd"; return; }
    if (form.elements.name) { try { localStorage.setItem("chomikdl_name", form.elements.name.value); } catch (e) {} }
    form.elements.url.value = "";
    await refresh();
  } catch (err) {
    msg.textContent = "Brak połączenia z serwerem";
  } finally { btn.disabled = false; }
});

if (!ADMIN) {
  try { document.querySelector("input[name=name]").value = localStorage.getItem("chomikdl_name") || ""; } catch (e) {}
}
refresh();
setInterval(refresh, 2000);
