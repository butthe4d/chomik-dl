# chomik-dl — request approval queue (step 1 of 2)

Date: 2026-11-15
Status: approved (user, 2026-11-15)
Step 2 (separate design, later): Proxmox community-script install, like wish-list.

## Intent

Family members on the home network paste chomikuj.pl links. Today that starts a
download immediately (spending the account's transfer). Instead, each pasted
link becomes a **request**: the app looks up what the file is (name, size,
description if any) and puts it on a waiting list. The admin (the user) accepts
or rejects each request; only accepted ones are downloaded. How family members
then get the files is out of scope (handled outside the app).

## Goals

- Public page (no login, home network only):
  - one URL input + optional "Your name" field (remembered by the browser).
  - On submit the app fetches the file page (approach A below) and either shows
    an immediate error (invalid link, file removed / not found, page unreadable)
    or adds a request with status **waiting for approval**.
  - Shows the list of all requests with: file name, size, description (if any),
    who asked (if given), status. Statuses: waiting · rejected · queued ·
    downloading (progress) · done · failed (reason).
- Admin page behind a **secret admin link** (wish-list style):
  - Waiting requests at the top with name, size, description, folder/owner,
    who asked, when; **Accept** / **Reject** buttons per request.
  - Accept → request joins the existing download queue (status `queued`).
  - Reject → status `rejected`, stays visible on the public list.
  - Links pasted on the admin page are accepted automatically.
  - Admin also sees the full history and can retry a failed download.
- Duplicate request for the same file (same file id) while an earlier one is
  waiting/queued/downloading/done → no new row; the requester's name is added to
  the existing request ("asked by: Ania, Tomek"). A request that was rejected or
  failed can be requested again (new waiting request).

## Non-goals

- User accounts, per-person views, notifications, serving files to browsers.
- Editing requests, priorities, reordering the queue.
- Exposure outside the home network (LAN-only stays a constraint).

## Anti-goals

- Any transfer spent on a request the admin hasn't accepted.
- Family members being able to accept/reject (admin actions must require the
  admin secret, not just being on the LAN).
- Lookups touching the logged-in chomikuj account.

## Constraints

- Existing behaviour kept: one download at a time, human-like pacing, CSRF
  same-origin check and Host allowlist, `.part` files, crash recovery.
- Lookup traffic must stay modest: one GET per submitted link, no retries
  hammering, a per-client rate limit on submissions (e.g. 10/min) so a stuck
  button or script can't flood chomikuj.
- Existing jobs in the database from v1 must survive the upgrade (they become
  requests with their current status).

## Approaches considered (user picked A)

- **A. Plain HTTP fetch of the public file page — chosen.** Logged-out httpx GET
  with the same browser-like headers (UA, Accept-Language), parse HTML. Fast
  (<1 s), independent of the browser and the account, no transfer.
  Trade-off: another piece of site-specific parsing (kept in `selectors.py`).
- B. Lookup through the logged-in Playwright browser. Reuses selectors, but
  3–5 s per paste, contends with downloads, and puts every family paste
  (including rejected ones) on the account. Rejected.

## Decided "how"

- Parsing (live site, checked 2026-11-15 on a file without description):
  - name: `#fileDetails h1` text (fallback `og:title`, then name from URL);
  - size: `#fileDetails .fileInfo .fileSize` text, stored as shown ("35 KB")
    plus parsed bytes when possible;
  - folder/owner + date added: `<meta name="description">`;
  - description: `#fileDetails .filedescription[itemprop=description]`
    (confirmed 2026-11-15 on the user's example, a zip whose description lists
    the books inside, one per line separated by `<br>`); keep the line breaks,
    strip other markup; element missing or empty → none. Size text uses a Polish
    decimal comma ("16,38 MB").
  - Real logged-out pages saved as test fixtures in `tests/fixtures/`
    (`with_description.html`, `no_description.html`, `not_found.html` — the
    last is a 404 for a nonexistent id).
  - 404 / "nie istnieje / usunięty" text / no `#fileDetails` → error at submit.
  - (my call) chomikuj timeout, 5xx or 429 → error at submit "chomikuj is not
    responding, try again later"; one GET, no retry. A request never exists
    without a name.
  - (my call) page readable but showing a password / adult-content gate instead
    of `#fileDetails` → error at submit with that reason.
- Duplicate detection (my call): "same file" = the numeric file id in the URL
  (`,12345.ext`). Copies of a file in another user's folder have a different id
  and are treated as different requests. v1 rows get their file id from their
  stored URL during migration; their name comes from the URL (no lookups).
- The old direct-enqueue `POST /jobs` is replaced by the request flow; links
  pasted on the admin page use the same lookup and duplicate merge, then are
  auto-accepted. Admin "retry" reuses the same row.
- Admin secret (my call, after builder check): `secrets.token_urlsafe(32)`
  generated on first start and kept in plain text in `/data/admin-token`
  (mode 600; the data dir is the trust boundary — hashing would make it
  impossible to show the link again). The admin link
  `http://<host>/admin/<token>` is logged on every startup and written to
  `/data/admin-link.txt` (mode 600). Visiting it sets an HttpOnly,
  SameSite=Strict cookie so plain `/admin` works afterwards. Regenerate with a
  one-shot command `python -m app.admin_token --regenerate` (not an env var, so
  it can't rotate on every restart by accident).
- Admin POSTs (accept/reject/retry) require the admin cookie **and** pass the
  existing same-origin check.
- Requester name: optional, max 40 chars, stored as given (trimmed), shown
  escaped; browser remembers it in localStorage.
- Statuses: new `waiting` and `rejected` added in front of the existing
  `queued → resolving → downloading → done/failed` pipeline; the worker only
  ever picks `queued`.

## Left to the builder (builder's calls, flagged)

- Exact page layout (public list + admin page), Polish UI labels.
- Schema change mechanics (add columns / migrate existing rows on startup).
- Rate-limit implementation details (in-memory per client IP is fine).
- How many history rows the pages show (e.g. last 100).
