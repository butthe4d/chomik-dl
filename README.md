# chomik-dl

A small background downloader for chomikuj.pl, meant for a homelab. Family members ask for a file,
and one admin approves it. Nothing downloads until the admin says yes.

## How it works

1. A family member opens the page, pastes a link to a file page (for example
   `https://chomikuj.pl/user/Folder/plik,123456.rar(archive)`), adds an optional name, and sends it.
2. The app looks up the file's name, size and description on the public page. This uses no transfer.
   The request then waits for approval. If two people ask for the same file, their names are merged.
3. The admin opens the admin page and presses **Akceptuj** to download or **Odrzuć** to refuse.
4. The server logs in with your account, goes through *Pobierz → popup → Pobierz* in a headless
   browser, and saves the file to `./downloads`.

- Status labels on the pages are in Polish.
- Each device can send 10 requests per minute.
- Downloads run one at a time. The page shows each one's status and progress.
- A download goes to `name.part` first and gets its real name only when it's complete.
- Failures show a reason: out of transfer, file needs a password, login failed or needs a captcha,
  file removed, or timeout.

## Admin link

The admin page is behind a secret link. The startup log does not print it. It says where the link is
saved: `data/admin-link.txt`. To print it:

```bash
docker compose exec chomik-dl python -m app.admin
```

Open the link once. It sets a cookie in that browser, and after that `http://<host>:8080/admin` works
there without the link. Don't share the link.

Set `PUBLIC_URL` in `.env` (for example `http://192.168.1.10:8080`) so the printed link is complete.

If the link leaks, make a new one:

```bash
docker compose exec chomik-dl python -m app.admin --regenerate
```

This takes effect at once. The old link and all admin cookies stop working.

On the admin page you can:

- press **Akceptuj** or **Odrzuć** on waiting requests,
- press **Ponów** on failed ones,
- paste a link into the field at the top to add it as an already-approved download, without a request. If the file was already downloaded it is merged into the existing entry, and a matching waiting request is promoted to queued.

## Setup

```bash
cp .env.example .env
#   set CHOMIKUJ_LOGIN / CHOMIKUJ_PASSWORD   (use a separate test account first)
#   set BIND_ADDR to this machine's LAN IP, e.g. 192.168.1.10
#   set PUID / PGID to the output of `id -u` / `id -g`
mkdir -p downloads data          # create them yourself so they are owned by you, not root
docker compose up -d --build
```

Open `http://<BIND_ADDR>:8080`. To open it by a hostname instead, for example `http://homelab.lan:8080`,
add that name to `ALLOWED_HOSTS` in `.env`. Any name not listed there is rejected, which protects
against DNS-rebinding attacks.

The family page has no password, and the admin page is protected only by the secret link. Only your
network is supposed to reach them, so keep `BIND_ADDR` on a LAN
address and never port-forward it. Requests from other websites are rejected, so a page you visit
can't queue requests or approve them behind your back.

Logs: `docker compose logs -f`.

## Staying under the radar

The browser presents itself as an ordinary Chromium on Linux: no "HeadlessChrome" anywhere,
`navigator.webdriver` off, Polish language, Warsaw time zone, and a 1920×1080 window. The file
download uses the same browser identity and cookies.

Behaviour matters more than looks:

- The login session is saved in `./data/browser`, and the app only logs in again when it expires.
- It types the login slowly and pauses 1–4 s between clicks.
- It waits at least 20 s between files.
- It handles one download at a time.
- A failed job is retried at most once.

You can change the pacing in `.env`.

None of this guarantees you won't be banned, and chomikuj's terms may not allow automated downloads.
Keep the volume low.

## If something fails

| Message | What to do |
|---|---|
| Login failed | Check `CHOMIKUJ_LOGIN` / `CHOMIKUJ_PASSWORD`. |
| Login needs captcha | Log in by hand once (see below). The saved session is reused afterwards. |
| Out of transfer | Top up transfer on the account. |
| File is password-protected | Not supported. |
| File not found or removed | Check the link in a normal browser. |
| chomikuj did not respond in time / Download interrupted | The job was already retried once, so submit it again later. |

Every failure saves a screenshot of what the browser saw to `./data/last_error.png`.

### Logging in by hand (captcha)

On a desktop with Python and a display, from a checkout of this repo:

```bash
python -m venv .venv && .venv/bin/pip install "playwright==1.65.1" && .venv/bin/playwright install chromium
.venv/bin/playwright open --channel chromium --user-data-dir ./browser-profile \
    --lang pl-PL --timezone Europe/Warsaw https://chomikuj.pl
# log in in the window that opens, solve the captcha, then close the window
```

Stop the container, replace `./data/browser` on the homelab with that `browser-profile` folder
(`chown -R PUID:PGID` it), and start the container again.

### The site changed

All the chomikuj-specific parts are in `app/browser/selectors.py`. The login form, cookie-consent
overlay, Pobierz button and download popup were checked against the live site on 2026-11-12 with a
real download. The lookup selectors (`LOOKUP_*`, for name, size and description on the logged-out
file page) were checked on 2026-11-15 against saved pages, kept in `tests/fixtures/`. Two parts are still unverified: the text that signals "no transfer" and the text that
signals "password needed". If something breaks, look at `data/last_error.png` and adjust that file.

## Development

```bash
python -m venv .venv && .venv/bin/pip install -e '.[dev]' && .venv/bin/playwright install chromium
.venv/bin/pytest
```

The browser tests run against a local fake chomikuj (`tests/fake_site/`) that mirrors the selectors,
so no account is needed. The lookup tests use the saved pages in `tests/fixtures/`.
