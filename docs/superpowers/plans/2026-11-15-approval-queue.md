# Approval Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pasted chomikuj links become requests with looked-up name/size/description that wait for the admin (secret link) to accept or reject; only accepted ones reach the existing download worker.

**Architecture:** A new `lookup` module fetches the public file page with httpx (logged out) and parses it with BeautifulSoup. The existing `jobs` table gains request columns (file id, name, size, description, requested_by) and two statuses in front of the pipeline (`waiting`, `rejected`); the worker still only takes `queued`. A new `admin` module owns the secret token; FastAPI gets public `/requests` routes and cookie-protected `/admin` routes with two HTML pages.

**Tech Stack:** Python 3.12+, FastAPI, httpx, BeautifulSoup4 (`html.parser`), sqlite3, Playwright (unchanged), pytest.

**Spec:** `docs/superpowers/specs/2026-11-15-approval-queue-design.md` (step 1). Earlier spec: `docs/superpowers/specs/2026-11-06-chomik-dl-design.md`.

## Global Constraints

- Keep: one download at a time, pacing, `.part` files, crash recovery, `_same_origin` CSRF check on every POST, `_host_allowed` Host allowlist, httpx logger at WARNING.
- Lookup: exactly one GET per submitted link, no retry; headers = `BrowserSession`'s UA style (`chrome_user_agent`) + `Accept-Language: pl-PL,pl;q=0.9,en;q=0.8`; timeout 15 s; never sends account cookies.
- New error codes + exact messages: `unavailable` "chomikuj is not responding, try again later"; `adult_content` "File is behind an adult-content check". Existing codes/messages unchanged (`not_found`, `password_protected`, `invalid_url` reused at submit).
- Statuses: `waiting`, `rejected`, `queued`, `resolving`, `downloading`, `done`, `failed`. Worker picks only `queued`.
- Duplicate key: numeric file id from the URL (`,12345.ext`). "Active" statuses for merging: `waiting`, `queued`, `resolving`, `downloading`, `done`. `rejected`/`failed` → a new request row.
- Requester name: optional, `strip()`, max 40 chars (truncate), stored in `requested_by` as `", "`-joined unique names (empty string when nobody named).
- Admin token: `secrets.token_urlsafe(32)` in `DATA_DIR/admin-token` (mode 600); link file `DATA_DIR/admin-link.txt` (mode 600); cookie `chomikdl_admin` = token, HttpOnly, SameSite=Strict, Path=/, max-age 31536000; compare with `hmac.compare_digest`. Wrong/missing token on GET `/admin*` → 404; on admin POSTs → 403.
- New optional env `PUBLIC_URL` (e.g. `http://192.168.1.10:8080`, no trailing slash) used only to print a full admin link; unset → print `<PUBLIC_URL>/admin/<token>` with a hint to set it.
- Submission rate limit: 10 per 60 s per client IP on `POST /requests` → 429 "Too many requests, wait a minute".
- UI labels Polish; API error messages as above (English, as in v1).
- Pages render all looked-up text with `textContent` (never `innerHTML`).

## Review Focus

1. Description/name containing markup (`<script>`, `&amp;`) from chomikuj → stored as plain text, shown literally, never executed → test in Task 1 (parse) and Task 5 (page uses textContent; checked by grep test).
2. Family member POSTing to `/admin/requests/{id}/accept` without the cookie (or with a wrong one) → 403, status unchanged → test in Task 5.
3. Same link submitted twice, by the same and by different people → one row; names merged without repeats; a rejected file can be requested again → test in Task 2.
4. v1 database (old schema, rows in `done`/`failed`/`queued`) on upgrade → rows kept with name from URL and file id; a v1 `queued` row is still downloaded → test in Task 2.
5. Name field 200 chars / only spaces → truncated to 40 / treated as no name → test in Task 2.

---

## File Structure

