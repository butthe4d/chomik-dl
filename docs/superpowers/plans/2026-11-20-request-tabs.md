# Request Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five status tabs with counts, a "Kto prosił" filter and recent-name suggestions on both pages, computed in the browser from the polled `/requests` data.

**Architecture:** Pure list logic goes in a new `app/static/list-logic.js` (loaded before `requests.js` in the browser, `require`-able from Node for unit tests). `requests.js` keeps rendering and adds the tab bar, filter and datalist, preserving UI state across the 2 s polls. A Playwright test drives both pages against a seeded app.

**Tech Stack:** vanilla JS, Node's built-in test runner (`node --test`), pytest + Playwright.

**Spec:** `docs/superpowers/specs/2026-11-20-request-tabs-design.md`

## Global Constraints

- Tabs, in order, ids → labels → statuses: `waiting` "Czeka na akceptację" [waiting]; `approved` "Zaakceptowane" [queued, resolving, downloading]; `done` "Pobrane" [done]; `failed` "Błędy" [failed]; `rejected` "Odrzucone" [rejected]. Label shows count: `Czeka na akceptację (3)`.
- Filter label "Kto prosił", first option "wszyscy" (value ""). Names = distinct `requested_by` parts split on `", "`, trimmed, sorted with `localeCompare(…, "pl")`. Multi-name request matches each name; unnamed rows only under "wszyscy".
- Suggestions: `<datalist id="names">` with the 5 most recent distinct names (newest request id first, then name order inside the row), only on the family page form (the admin form has no name field).
- Default tab `waiting` on both pages. localStorage keys `chomikdl_tab_<page>` and `chomikdl_who_<page>` with `<page>` = `admin` or `public`; every access in try/catch.
- Counts reflect the active requester filter.
- A poll never resets: active tab, filter, expanded descriptions, focused name input value.
- Text only via `textContent`; no `innerHTML` anywhere (existing test scans templates and static JS).
- Phone width: tab bar scrolls horizontally inside itself (`overflow-x: auto`), page never scrolls sideways.

## Review Focus

1. A selected requester disappears from the data (their only request scrolled out of the last 100) → filter falls back to "wszyscy" instead of showing an empty list with an invalid selection → test in Task 1 (`resolveRequester`) and Task 2.
2. Names with odd spacing/case duplicates (`"Ania"`, `" Ania "`) → one entry → test in Task 1.
3. localStorage throws (private mode) → page still renders on default tab → test in Task 2 (Playwright with `localStorage` patched to throw).
4. A tab with zero rows → shows "Brak próśb." inside that tab, tab still clickable → test in Task 2.
5. Status the client doesn't know (future server value) → row isn't lost: appears under no tab but the page doesn't crash → test in Task 1 (`tabOf` returns null) — accepted.

---

### Task 1: List logic module

**Files:** Create `app/static/list-logic.js`, `tests/js/list-logic.test.js`, `tests/test_js.py`.

**Interfaces — Produces** (global `ListLogic` in the browser; `module.exports` in Node):
- `TABS: Array<{id, label, statuses}>` (values from Global Constraints)
- `tabOf(status: string) -> string|null`
- `namesOf(job) -> string[]` (split/trim requested_by, drop empty)
- `requesters(jobs) -> string[]` (distinct, pl-sorted)
- `filterByRequester(jobs, who: string) -> jobs` ("" = all)
- `countByTab(jobs) -> {waiting, approved, done, failed, rejected}`
- `inTab(jobs, tabId) -> jobs` (newest id first)
- `recentNames(jobs, n = 5) -> string[]`
- `resolveRequester(saved: string, available: string[]) -> string` (saved if present else "")

- [ ] **Step 1: Failing tests** (`node:test` + `node:assert/strict`) covering every function with the Global Constraints values; include `namesOf({requested_by:" Ania ,  Tomek"})` → `["Ania","Tomek"]` (split on "," then trim), duplicate `"Ania"` across rows counted once, `recentNames` over rows ids 1..7 returning 5 newest distinct, `tabOf("weird") === null`, `resolveRequester("Ola", ["Ania"]) === ""`. `tests/test_js.py::test_node_unit_tests` runs `node --test tests/js/` via subprocess (skip if `node` missing) and asserts exit code 0.
- [ ] **Step 2:** `node --test tests/js/` → FAIL (module missing).
- [ ] **Step 3:** Implement; wrap as `(function (root) { … if (typeof module !== "undefined") module.exports = api; else root.ListLogic = api; })(this);`.
- [ ] **Step 4:** `node --test tests/js/` and `.venv/bin/pytest -q tests/test_js.py` → PASS.
- [ ] **Step 5:** Commit `feat: list logic for tabs, requester filter and name suggestions`.

### Task 2: Tabs, filter and suggestions on both pages

**Files:** Modify `app/static/requests.js`, `app/static/style.css`, `app/templates/index.html`, `app/templates/admin.html`; Create `tests/test_pages.py`.

**Interfaces — Consumes:** `ListLogic` from Task 1. Templates load `/static/list-logic.js` before `/static/requests.js`; add `<nav id="tabs" role="tablist">`, `<label>Kto prosił <select id="who"></select></label>`, and on the family page `list="names"` on the name input plus `<datalist id="names">`. Page key from `ADMIN`.
- Tab buttons: `role="tab"`, `aria-selected`, `data-tab`; rebuilt in place each poll only by updating text/selection (don't recreate if ids unchanged, to keep focus).
- `<select id="who">`: rebuild options only when the name list changes; keep selection via `resolveRequester`.
- Datalist: rebuild only when `recentNames` changes (never touch the name input's value).
- Empty tab → `Brak próśb.`; admin sort "waiting first" no longer needed (tabs separate it) — remove.

- [ ] **Step 1: Failing Playwright tests** in `tests/test_pages.py` (sync or async Playwright; start the app with `create_app(settings, start_worker=False, lookup=stub)` via uvicorn in a thread like `tests/conftest.py` does for the fake site; seed rows with `tests.conftest.make_job` + `store.update` — one row per status, names "Ania", "Tomek", "Ania, Ola", one unnamed):
  - `test_tabs_counts_and_default` — family page shows 5 tabs in the order/labels above with correct counts; default selected tab is "Czeka na akceptację"; only waiting rows visible.
  - `test_switching_tab_survives_poll` — click "Pobrane", wait 2.5 s, still on "Pobrane" with only done rows.
  - `test_filter_by_requester` — select "Ola" → only the "Ania, Ola" row's tab counts as 1, others 0; reload keeps "Ola" (localStorage).
  - `test_missing_requester_falls_back` — set localStorage `chomikdl_who_public` to "Zenek" before load → select shows "wszyscy".
  - `test_name_suggestions` — family page datalist options are the 5 most recent distinct names; admin page has no datalist.
  - `test_empty_tab_and_storage_errors` — with `localStorage` access patched to throw (`page.add_init_script`), page renders default tab; a tab with 0 rows shows "Brak próśb.".
  - `test_admin_buttons_in_tabs` — admin page (cookie via `/admin/<token>`): Akceptuj/Odrzuć in "Czeka na akceptację", Ponów in "Błędy".
- [ ] **Step 2:** `.venv/bin/pytest -q tests/test_pages.py` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `.venv/bin/pytest -q` (full suite incl. no-innerHTML test) → PASS; take a screenshot of both pages at 1280 px and 390 px wide and look at them.
- [ ] **Step 5:** Commit `feat: tabs, requester filter and name suggestions on the request list`.
