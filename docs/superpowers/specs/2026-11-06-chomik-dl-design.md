# chomik-dl — design

Date: 2026-11-06

## Intent

A personal background downloader for chomikuj.pl running on the user's homelab.
The user pastes a chomikuj.pl file-page URL into a single-input web form; the app
logs into chomikuj with the user's account, goes through the site's own
download flow, and saves the file into a folder on the homelab. The user should
not have to keep the page open or click through the site by hand.

## Goals

- One page, one input (chomikuj.pl file URL), one submit button.
- Downloads run in the background, saved to a mounted folder on the server.
- Page shows a list of submitted jobs with status and progress:
  `queued → resolving → downloading (x%) → done` or `failed: <plain reason>`.
- Login credentials configured once on the server (`.env`), never typed in the form.
- Login session is persisted between jobs/restarts so logins (and captchas) are rare.
- Clear failure reasons: login failed / captcha required, out of transfer,
  file password-protected, file not found / removed, invalid URL, timeout.

## Non-goals

- Downloading whole folders, multiple URLs per submission, or search.
- Passing files through to the browser (files stay on the server).
- Captcha solving. If chomikuj demands a captcha, the job fails with a clear
  message (the user can then log in once manually — see "Left to the builder").
- Multi-user support, accounts, or a public deployment.

## Anti-goals

- Exposed to the internet. It must be reachable only on the local network.
- Silent failures — a job that didn't produce a complete file must say why.
- Partial/corrupted files left looking like finished ones (download to a
  `.part` file, rename on completion).

## Constraints

- Runs on the user's homelab via `docker compose`; LAN only, no auth on the page
  (decided: LAN-only is the protection). Port published on a configurable host
  address so the user can bind it to the LAN interface.
- chomikuj file URLs point to a file *page*, not the file. The real download is
  triggered by clicking **Pobierz**, which opens a popup with a second button;
  chomikuj's JS then produces the actual file URL. Logged-in downloads consume
  the account's transfer quota.
- Login form is on the homepage: fields `Login`, `Password`, plus a
  `__RequestVerificationToken` hidden field (observed 2026-11-06).

## Approaches considered

1. **Headless browser end-to-end (Playwright + Chromium).** Robust to site JS;
   heavy image, no progress reporting for large downloads.
2. **Replicate site HTTP requests (no browser).** Lightweight, real progress;
   most fragile to site changes and needs reverse-engineering with a real account.
3. **Hybrid — chosen.** Playwright handles login and the Pobierz → popup →
   button clicks; the moment chomikuj produces the real file URL (navigation,
   download event, or network response), the browser stops and the app streams
   that URL with the browser's cookies via an HTTP client, reporting progress.
   Chosen because it follows the site's own JS (resilient) while giving
   progress and reliable large-file handling. Trade-off: more code than (1),
   image still ~1 GB.

## Decided "how"

- Python + FastAPI, single container, `docker compose`.
- Playwright (Chromium, headless) for login + resolving the download URL.
- httpx (streaming) for the actual file download, using cookies exported from
  the browser context and the same User-Agent.
- One download at a time (in-process queue/worker).
- Credentials in `.env` (`CHOMIKUJ_LOGIN`, `CHOMIKUJ_PASSWORD`).
- Volumes: `/downloads` (files) and `/data` (persisted browser session state +
  job history).
- Filename: as provided by chomikuj (Content-Disposition, else page title /
  URL); collisions get a numeric suffix.

## Looking like a regular browser (added 2026-11-12)

User wants the app to avoid looking automated, to reduce ban risk. Decided:

- Use real installed Chrome/Chromium ("new" headless mode) with a realistic,
  current desktop Chrome User-Agent (no "HeadlessChrome"), `pl-PL` locale,
  `Accept-Language: pl-PL,pl;q=0.9,en;q=0.8`, Europe/Warsaw timezone, normal
  1366×768/1920×1080 viewport. httpx download reuses the exact same UA/headers.
- Disable the `navigator.webdriver` flag (`--disable-blink-features=AutomationControlled`).
- Human-like behaviour matters more than fingerprints: reuse the persisted
  session (log in only when it expires), one job at a time, randomized short
  pauses (≈1–4 s) between page actions, real clicks on visible buttons, a
  minimum gap between jobs, no retries hammering the site (max 1 retry with backoff).
- No captcha solving, no proxies/IP rotation, no heavy stealth plugins.
- Honest caveat: none of this guarantees no ban; automation may be against
  chomikuj's terms. Low volume and normal pacing are the main protection.

## Test account

The user creates a separate chomikuj account themselves for testing (Claude
does not register accounts on third-party sites). Its credentials go in `.env`
the same way as the real ones.

## Left to the builder (builder's calls, flagged)

- Exact selectors and how to detect the resolved file URL — must be discovered
  against the live site; keep selectors in one module so they're easy to fix.
- Job persistence format (SQLite or JSON file in `/data`) — builder's call;
  queued jobs should survive a restart, an interrupted download restarts.
- Page refresh mechanism (simple polling every ~2 s is fine).
- Captcha fallback: if login hits a captcha, fail the job with
  "login needs captcha — log in manually"; offer a documented way to import a
  session (e.g. a one-off headed login or pasting cookies) — builder's call.
- Detecting "out of transfer" and "password-protected" from the popup contents.
- Testing: unit tests for URL validation, queue, filename handling and the
  download streamer (against a local test server); the chomikuj-facing flow is
  verified manually by the user with their account, since we have no account
  in the dev environment.
