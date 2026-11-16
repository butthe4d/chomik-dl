# chomik-dl — Proxmox community-script install (step 2 of 2)

Date: 2026-11-16
Status: draft — awaiting user approval

## Intent

Install and run chomik-dl on the user's Proxmox VE homelab the same way as the
community-scripts apps and as the user's wish-list project: one command in the
Proxmox shell creates a Debian 13 LXC with the app running; `update` inside the
container upgrades it from GitHub; a settings command changes configuration.
Downloaded files go to a NAS folder that the user will attach to the container
at `/data` (mount point) — set up by the user outside this work.

The repo (github.com/butthe4d/chomik-dl) will be public before installing, so no
GitHub token handling.

## Goals

- `bash -c "$(curl -fsSL https://raw.githubusercontent.com/butthe4d/chomik-dl/main/proxmox/ct/chomik-dl.sh)"`
  on the Proxmox host shows the standard community-scripts menus and creates an
  unprivileged Debian 13 LXC with chomik-dl running on port 8080.
- During installation the script asks for: chomikuj login and password
  (required), PUBLIC_URL (default `http://<container-IP>:8080`), optional
  ALLOWED_HOSTS, and (behind "advanced?") pacing: MIN_JOB_GAP_SECONDS,
  HUMAN_PAUSE_MIN/MAX. Update channel `main` (default) or `releases`.
- At the end it shows the **admin link** (live terminal only) and saves it to
  `/root/chomik-dl.creds` (mode 600), like wish-list.
- `chomik-dl-settings` in the container: whiptail menu with every setting and
  its current value (password shown masked); saves and restarts the service.
  Also offers "regenerate admin link" (runs `python -m app.admin --regenerate`,
  updates the creds file).
- `update` in the container: checks GitHub for a newer version on the chosen
  channel; if newer: backs up app state, installs the new code (including the
  Playwright Chromium matching the new Playwright version), restarts, health
  check, rolls back code + state if the new version fails to start.
- Downloads land in `/data`; app state stays on the container's own disk.

## Non-goals

- Mounting the NAS share or creating the LXC mount point (user does this; the
  README documents how and what the permissions must allow).
- Submitting to community-scripts/ProxmoxVE; VM install; Docker inside the LXC.
- Private-repo/token support.
- Sharing shell code with wish-list (deliberate copy; the two may diverge).

## Anti-goals

- Downloads silently filling the container's disk because the NAS isn't
  mounted.
- The chomikuj password or admin token readable by anyone but root and the app
  user, or printed into logs.
- An update that leaves the app down with no way back.

## Constraints