```
app/lookup.py        FileInfo, parse_file_page, lookup_file           (new)
app/admin.py         token load/create/regenerate, link text, CLI       (new)
app/ratelimit.py     RateLimiter                                         (new)
app/urls.py          + file_id_from_url
app/errors.py        + unavailable, adult_content
app/browser/selectors.py  + lookup selectors and adult-gate text
app/jobs.py          schema migration, request fields, add_request, accept/reject/retry
app/main.py          /requests, /admin routes, startup admin link
app/config.py        + public_url
app/templates/index.html   public page (requests list + name field)
app/templates/admin.html   admin page (new)
tests/fake_site/app.py     file pages gain .fileInfo/.fileSize/.filedescription
tests/test_lookup.py, tests/test_admin.py, tests/test_ratelimit.py (new); test_jobs.py, test_api.py, test_config.py updated
README.md, .env.example
```

---

### Task 1: File page lookup

**Files:**
- Create: `app/lookup.py`, `tests/test_lookup.py`
- Modify: `app/urls.py`, `app/errors.py`, `app/browser/selectors.py`, `pyproject.toml` (add `beautifulsoup4>=4.12`)
- Fixtures (already committed): `tests/fixtures/with_description.html`, `no_description.html`, `not_found.html`

**Interfaces:**
- Produces:
  - `file_id_from_url(url: str) -> int | None` in `app/urls.py` (id from last segment `,(\d+)\.`).
  - `FileInfo` dataclass in `app/lookup.py`: `file_id: int, name: str, size_text: str | None, size_bytes: int | None, description: str | None, folder: str | None`.
  - `parse_file_page(html: str, url: str) -> FileInfo` — raises `ChomikError("not_found" | "password_protected" | "adult_content")`.
  - `parse_size(text: str) -> int | None` ("16,38 MB" → 17175674, "35 KB" → 35840; units B/KB/MB/GB, base 1024, comma or dot decimal).
  - `async lookup_file(url: str, *, client: httpx.AsyncClient | None = None) -> FileInfo` — 404 → `not_found`; timeout / connect error / 5xx / 429 → `unavailable`.
  - `LOOKUP_HEADERS: dict[str, str]` in `app/lookup.py`.
- selectors.py additions: `LOOKUP_NAME = "#fileDetails h1"`, `LOOKUP_SIZE = "#fileDetails .fileInfo .fileSize"`, `LOOKUP_DESCRIPTION = "#fileDetails .filedescription"`, `LOOKUP_FOLDER = "#fileDetails .folder"`, `TEXT_ADULT = re.compile(r"pełnoletn|ukończył\w* 18|treści dla dorosłych|tylko dla dorosłych", re.I)`.

- [ ] **Step 1: Failing tests** (`tests/test_lookup.py`, fixtures read from `tests/fixtures/`):
  - `test_parse_with_description`: URL `https://chomikuj.pl/kazik_78/Ksi*c4*85*c5*bcki/Harry+Harrison/Harrison+Harry/Harry+Harrison,2279812126.zip(archive)` → `file_id == 2279812126`, `name == "Harry Harrison.zip"`, `size_text == "16,38 MB"`, `size_bytes == 17175674`, `description.splitlines()[0] == "Harrison Harry - 24 Opowiadania"`, `"Harrison Harry - Stalowy Szczur 04 - Stalowy Szczur" in description.splitlines()`, no `"<"` in description, `folder == "kazik_78 / Książki / Harry Harrison / Harrison Harry"`.
  - `test_parse_without_description`: pirat URL `https://chomikuj.pl/Sylwiasiegmuller/Przedszkole/pirat/pirat+kolorowanka,5999643804.jpg` → `name == "pirat kolorowanka.jpg"`, `size_text == "35 KB"`, `size_bytes == 35840`, `description is None`.
  - `test_parse_not_found`: `not_found.html` → `ChomikError` code `not_found`.
  - `test_parse_markup_is_text`: minimal HTML `<div id="fileDetails"><h1><a>a&amp;b.zip</a></h1><div class="filedescription">x <script>alert(1)</script><br>y &lt;b&gt;</div></div>` → `name == "a&b.zip"`, `description == "x alert(1)\ny <b>"` (tags dropped, `<br>` → newline, entities decoded).
  - `test_parse_password_and_adult_gates`: page without `#fileDetails` whose body text contains "Podaj hasło do folderu" → `password_protected`; containing "Musisz być pełnoletni" → `adult_content`.
  - `test_parse_size`: table `[("16,38 MB", 17175674), ("35 KB", 35840), ("1 GB", 1073741824), ("700 B", 700), ("?", None)]`.
  - `test_file_id_from_url` (in `tests/test_urls.py`): `…/f,9.pdf` → 9; `https://chomikuj.pl/user` → None.
  - `lookup_file` via `httpx.MockTransport`: 200 fixture → FileInfo; 404 → `not_found`; 503 → `unavailable`; 429 → `unavailable`; transport raising `httpx.ConnectTimeout` → `unavailable`; request headers have `Accept-Language` starting `pl-PL` and no `Cookie`.