- Container defaults: 1 vCPU, 1536 MB RAM, 6 GB disk, unprivileged, Debian 13
  (Chromium + Playwright need more than wish-list's 512 MB / 3 GB).
  Playwright 1.65 supports Debian 13 (`playwright install --with-deps chromium`).
- Community-scripts engine pinned to the same known-good commit wish-list uses
  (`community-scripts/core@665635b6aff5cf1486400d47e6c5aa38f9ba333d`),
  overridable by env like upstream.
- Own catalogue slug (`butthe4d-chomik-dl`) so upstream advisories never apply.

## Approaches (user picked A)

- **A. Native install with the community-scripts engine — chosen.** Copy and
  adapt wish-list's `proxmox/` (ct, install, misc lib/settings/unit, tests):
  venv in `/opt/chomik-dl`, Playwright Chromium beside it. Same UX the user
  knows; inherits wish-list's interrupt-safe install/rollback fixes. Costs
  ~1,200 lines of adapted shell that will drift from wish-list (accepted:
  "similarities are expected at this moment, but it does not mean I will want
  the same behaviour in the future").
- B. Docker inside the LXC with the existing compose file — less code, but
  nesting, an extra ~1 GB, another permission layer on `/data`, no rollback.
- C. Shared shell library across both repos — couples the repos; overkill.

## Decided "how"

- Layout: `proxmox/ct/chomik-dl.sh`, `proxmox/install/chomik-dl-install.sh`,
  `proxmox/misc/chomik-dl-lib.sh`, `proxmox/misc/chomik-dl-settings`,
  `proxmox/misc/chomik-dl.service`, `proxmox/tests/…` (adapted from wish-list).
- In the container: system user `chomik-dl` with **fixed UID/GID 1000**
  (maps to 101000 on the host for an unprivileged LXC — the README tells the
  user to give that UID write access on the NAS side); code
  `/opt/chomik-dl` (venv `.venv`, git checkout of the chosen ref); Playwright
  browsers in `/opt/chomik-dl/ms-playwright` (`PLAYWRIGHT_BROWSERS_PATH`);
  app state `DATA_DIR=/var/lib/chomik-dl` (SQLite, browser profile, admin
  token); `DOWNLOAD_DIR=/data`; settings `/etc/chomik-dl/chomik-dl.env`
  (root:chomik-dl 640); installed version in `/opt/chomik-dl_version.txt`.
- systemd `chomik-dl.service`: `uvicorn --factory app.main:build --host 0.0.0.0
  --port 8080` as `chomik-dl`, `EnvironmentFile=` the settings file,
  `Restart=on-failure`.
- `/data` handling: the install creates `/data` (owned by the app user) if it
  doesn't exist. New app setting `DOWNLOAD_REQUIRE_MOUNT` (default `false` in
  the app, set `true` by the Proxmox installer): when true, before resolving a
  download the worker checks that `DOWNLOAD_DIR` is a mount point and writable;
  otherwise the job fails with new error code `storage_unavailable`
  "Download folder is not available — is the NAS mounted?" **before any
  transfer is spent**. Requests and approvals keep working; admin "Ponów"
  retries once fixed. (Small app change, part of this work.)
- Backups before update: `/var/lib/chomik-dl` (DB via sqlite3 `.backup`,
  admin token, browser profile), keep last 3, like wish-list.
- Testing: `shellcheck`; the wish-list-style harness (install script inside a
  plain `debian:13` container with stubbed engine functions/systemctl,
  checking `/healthz`, settings edits persist, update upgrades and rolls back,
  `storage_unavailable` when `/data` isn't a mount point). The harness needs
  `docker run --security-opt apparmor=unconfined`, which is blocked in the dev
  sandbox, so it also runs in a GitHub Actions workflow (shellcheck + harness +
  pytest) on push/PR. The final real-Proxmox run is the user's.
- README: "Proxmox" section — the one-liner, what it asks, where things live,
  `update`, `chomik-dl-settings`, and **attaching the NAS folder**: mount the
  share on the host, `pct set <CTID> -mp0 <host-path>,mp=/data`, and make the
  share writable for host UID 101000 (examples for NFS and SMB).

## Calls made after the builder check (mine — user to confirm while reading)

- **Captcha on a headless LXC:** no display/xvfb in the container. If chomikuj
  demands a captcha, the README's existing desktop flow applies: log in once in
  a desktop browser with `playwright open --user-data-dir …`, then copy that
  profile to `/var/lib/chomik-dl/browser` (stop the service, `chown -R
  chomik-dl:`, start). Documented in the Proxmox section.
- **Fresh install only:** no migration from a Docker deployment (none exists
  yet). README notes that the DB and `admin-token` can be copied into
  `/var/lib/chomik-dl` by hand.
- **`releases` channel with no tags yet:** `update` reports "no release yet,
  staying on <current>" and changes nothing; `main` is the default anyway.
- **Playwright pin:** `pyproject.toml` pins `playwright==1.65.1` (single source
  of truth, matches the Dockerfile); install and every update run the venv's
  `playwright install --with-deps chromium`, so the browser always matches.
- **Mount check:** checks `DOWNLOAD_DIR` itself (`/data` is the mount point by
  design) with `os.path.ismount` + a write test.
- **Messages:** `storage_unavailable` message in English like the other API
  messages.
- **Settings values:** any characters except newlines are allowed (password
  included); quoting reuses wish-list's env-file quote/unquote helpers, with a
  test for quotes, `$`, `#`, spaces and backslashes reaching the app intact.
- **PUBLIC_URL change:** `chomik-dl-settings` rewrites `/root/chomik-dl.creds`
  (and the app's `admin-link.txt`) with the same token; only "regenerate"
  changes the token.

## Left to the builder

Prompt wording (English), whiptail layout, how `update` compares versions
(copy wish-list), harness details, CI workflow details, whether pacing
prompts sit behind an "advanced" question.