- [ ] **Step 2:** `.venv/bin/pip install -e '.[dev]'`; run `pytest tests/test_lookup.py tests/test_urls.py -q` → FAIL (import errors).
- [ ] **Step 3:** Implement. Description: walk the `.filedescription` element, `<br>` → `\n`, take text, strip each line, drop leading/trailing empty lines; empty → `None`. Name: `LOOKUP_NAME` text, else `og:title` meta, else `suggested_name_from_url`. Folder: `.folder` link texts joined `" / "` (the trailing file name text excluded). Gate detection runs only when `#fileDetails` is missing: password regex (existing `TEXT_PASSWORD`) → `password_protected`, `TEXT_ADULT` → `adult_content`, else `not_found`.
- [ ] **Step 4:** Run → PASS; full suite `.venv/bin/pytest -q` green.
- [ ] **Step 5:** Commit `feat: look up file name, size and description from the public page`.

### Task 2: Requests in the job store

**Files:** Modify `app/jobs.py`, `tests/test_jobs.py`, `app/recover`-related code unchanged.

**Interfaces:**
- Consumes: `FileInfo` (Task 1), `file_id_from_url` (Task 1), `suggested_name_from_url` (`app/browser/session.py`).
- Produces (all on `JobStore`; `Job` dataclass gains `file_id: int | None, name: str | None, size_text: str | None, description: str | None, folder: str | None, requested_by: str` — appended after existing fields):
  - `add_request(url: str, info: FileInfo, requested_by: str | None, *, status: str = "waiting") -> tuple[Job, bool]` — `bool` is True when a new row was created; merges into an active row with the same `file_id` (adds the name if new; if the merged row is `waiting` and `status == "queued"` it is promoted to `queued`).
  - `accept(job_id: int) -> bool` (`waiting` → `queued`), `reject(job_id: int) -> bool` (`waiting` → `rejected`), `retry(job_id: int) -> bool` (`failed` → `queued`, `attempts=0`, error cleared). Return False when the row is missing or in another status.
  - `list(limit: int = 100)` default raised to 100.
  - `add(url)` removed (tests updated to use `add_request` or a helper in tests).
- Schema migration in `__init__`: `PRAGMA table_info(jobs)`; `ALTER TABLE jobs ADD COLUMN …` for each missing new column (`requested_by TEXT NOT NULL DEFAULT ''`); then backfill rows with `file_id IS NULL`: `file_id = file_id_from_url(url)`, `name = suggested_name_from_url(url)`.
- `normalize_name(raw: str | None) -> str | None` module function: strip, empty → None, truncate to 40.

- [ ] **Step 1: Failing tests:**
  - `test_add_request_waiting` → status `waiting`, fields copied from FileInfo, `requested_by == "Ania"`.
  - `test_duplicate_merges_names`: same file_id twice ("Ania", then "Tomek", then "Ania" again, then no name) → one row, `requested_by == "Ania, Tomek"`, second call returns `created is False`.
  - `test_rejected_file_can_be_requested_again` → reject, then add_request → new row `waiting`.
  - `test_admin_add_promotes_waiting`: waiting row, then `add_request(..., status="queued")` → same row now `queued`.
  - `test_transitions`: accept only from waiting (accept on queued → False), reject only from waiting, retry only from failed (resets attempts, clears error).
  - `test_normalize_name`: `"  "` → None, `"x"*200` → 40 chars, `" Ania "` → `"Ania"`.
  - `test_v1_database_migrates` — create a db with the exact v1 `CREATE TABLE jobs (...)` statement (copy from current `app/jobs.py`), insert rows `('https://chomikuj.pl/u/Plik+a,11.zip','done',…)` and a `queued` one; open `JobStore` → rows listed with `name == "Plik a.zip"`, `file_id == 11`, `requested_by == ""`; `next_queued()` returns the v1 queued row.
  - existing tests in `test_jobs.py`, `test_worker.py` adapted to create rows through a test helper `make_job(store, url, status="queued")` in `tests/conftest.py`.
- [ ] **Step 2:** Run `pytest tests/test_jobs.py tests/test_worker.py -q` → FAIL.
- [ ] **Step 3:** Implement. **Step 4:** PASS + full suite green. **Step 5:** Commit `feat: requests with waiting/rejected states and v1 migration`.

### Task 3: Admin token

**Files:** Create `app/admin.py`, `tests/test_admin.py`; Modify `app/config.py` (+ `public_url: str | None`, env `PUBLIC_URL`, trailing `/` stripped), `tests/test_config.py`.

**Interfaces:**
- Produces: `load_or_create_token(data_dir: Path) -> str`; `regenerate_token(data_dir: Path) -> str`; `admin_link(token: str, public_url: str | None) -> str` (`f"{public_url}/admin/{token}"`, or `f"<PUBLIC_URL>/admin/{token}"` when None); `write_link_file(data_dir: Path, link: str) -> Path`; `token_matches(expected: str, given: str | None) -> bool`; CLI `python -m app.admin [--regenerate]` printing the link (reads settings via `load_settings`, but only needs `DATA_DIR`/`PUBLIC_URL` — so `load_settings` must not be required: the CLI reads those two env vars directly).
- [ ] **Step 1: Failing tests:** token created once and reused (same value on second call), file mode `0o600` for token and link files; regenerate returns a different token and the old no longer matches; `token_matches("abc", None) is False`, `("abc","abd") is False`; `admin_link` both forms; config `PUBLIC_URL="http://h:8080/"` → `"http://h:8080"`, default None.
- [ ] **Step 2:** FAIL. **Step 3:** Implement (`os.open(..., 0o600)` or `chmod` after write). **Step 4:** PASS. **Step 5:** Commit `feat: secret admin link`.

### Task 4: Rate limiter

**Files:** Create `app/ratelimit.py`, `tests/test_ratelimit.py`.

**Interfaces:** `RateLimiter(limit: int = 10, window: float = 60.0, clock: Callable[[], float] = time.monotonic)` with `allow(key: str) -> bool` (sliding window of timestamps per key; prune old keys).

- [ ] **Step 1: Failing tests:** 10 allowed, 11th refused; different key unaffected; after advancing a fake clock by 60 s allowed again.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit `feat: per-client submission rate limit`.

### Task 5: Routes and pages

**Files:** Modify `app/main.py`, `app/templates/index.html`; Create `app/templates/admin.html`; Modify `tests/test_api.py`, `tests/fake_site/app.py`.

**Interfaces:**
- Consumes: Tasks 1–4. `create_app(settings, *, start_worker=True, lookup=lookup_file)` — `lookup` is injectable (`async (url) -> FileInfo`).
- Produces routes (all POSTs pass `_same_origin`; bodies accept form or JSON like v1):
  - `GET /` public page. `GET /requests` → JSON list (Job fields).
  - `POST /requests` (`url`, optional `name`) → rate limit (key = `request.client.host`) → `normalize_file_url` → `lookup` → `add_request(status="waiting")` → 201 `{"request": job, "created": bool}`; `ChomikError` → 400 `{"detail": message}` except `unavailable` → 503; rate limit → 429.
  - `GET /admin/{token}` → valid: set cookie, 303 to `/admin`; invalid: 404. `GET /admin` → admin page if cookie valid else 404.
  - `POST /admin/requests` (`url`) → as public but `status="queued"`, name `"admin"` is **not** added (requested_by unchanged); wakes worker.
  - `POST /admin/requests/{id}/accept|reject|retry` → cookie check (403) → transition → 200 job JSON, or 409 `{"detail": "Request is not in a state that allows this"}`; accept/retry wake the worker.
  - Remove `POST /jobs` and `GET /jobs`.
  - Lifespan: `load_or_create_token`, build link with `settings.public_url`, `write_link_file`, log `Admin link: <link>` at INFO.
- Pages: public — URL input, optional name input (`localStorage` key `chomikdl_name`, wrapped in try/catch), list with name, size, description (collapsed to first 3 lines with a "więcej" toggle), "prosi: …", status label (`waiting` "czeka na akceptację", `rejected` "odrzucone", others as v1). Admin — same list with waiting requests first, Accept/Reject buttons on waiting, Retry on failed, an URL input that auto-accepts. Both poll every 2 s and use `textContent` only.
- Fake site: each file page gets `<div class="fileInfo"><p class="fileSize">16 KB</p></div>` and `<div class="filedescription" itemprop="description">opis<br>linia 2</div>` inside `#fileDetails`.

- [ ] **Step 1: Failing tests** (`TestClient`, `start_worker=False`, `lookup` stub returning a FileInfo, or raising `ChomikError`):
  - submit → 201, `request.status == "waiting"`, appears in `GET /requests`; submit same URL with another name → `created False`, names merged.
  - lookup raising `not_found` → 400 exact message; `unavailable` → 503 exact message; nothing stored.
  - cross-site POST to `/requests` → 403 (existing CSRF tests moved to `/requests`).
  - 11th submit within a minute → 429.
  - `GET /admin` without cookie → 404; `GET /admin/wrong` → 404; `GET /admin/<token>` → 303 with `set-cookie` containing `chomikdl_admin`, `HttpOnly`, `SameSite=strict`; then `GET /admin` → 200.
  - `POST /admin/requests/{id}/accept` without cookie → 403 and status still `waiting`; with cookie → `queued`; accept again → 409; reject on a waiting row → `rejected`; retry on a `failed` row → `queued`.
  - `POST /admin/requests` with cookie → status `queued`, `requested_by == ""`.
  - startup writes `DATA_DIR/admin-link.txt` containing `/admin/`.
  - `test_pages_use_textcontent_only`: neither template contains `innerHTML`.
  - `POST /jobs` → 404/405 (removed).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS + full suite.
- [ ] **Step 5: End-to-end** (scratchpad script like v1's): run app against the fake site, submit `/u/f,1.zip` with name "Ania" via the public page → shows "czeka na akceptację" with description "opis"; open admin link, Accept → job reaches done, file exists. Screenshot both pages and look at them.
- [ ] **Step 6:** Commit `feat: request form, admin page with accept/reject`.

### Task 6: Docs

**Files:** Modify `README.md`, `.env.example` (add `PUBLIC_URL=` with comment).

- [ ] **Step 1:** README: how requests work, where the admin link is (`docker compose logs | grep "Admin link"` or `data/admin-link.txt`), `docker compose exec chomik-dl python -m app.admin --regenerate`, `PUBLIC_URL`.
- [ ] **Step 2:** Full suite green. Commit `docs: approval queue and admin link`.
